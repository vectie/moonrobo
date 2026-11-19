"""Reconstruct actor updates, fork final-cycle gradients and score the full suite."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import torch

from cpu_physics import PhysicsRuntime
from dynamics import load_model
from full_body_reference import assess_tracking_quality
from reference_action_response import digest
from reference_actor import load_reference_actor, load_references, save_reference_actor
from reference_learning import actor_origin_indices, collect_episode, imagined_objective, join_batches, optimize_model_actor, restore_collected_batch, state_digest, take
from reference_task import ReferenceSchedule


def optimizer_digest(optimizer):
    state = optimizer.state_dict()
    result = hashlib.sha256(json.dumps(state["param_groups"], sort_keys=True).encode())
    for index, values in sorted(state["state"].items()):
        result.update(str(index).encode())
        for name, value in sorted(values.items()):
            result.update(name.encode())
            result.update(value.detach().cpu().numpy().tobytes() if isinstance(value, torch.Tensor) else repr(value).encode())
    return result.hexdigest()


def generator_digest(generator):
    return hashlib.sha256(generator.get_state().numpy().tobytes()).hexdigest()


def fork_actor_optimizer(actor, optimizer, generator):
    branch = copy.deepcopy(actor)
    branch_optimizer = torch.optim.Adam(branch.parameters(), lr=optimizer.param_groups[0]["lr"])
    branch_optimizer.load_state_dict(copy.deepcopy(optimizer.state_dict()))
    branch_generator = torch.Generator().set_state(generator.get_state().clone())
    if (state_digest(branch) != state_digest(actor) or optimizer_digest(branch_optimizer) != optimizer_digest(optimizer) or
        generator_digest(branch_generator) != generator_digest(generator)):
        raise ValueError("actor/optimizer/sampler fork differs")
    return branch, branch_optimizer, branch_generator


def compare_actor(actor, metadata, source):
    path = source/metadata["checkpoint"]
    if digest(path) != metadata["sha256"]: raise ValueError("original actor bytes changed")
    saved, _, _ = load_reference_actor(path)
    a, b = actor.state_dict(), saved.state_dict()
    if a.keys() != b.keys() or any(not torch.equal(value, b[key]) for key, value in a.items()):
        maximum = max(float((value-b[key]).abs().max()) for key, value in a.items())
        raise ValueError(f"reconstructed actor differs: {path}, maximum {maximum}")
    return dict(actor_checkpoint=str(path), checkpoint_sha256=digest(path), actor_state_sha256=state_digest(actor), all_tensors_identical=True)


def summarize(trials):
    steps = sum(t["steps"] for t in trials)
    metrics = ["joint_rmse_rad", "body_position_rmse_m", "root_position_rmse_m", "root_orientation_rmse_rad"]
    return dict(trials=len(trials), falls=sum(t["failed"] for t in trials), steps=steps,
        mean_survival_s=sum(t["simulated_seconds"] for t in trials)/len(trials),
        **{name: (sum(t[name]**2*t["steps"] for t in trials)/steps)**.5 for name in metrics})


def inherited_record(record, source):
    record = copy.deepcopy(record)
    record["file"] = str(source/record["file"])
    record["behavior"]["checkpoint"] = str(source/record["behavior"]["checkpoint"])
    return record


def run(args):
    started = time.perf_counter()
    output, diagnostic_path = Path(args.output).resolve(), Path(args.source).resolve()
    charter = json.loads((output/"config.json").read_bytes())
    if digest(diagnostic_path/"report.json") != charter["diagnostic_report_sha256"]:
        raise ValueError("parameter-direction source changed")
    diagnostic = json.loads((diagnostic_path/"report.json").read_bytes())
    source = Path(diagnostic["source_study"])
    if digest(source/"report.json") != charter["source_report_sha256"]: raise ValueError("learning source changed")
    previous = json.loads((source/"report.json").read_bytes())
    learning = {**previous["config"], "actor_critic_tail": False, "actor_origin_sampling": "trajectory-states"}
    config = {**learning, **charter}
    torch.set_num_threads(learning["cpu_threads"]); torch.use_deterministic_algorithms(True)
    _, references = load_references(diagnostic["references"])
    if digest(Path(diagnostic["references"])/"manifest.json") != previous["reference_manifest_sha256"]:
        raise ValueError("reference manifest changed")
    quality = previous["quality_target"]
    incoming_path = source/"initial/actor-zero-output.pt"
    if digest(incoming_path) != previous["initialization_sha256"]: raise ValueError("incoming actor changed")
    by_id = {r["episode_id"]: r for r in previous["physical_records"]}
    runtime = PhysicsRuntime(args.scene)
    records, runs, checks = [], [], []
    reconstruction_seconds, intervention_seconds, evaluation_seconds = 0., 0., 0.
    for method in charter["methods"]:
        for seed in charter["seeds"]:
            original = next(r for r in previous["runs"] if r["method"]==method and r["seed"]==seed)
            actor, geometry, _ = load_reference_actor(incoming_path)
            schedule = ReferenceSchedule(references, geometry, [0, 500, 1000])
            optimizer = torch.optim.Adam(actor.parameters(), lr=learning["actor_learning_rate"])
            generator = torch.Generator().manual_seed(23000+seed)
            training_ids, reconstruction = [], []
            branch = branch_optimizer = branch_generator = None
            for cycle in original["cycles"]:
                cycle_started = time.perf_counter()
                number = cycle["cycle"]
                batch = join_batches([restore_collected_batch(source, by_id[i], actor, schedule, learning) for i in cycle["training_episode_ids"]])
                training_ids += cycle["training_episode_ids"]
                actor_path = source/cycle["checkpoint"]["checkpoint"]
                model_path = actor_path.parent/f"dynamics-cycle-{number}.pt"
                model, model_metadata = load_model(model_path)
                if model_metadata["training_episode_ids"] != training_ids: raise ValueError("saved model training records differ")
                if number == charter["intervention_cycle"]:
                    pinned = next(r for r in diagnostic["runs"] if r["method"]==method and r["seed"]==seed)
                    if digest(model_path) != pinned["model_sha256"]: raise ValueError("final fixed model differs from independent diagnostic")
                for p in model.parameters(): p.requires_grad_(False); p.grad = None
                if number == charter["intervention_cycle"]:
                    branch, branch_optimizer, branch_generator = fork_actor_optimizer(actor, optimizer, generator)
                    start_actor, start_optimizer, start_sampler = state_digest(actor), optimizer_digest(optimizer), generator_digest(generator)
                    peek = torch.Generator().set_state(generator.get_state().clone())
                    torch.randint(len(batch["state"]), (learning["actor_calibration_batch_size"],), generator=peek)
                    first = take(batch, actor_origin_indices(batch, learning, peek))
                    with torch.no_grad():
                        full_forward, full_active = imagined_objective(model, actor, None, first, geometry, schedule,
                            {**learning, "actor_feedback_gradient": "full"})
                        stop_forward, stop_active = imagined_objective(model, branch, None, first, geometry, schedule,
                            {**learning, "actor_feedback_gradient": "stop-policy-inputs"})
                    if not torch.equal(full_forward, stop_forward) or full_active != stop_active:
                        raise ValueError("fork changes the forward objective")
                fit = optimize_model_actor(model, actor, None, optimizer, batch, geometry, schedule,
                    {**learning, "actor_feedback_gradient": "full"}, generator)
                comparison = compare_actor(actor, cycle["checkpoint"], source)
                if fit["actor_origin_samples"] != cycle["actor"]["actor_origin_samples"]:
                    raise ValueError("reconstructed actor origins differ from original draws")
                row = dict(cycle=number, model_checkpoint=str(model_path), model_sha256=digest(model_path),
                    training_episode_ids=cycle["training_episode_ids"], actor_origin_draws_identical=True, **comparison)
                reconstruction.append(row)
                reconstruction_seconds += time.perf_counter()-cycle_started
                print(json.dumps(dict(event="actor-reconstructed", method=method, seed=seed, cycle=number,
                    actor_state_sha256=comparison["actor_state_sha256"])), flush=True)
            checks.append(dict(method=method, seed=seed, cycles=reconstruction))
            full_result = dict(method=method, seed=seed, gradient_route="full", reused_final_evaluation=True,
                actor_optimizer_steps=72, summary=original["summary"], trials=original["trials"], quality=original["quality"],
                checkpoint={**original["checkpoint"], "checkpoint": str(source/original["checkpoint"]["checkpoint"])},
                final_actor_fit=fit, reconstructed_final_actor_identical=True, reconstruction=reconstruction)
            full_result.update(matched_start_actor_sha256=start_actor, matched_start_optimizer_sha256=start_optimizer,
                matched_start_sampler_sha256=start_sampler, equal_fork_forward_objective=True,
                fork_forward_objective=float(full_forward), fork_active_steps=full_active,
                final_sampler_sha256=generator_digest(generator))
            runs.append(full_result)
            records += [inherited_record(by_id[t["episode_id"]], source) for t in original["trials"]]
            intervention_started = time.perf_counter()
            stop_fit = optimize_model_actor(model, branch, None, branch_optimizer, batch, geometry, schedule,
                {**learning, "actor_feedback_gradient": "stop-policy-inputs"}, branch_generator)
            intervention_seconds += time.perf_counter()-intervention_started
            if stop_fit["actor_origin_samples"] != fit["actor_origin_samples"] or generator_digest(branch_generator) != generator_digest(generator):
                raise ValueError("forked actor sampler draws differ")
            folder = output/method/f"seed-{seed}"
            (folder/"policy").mkdir(parents=True)
            path = folder/"policy/actor-stop-cycle-6.pt"
            provenance = dict(source_report_sha256=digest(source/"report.json"), source_method=method, seed=seed,
                cycle=6, actor_steps=72, final_cycle_route="stop-policy-inputs", training_episode_ids=training_ids)
            save_reference_actor(path, branch, geometry.spec, .02, provenance, critic_status="unused by fixed H32 no-tail objective")
            restored, restored_geometry, _ = load_reference_actor(path)
            if state_digest(restored) != state_digest(branch): raise ValueError("stopped actor reload differs")
            behavior = dict(checkpoint=str(path.relative_to(output)), sha256=digest(path), state_sha256=state_digest(branch))
            update_path = folder/"policy/actor-update-state-cycle-6.pt"
            torch.save(dict(format="moonrobo.g1-fixed-model-actor-update-state.v1", optimizer=branch_optimizer.state_dict(),
                sampler_state=branch_generator.get_state(), paired_actor_sha256=digest(path), fixed_model_checkpoint=str(model_path),
                fixed_model_sha256=digest(model_path), source_report_sha256=digest(source/"report.json"),
                config={**learning, "actor_feedback_gradient": "stop-policy-inputs"},
                scope="Actor optimizer/sampler under imported fixed model; not a full alternation-worker restart"), update_path)
            saved_state = torch.load(update_path, weights_only=True)
            restored_optimizer = torch.optim.Adam(restored.parameters(), lr=learning["actor_learning_rate"])
            restored_optimizer.load_state_dict(saved_state["optimizer"])
            if optimizer_digest(restored_optimizer) != optimizer_digest(branch_optimizer) or not torch.equal(saved_state["sampler_state"], branch_generator.get_state()):
                raise ValueError("new actor-update state reload differs")
            trials = []
            evaluation_started = time.perf_counter()
            for clip in range(len(references)):
                for seconds in quality["origins_s"]:
                    _, record, trial = collect_episode(runtime, references, schedule, restored, restored_geometry, learning,
                        clip, round(seconds/.02), seed, 6, "final-stop-policy-inputs", folder, behavior)
                    record["file"] = str((folder/record["file"]).relative_to(output))
                    records.append(record); trials.append(trial)
            evaluation_seconds += time.perf_counter()-evaluation_started
            assessed = assess_tracking_quality(trials, quality)
            result = dict(method=method, seed=seed, gradient_route="stop-policy-inputs", reused_final_evaluation=False,
                actor_optimizer_steps=72, intervention_actor_steps=12, summary=summarize(trials), trials=trials, quality=assessed,
                checkpoint=behavior, final_actor_fit=stop_fit, matched_start_actor_sha256=start_actor,
                matched_start_optimizer_sha256=start_optimizer, matched_start_sampler_sha256=start_sampler,
                equal_fork_forward_objective=True, fork_forward_objective=float(full_forward), fork_active_steps=full_active,
                final_sampler_sha256=generator_digest(branch_generator), paired_full_sampler_sha256=generator_digest(generator),
                origin_draws_identical=True, optimizer_state_source="reconstructed from archived actor operations, original snapshots unavailable",
                actor_update_state=dict(file=str(update_path.relative_to(output)), sha256=digest(update_path),
                    optimizer_sha256=optimizer_digest(branch_optimizer), sampler_sha256=generator_digest(branch_generator), reload_identical=True))
            runs.append(result)
            print(json.dumps(dict(event="final-route-quality", method=method, seed=seed, summary=result["summary"], quality=assessed)), flush=True)
    report = dict(format="moonrobo.g1-reference-final-route-training.v1", config=config, source_study=str(source),
        source_report_sha256=digest(source/"report.json"), diagnostic_study=str(diagnostic_path), diagnostic_source_sha256=digest(diagnostic_path/"report.json"),
        references=diagnostic["references"], reference_manifest_sha256=previous["reference_manifest_sha256"], quality_target=quality,
        initial=dict(trials=[]), runs=runs, reconstruction=checks, physical_records=records,
        new_physical_records=162, reused_physical_records=162, provider_sha256=digest(__file__),
        provider_seconds=time.perf_counter()-started, costs=dict(actor_reconstruction_seconds=reconstruction_seconds,
            actor_intervention_seconds=intervention_seconds, new_evaluation_seconds=evaluation_seconds),
        physical_execution_allowed=False, release_qualified=False, scope=charter["scope"])
    (output/"report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["source", "scene", "output"]: parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
