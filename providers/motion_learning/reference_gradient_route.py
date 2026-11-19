"""Compare full and stopped policy-input parameter directions in CPU physics."""
import argparse
import copy
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch.nn.utils import parameters_to_vector, vector_to_parameters

from cpu_physics import PhysicsRuntime
from dynamics import load_model
from reference_action_response import digest
from reference_actor import load_reference_actor, load_references
from reference_learning import collect_episode, imagined_objective, join_batches, restore_collected_batch, state_digest, take
from reference_task import ReferenceSchedule


@torch.no_grad()
def means(actor, batch):
    return actor.latent_mean(batch["history"], batch["current"], batch["future"], batch["valid"])


@torch.no_grad()
def calibrate(actor, base, direction, calibration, target, sign, response):
    vector_to_parameters(base.clone(), actor.parameters())
    initial = means(actor, calibration)
    amount = sign*target/response
    for iteration in range(8):
        vector_to_parameters(base+amount*direction, actor.parameters())
        achieved = float((means(actor, calibration)-initial).square().mean().sqrt())
        if not np.isfinite(achieved) or achieved <= 0: raise ValueError("invalid parameter-direction calibration")
        if abs(achieved-target) <= .001*target:
            return amount, achieved, iteration+1
        amount *= target/achieved
    raise ValueError("fixed-input parameter step did not reach prescribed RMS")


def inherited_record(record, folder):
    record = copy.deepcopy(record)
    record["file"] = str(folder/record["file"])
    record["behavior"]["checkpoint"] = str(folder/record["behavior"]["checkpoint"])
    return record


def run(args):
    started = time.perf_counter()
    output, diagnostic_path = Path(args.output).resolve(), Path(args.source).resolve()
    charter = json.loads((output/"config.json").read_bytes())
    if digest(diagnostic_path/"report.json") != charter["diagnostic_report_sha256"]:
        raise ValueError("feedback-response diagnostic changed")
    diagnostic = json.loads((diagnostic_path/"report.json").read_bytes())
    action_path = Path(diagnostic["source_study"])
    if digest(action_path/"report.json") != diagnostic["source_report_sha256"]: raise ValueError("action-response source changed")
    action_report = json.loads((action_path/"report.json").read_bytes())
    baseline_path = Path(action_report["source_study"])
    if digest(baseline_path/"report.json") != charter["baseline_report_sha256"]: raise ValueError("baseline study changed")
    baselines = json.loads((baseline_path/"report.json").read_bytes())
    source = Path(baselines["source_study"])
    if digest(source/"report.json") != charter["source_report_sha256"]: raise ValueError("learning source changed")
    previous = json.loads((source/"report.json").read_bytes())
    learning = {**previous["config"], "actor_critic_tail": False}
    config = {**learning, **charter}
    torch.set_num_threads(learning["cpu_threads"]); torch.use_deterministic_algorithms(True)
    manifest, references = load_references(baselines["references"])
    if digest(Path(baselines["references"])/"manifest.json") != previous["reference_manifest_sha256"]:
        raise ValueError("reference manifest changed")
    runtime = PhysicsRuntime(args.scene, manifest["layout"]["dt_s"])
    records, rows, baseline_trials = [], [], []
    source_records = {r["episode_id"]: r for r in previous["physical_records"]}
    baseline_records = {r["episode_id"]: r for r in baselines["physical_records"]}
    (output/"directions").mkdir()
    for method in charter["methods"]:
        for seed in charter["seeds"]:
            original = next(r for r in previous["runs"] if r["method"]==method and r["seed"]==seed)
            old = next(r for r in baselines["runs"] if r["method"]==method and r["seed"]==seed)
            actor_path, model_path = Path(old["before_checkpoint"]), Path(old["model_checkpoint"])
            if digest(actor_path) != old["before_sha256"] or digest(model_path) != old["model_sha256"]:
                raise ValueError("frozen actor/model changed")
            actor, geometry, _ = load_reference_actor(actor_path)
            model, _ = load_model(model_path)
            for p in model.parameters(): p.requires_grad_(False)
            frozen_model, base_state = state_digest(model), state_digest(actor)
            base = parameters_to_vector(actor.parameters()).detach().clone()
            schedule = ReferenceSchedule(references, geometry, [0, 500, 1000])
            training_ids = original["cycles"][-1]["training_episode_ids"]
            training = join_batches([restore_collected_batch(source, source_records[i], actor, schedule, learning) for i in training_ids])
            def sampled(count, seed_base):
                generator = torch.Generator().manual_seed(seed_base+seed)
                ids = torch.randint(len(training["state"]), (count,), generator=generator)
                return take(training, ids), ids.tolist()
            gradient_batch, origin_ids = sampled(charter["gradient_origin_samples"], charter["gradient_origin_seed_base"])
            calibration, calibration_ids = sampled(charter["calibration_origin_samples"], charter["calibration_origin_seed_base"])
            gradients, forwards, active = {}, {}, {}
            for route in charter["gradient_routes"]:
                actor.zero_grad(set_to_none=True)
                objective, steps = imagined_objective(model, actor, None, gradient_batch, geometry, schedule,
                    {**learning, "actor_feedback_gradient": route})
                objective.backward()
                gradient = torch.cat([(p.grad if p.grad is not None else torch.zeros_like(p)).flatten() for p in actor.parameters()]).detach()
                if not torch.isfinite(gradient).all() or float(gradient.norm()) <= 0: raise ValueError("invalid actor parameter direction")
                gradients[route], forwards[route], active[route] = gradient, objective.detach().clone(), steps
            if not torch.equal(forwards["full"], forwards["stop-policy-inputs"]) or active["full"] != active["stop-policy-inputs"]:
                raise ValueError("backward-route ablation changed the forward controller")
            cosine = float(torch.nn.functional.cosine_similarity(gradients["full"][None], gradients["stop-policy-inputs"][None]))
            old_by_clip = {c["clip_index"]: c for c in old["comparisons"]}
            baseline_returns = []
            for clip_index in charter["probe_clip_indices"]:
                c = old_by_clip[clip_index]
                record = inherited_record(baseline_records[c["before_episode_id"]], baseline_path)
                if record["behavior"]["sha256"] != old["before_sha256"]: raise ValueError("baseline actor mismatch")
                records.append(record); baseline_trials.append(c["before_trial"]); baseline_returns.append(c["actual_before"])
            for route in charter["gradient_routes"]:
                vector_to_parameters(base.clone(), actor.parameters())
                direction = gradients[route]/gradients[route].norm()
                direction_path = output/"directions"/f"{method}-seed-{seed}-{route}.pt"
                torch.save(dict(format="moonrobo.g1-reference-parameter-direction.v1", direction=direction,
                    base_actor_sha256=old["before_sha256"], parameter_names=[n for n, _ in actor.named_parameters()],
                    gradient_route=route, gradient_norm=float(gradients[route].norm())), direction_path)
                initial = means(actor, calibration)
                vector_to_parameters(base+.001*direction, actor.parameters())
                response = float((means(actor, calibration)-initial).square().mean().sqrt())/.001
                if not np.isfinite(response) or response < 1e-8: raise ValueError("parameter direction has no calibration response")
                vector_to_parameters(base.clone(), actor.parameters())
                outcomes = []
                for amplitude in charter["logit_rms_steps"]:
                    for sign in charter["probe_signs"]:
                        coefficient, achieved, iterations = calibrate(actor, base, direction, calibration, amplitude, sign, response)
                        with torch.no_grad():
                            predicted_after = float(imagined_objective(model, actor, None, gradient_batch, geometry, schedule,
                                {**learning, "actor_feedback_gradient": "full"})[0])
                        behavior = dict(checkpoint=str(actor_path), sha256=old["before_sha256"],
                            direction_file=str(direction_path), direction_sha256=digest(direction_path), coefficient=coefficient)
                        trials, returns_list = [], []
                        folder = output/method/f"seed-{seed}"
                        role = f"gradient-{route}-amp-{amplitude}-sign-{sign}"
                        for clip_index in charter["probe_clip_indices"]:
                            batch, record, trial = collect_episode(runtime, references, schedule, actor, geometry, learning,
                                clip_index, 0, seed, 5, role, folder, behavior)
                            record["file"] = str(folder/record["file"])
                            rewards = batch["reward"].double()
                            weights = learning["gamma"]**torch.arange(len(rewards), dtype=torch.float64)
                            returns_list.append(dict(clip_index=clip_index, prefix_return=float((rewards[:32]*weights[:32]).sum()),
                                full_return=float((rewards*weights).sum())))
                            records.append(record); trials.append(trial)
                        outcomes.append(dict(target_logit_rms=amplitude, achieved_logit_rms=achieved, sign=sign,
                            coefficient=coefficient, calibration_iterations=iterations, predicted_after=predicted_after,
                            predicted_change=predicted_after-float(forwards[route]), trials=trials, returns=returns_list,
                            mean_prefix_change=float(np.mean([r["prefix_return"]-b["prefix_return"] for r, b in zip(returns_list, baseline_returns)])),
                            mean_full_change=float(np.mean([r["full_return"]-b["full_return"] for r, b in zip(returns_list, baseline_returns)]))))
                vector_to_parameters(base.clone(), actor.parameters())
                row = dict(method=method, seed=seed, gradient_route=route, base_actor=str(actor_path), base_actor_sha256=old["before_sha256"],
                    model_checkpoint=str(model_path), model_sha256=old["model_sha256"], training_episode_ids=training_ids,
                    gradient_origin_indices=origin_ids, calibration_origin_indices=calibration_ids,
                    equal_forward_objective=True, forward_objective=float(forwards[route]), active_imagined_steps=active[route],
                    gradient_norm=float(gradients[route].norm()), route_gradient_cosine=cosine,
                    full_gradient_projection=float((gradients["full"]*direction).sum()),
                    surrogate_gradient_projection=float((gradients["stop-policy-inputs"]*direction).sum()),
                    direction_file=str(direction_path.relative_to(output)), direction_sha256=digest(direction_path),
                    outcomes=outcomes, trials=[t for o in outcomes for t in o["trials"]], baseline_returns=baseline_returns)
                rows.append(row)
                print(json.dumps(dict(event="gradient-route-finished", method=method, seed=seed, route=route, cosine=cosine,
                    changes=[dict(amplitude=o["target_logit_rms"], sign=o["sign"], prefix=o["mean_prefix_change"], full=o["mean_full_change"]) for o in outcomes])), flush=True)
            if state_digest(model) != frozen_model or state_digest(actor) != base_state: raise ValueError("probe did not restore frozen base")
    report = dict(format="moonrobo.g1-reference-gradient-route.v1", config=config, source_study=str(source), source_report_sha256=digest(source/"report.json"),
        diagnostic_study=str(diagnostic_path), diagnostic_source_sha256=digest(diagnostic_path/"report.json"),
        baseline_study=str(baseline_path), baseline_report_sha256=digest(baseline_path/"report.json"),
        references=baselines["references"], reference_manifest_sha256=previous["reference_manifest_sha256"],
        initial=dict(role="same-seed-cycle-5-starting-policies", trials=baseline_trials), runs=rows, physical_records=records,
        new_physical_records=144, reused_physical_records=18, provider_sha256=digest(__file__), provider_seconds=time.perf_counter()-started,
        physical_execution_allowed=False, release_qualified=False, scope=charter["budget_and_selection"])
    (output/"report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["source", "scene", "output"]: parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
