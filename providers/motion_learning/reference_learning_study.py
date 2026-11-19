"""Run the frozen, matched full-reference MBRL/PPO comparison on CPU physics."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import torch

from cpu_physics import PhysicsRuntime
from dynamics import imagine
from full_body_reference import assess_tracking_quality
from reference_actor import load_reference_actor, load_references, save_reference_actor
from reference_learning import ReferenceModelReplay, collect_episode, fit_value, join_batches, optimize_model_actor, optimize_ppo_actor, ppo_advantages, restore_collected_batch, state_digest
from reference_task import ReferenceSchedule, ReferenceValue


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def summarize(trials):
    count = sum(t["steps"] for t in trials)
    metrics = ["joint_rmse_rad", "body_position_rmse_m", "root_position_rmse_m", "root_orientation_rmse_rad"]
    return dict(trials=len(trials), falls=sum(t["failed"] for t in trials), steps=count,
        mean_survival_s=sum(t["simulated_seconds"] for t in trials)/len(trials),
        **{name: (sum(t[name]**2*t["steps"] for t in trials)/count)**.5 for name in metrics})


@torch.no_grad()
def model_diagnostics(model, batch):
    results = []
    for horizon in [8, 32]:
        errors, persistence, count, start = 0., 0., 0, 0
        for length in batch["episode_lengths"]:
            for origin in range(0, length-horizon+1, max(1, horizon//2)):
                first = start+origin
                state = batch["state"][first:first+1]
                target = batch["next_state"][first:first+horizon][None]
                prediction = imagine(model, state, batch["action"][first:first+horizon][None], batch["context"][first:first+1])
                errors += float(((prediction-target)/model.state_scale).square().mean())
                persistence += float(((state[:, None]-target)/model.state_scale).square().mean()); count += 1
            start += length
        results.append(dict(horizon=horizon, windows=count, normalized_mse=errors/count if count else None,
            persistence_mse=persistence/count if count else None))
    return results


def checkpoint(output, actor, geometry, config, provenance):
    output.parent.mkdir(parents=True, exist_ok=True)
    save_reference_actor(output, actor, geometry.spec, .02, provenance,
        critic_status="paired separate moonrobo.g1-reference-value.v1 checkpoint; physical-return fitted")
    restored, _, _ = load_reference_actor(output)
    if state_digest(restored) != state_digest(actor): raise ValueError("reference learning actor reload changed tensors")
    return dict(checkpoint=str(output), sha256=digest(output), state_sha256=state_digest(actor))


def physical_group(runtime, references, schedule, actor, geometry, config, seed, cycle, role, folder, root, behavior, origins, clip_ids):
    batches, records, trials = [], [], []
    start = time.perf_counter()
    for clip in clip_ids:
        for origin in origins:
            batch, record, trial = collect_episode(runtime, references, schedule, actor, geometry, config,
                clip, origin, seed, cycle, role, folder, behavior)
            record["file"] = str((folder/record["file"]).relative_to(root))
            batches.append(batch); records.append(record); trials.append(trial)
    elapsed = time.perf_counter()-start
    print(json.dumps(dict(event="physics-group", role=role, seed=seed, cycle=cycle,
        folder=str(folder.relative_to(root)), summary=summarize(trials), seconds=elapsed)), flush=True)
    return join_batches(batches), records, trials, elapsed


def reused_record(record, source):
    record = copy.deepcopy(record)
    record["file"] = str(source/record["file"])
    record["behavior"]["checkpoint"] = str(source/record["behavior"]["checkpoint"])
    return record


def reused_run(run, source):
    run = copy.deepcopy(run)
    for checkpoint in [run["checkpoint"]]+[cycle["checkpoint"] for cycle in run["cycles"]]:
        checkpoint["checkpoint"] = str(source/checkpoint["checkpoint"])
    run["reused_from_study"] = str(source)
    return run


def baseline_record_ids(report, method):
    ids = {r["episode_id"] for r in report["physical_records"] if
        r["role"] in ["initial", "common-first-collection", "model-diagnostic"]}
    for run in report["runs"]:
        if run["method"] != method: continue
        ids.update(t["episode_id"] for t in run["trials"])
        for cycle in run["cycles"]: ids.update(cycle["training_episode_ids"])
    return ids


def verify_reconstructed_cycle(actor, model, value, old_cycle, source):
    path = Path(source)/old_cycle["checkpoint"]["checkpoint"]
    if digest(path) != old_cycle["checkpoint"]["sha256"]:
        raise ValueError("reconstructed baseline checkpoint bytes changed")
    old_actor, _, _ = load_reference_actor(path)
    cycle = old_cycle["cycle"]
    old_model = torch.load(path.parent/f"dynamics-cycle-{cycle}.pt", weights_only=True)["model"]
    old_value = torch.load(path.parent/f"value-cycle-{cycle}.pt", weights_only=True)["state_dict"]
    for name, current, previous in [("actor", actor.state_dict(), old_actor.state_dict()),
        ("model", model.state_dict(), old_model), ("value", value.state_dict(), old_value)]:
        if current.keys() != previous.keys() or any(not torch.equal(t, previous[k]) for k, t in current.items()):
            raise ValueError(f"reconstructed {name} differs at cycle {cycle}")
    return dict(cycle=cycle, actor_state_sha256=state_digest(actor), model_state_sha256=state_digest(model),
        value_state_sha256=state_digest(value), all_tensors_identical=True)


def run(args):
    setup_started = time.perf_counter()
    config = json.loads(Path(args.config).read_bytes())
    quality = json.loads(Path(args.quality).read_bytes())
    source = Path(args.reuse_study).resolve() if args.reuse_study else None
    anchored = config["format"] == "moonrobo.g1-reference-replay-anchor-charter.v1"
    extended = anchored or config["format"] == "moonrobo.g1-reference-extended-training-charter.v1"
    reconstruction_cycles = config.get("reconstruction_cycles", config.get("baseline_cycles", 0))
    baseline_method = config.get("reused_baseline_method", "prefix-only")
    previous = None
    if source is not None:
        if config["format"] not in ["moonrobo.g1-reference-state-origin-charter.v1", "moonrobo.g1-reference-extended-training-charter.v1", "moonrobo.g1-reference-replay-anchor-charter.v1"] or digest(source/"report.json") != config["reused_source_report_sha256"]:
            raise ValueError("wrong source for the actor-origin comparison")
        previous = json.loads((source/"report.json").read_bytes())
        if quality != previous["quality_target"]: raise ValueError("reused qualification target changed")
    if digest(args.actor) != config["incoming_actor_sha256"] or digest(Path(args.references)/"manifest.json") != config["reference_manifest_sha256"]:
        raise ValueError("matched comparison inputs changed")
    if quality["reference_manifest_sha256"] != config["reference_manifest_sha256"]:
        raise ValueError("matched quality target changed references")
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    manifest, references = load_references(args.references)
    incoming, geometry, incoming_meta = load_reference_actor(args.actor)
    runtime = PhysicsRuntime(args.scene, manifest["layout"]["dt_s"])
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    collection_origins = config.get("collection_origins_per_cycle_s", [[s] for s in config["collection_origins_s"]])
    origins = sorted({round(s/.02) for cycle in collection_origins for s in cycle} | {round(s/.02) for s in quality["origins_s"]})
    schedule = ReferenceSchedule(references, geometry, origins)
    all_clips = list(range(len(references)))
    setup_seconds = time.perf_counter()-setup_started
    started = time.perf_counter()
    initial_behavior = dict(checkpoint="initial/actor-zero-output.pt", sha256=digest(args.actor), state_sha256=state_digest(incoming))
    records, runs, common = [], [], []
    # One deterministic baseline, reused across all methods/seeds, not six
    # independently sampled initial policies or six baseline collections.
    if previous is None:
        _, raw, trials, seconds = physical_group(runtime, references, schedule, incoming, geometry, config,
            0, 0, "initial", output/"initial", output, initial_behavior,
            [round(s/.02) for s in quality["origins_s"]], all_clips)
        records += raw
        initial = dict(summary=summarize(trials), trials=trials, quality=assess_tracking_quality(trials, quality), seconds=seconds)
    else:
        initial = copy.deepcopy(previous["initial"])
        keep = baseline_record_ids(previous, baseline_method)
        records = [reused_record(r, source) for r in previous["physical_records"] if
            r["episode_id"] in keep]
        if len(records) != config.get("expected_reused_physical_records", 360): raise ValueError("expected complete frozen baseline evidence")
    reused_count = len(records) if previous is not None else 0
    if initial["quality"]["quality_passed"]: raise ValueError("incoming reference policy already meets the comparison target")
    for seed in config["seeds"]:
        first_origins = [round(s/.02) for s in collection_origins[0]]
        if previous is None:
            first, raw, common_trials, collection_seconds = physical_group(runtime, references, schedule, incoming, geometry,
                config, seed, 0, "common-first-collection", output/"common"/f"seed-{seed}", output, initial_behavior, first_origins, all_clips)
            records += raw; first_ids = [r["episode_id"] for r in raw]
            diagnostic, raw, _, diagnostic_seconds = physical_group(runtime, references, schedule, incoming, geometry,
                config, seed, 0, "model-diagnostic", output/"common"/f"seed-{seed}", output, initial_behavior,
                [first_origins[0]], config["model_diagnostic_clip_indices"])
            records += raw
        else:
            selected = lambda role: [r for r in records if r["role"]==role and r["seed"]==seed]
            first_records = selected("common-first-collection")
            first = join_batches([restore_collected_batch(output, r, incoming, schedule, config) for r in first_records])
            diagnostic = join_batches([restore_collected_batch(output, r, incoming, schedule, config) for r in selected("model-diagnostic")])
            first_ids = [r["episode_id"] for r in first_records]
            old_common = next(c for c in previous["common"] if c["seed"]==seed)
            collection_seconds, diagnostic_seconds = old_common["first_collection_seconds"], old_common["model_diagnostic_seconds"]
        relative_state = torch.cat((first["state"][:, :3]-schedule.positions[first["clip"], first["step"], 0], first["state"][:, 3:]), -1)
        torch.manual_seed(17000+seed)
        base_value = ReferenceValue(incoming, relative_state.mean(0), relative_state.std(0, unbiased=False).clamp_min(.05), len(references))
        common.append(dict(seed=seed, first_collection_episode_ids=first_ids, first_collection_seconds=collection_seconds,
            model_diagnostic_seconds=diagnostic_seconds, initial_actor_state_sha256=state_digest(incoming), initial_value_state_sha256=state_digest(base_value)))
        first_value_hashes = []
        for method in config["methods"]:
            if previous is not None and method==baseline_method:
                old = next(r for r in previous["runs"] if r["method"]==method and r["seed"]==seed)
                runs.append(reused_run(old, source))
                first_value_hashes.append(old["cycles"][0]["critic"]["state_sha256"])
                continue
            folder = output/method/f"seed-{seed}"; (folder/"policy").mkdir(parents=True, exist_ok=True)
            actor, value = copy.deepcopy(incoming), copy.deepcopy(base_value)
            buffers = {key: v.clone() for key, v in actor.named_buffers()}
            actor_optimizer = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
            value_optimizer = torch.optim.Adam(value.parameters(), lr=config["critic_learning_rate"])
            critic_random = torch.Generator().manual_seed(13000+seed)
            actor_random = torch.Generator().manual_seed(23000+seed)
            torch.manual_seed(27000+seed)
            model = ReferenceModelReplay(first, config, seed) if method!="ppo" else None
            cycles, behavior, training_ids = [], initial_behavior, []
            reconstruction = []
            old_run = next(r for r in previous["runs"] if r["method"]==baseline_method and r["seed"]==seed) if extended else None
            actor_steps = 0
            for cycle in range(config["cycles"]):
                if cycle == 0:
                    batch, fresh_ids, collection_cost = first, first_ids, collection_seconds
                elif extended and cycle < reconstruction_cycles:
                    old_cycle = old_run["cycles"][cycle]
                    fresh_ids = old_cycle["training_episode_ids"]
                    by_id = {r["episode_id"]: r for r in records}
                    batch = join_batches([restore_collected_batch(output, by_id[i], actor, schedule, config) for i in fresh_ids])
                    collection_cost = old_cycle["collection_seconds"]
                else:
                    current_origins = [round(s/.02) for s in collection_origins[cycle]]
                    batch, raw, _, collection_cost = physical_group(runtime, references, schedule, actor, geometry, config,
                        seed, cycle, "training", folder, output, behavior, current_origins, all_clips)
                    records += raw; fresh_ids = [r["episode_id"] for r in raw]
                training_ids += fresh_ids
                advantages = ppo_advantages(value, batch, schedule, config) if method=="ppo" else None
                critic_fit = fit_value(value, value_optimizer, batch, schedule, config, critic_random)
                if cycle == 0: first_value_hashes.append(critic_fit["state_sha256"])
                if model is not None:
                    if cycle: model.append(batch)
                    model_fit = model.fit()
                    diagnostic_start = time.perf_counter()
                    diagnostics = model_diagnostics(model.model, diagnostic)
                    diagnostic_score_seconds = time.perf_counter()-diagnostic_start
                    actor_config = {**config, "actor_critic_tail": method not in ["prefix-only", "replay-prefix", "replay-prefix-extended", "replay-prefix-anchor"],
                        "actor_origin_sampling": "trajectory-states" if method in ["replay-prefix", "replay-prefix-extended", "replay-prefix-anchor"] else "reset-starts"}
                    actor_fit = optimize_model_actor(model.model, actor, value, actor_optimizer, batch, geometry, schedule, actor_config, actor_random)
                else:
                    model_fit, diagnostics, diagnostic_score_seconds = None, None, 0.
                    actor_fit = optimize_ppo_actor(actor, actor_optimizer, batch, advantages, config, actor_random)
                actor_steps += actor_fit["actor_steps"]
                if extended and cycle < reconstruction_cycles:
                    reconstruction.append(verify_reconstructed_cycle(actor, model.model, value, old_run["cycles"][cycle], source))
                serialization_start = time.perf_counter()
                path = folder/"policy"/f"actor-cycle-{cycle+1}.pt"
                provenance = dict(method=method, seed=seed, cycle=cycle+1, actor_steps=actor_steps,
                    initialization_sha256=digest(args.actor), reference_manifest_sha256=config["reference_manifest_sha256"],
                    quality_sha256=digest(args.quality), behavior_training_episode_ids=training_ids)
                saved = checkpoint(path, actor, geometry, config, provenance)
                behavior = {**saved, "checkpoint": str(path.relative_to(output))}
                torch.save(dict(format="moonrobo.g1-reference-value.v1", state_dict=value.state_dict(),
                    paired_actor_sha256=saved["sha256"], provenance=provenance, physical_execution_allowed=False), folder/"policy"/f"value-cycle-{cycle+1}.pt")
                if model is not None:
                    torch.save(dict(format="moonrobo.residual-dynamics.v2", model=model.model.state_dict(),
                        config=dict(hidden_width=config["model_width"], horizontal_translation_invariant=True),
                        training_episode_ids=training_ids, diagnostic_records_fitted=False), folder/"policy"/f"dynamics-cycle-{cycle+1}.pt")
                serialization_seconds = time.perf_counter()-serialization_start
                if any(not torch.equal(v, dict(actor.named_buffers())[key]) for key, v in buffers.items()):
                    raise ValueError("reference RL changed the common policy normalization or frozen feedback")
                row = dict(cycle=cycle+1, collection_seconds=collection_cost, training_episode_ids=fresh_ids,
                    critic=critic_fit, model=model_fit, model_diagnostics=diagnostics, actor=actor_fit, checkpoint=behavior)
                row.update(model_diagnostic_score_seconds=diagnostic_score_seconds, serialization_seconds=serialization_seconds)
                cycles.append(row)
                print(json.dumps(dict(event="learning-cycle", method=method, seed=seed, **row)), flush=True)
                (output/"progress.json").write_text(json.dumps(dict(method=method, seed=seed, cycle=cycle+1,
                    completed_runs=len(runs), physical_records=len(records)), indent=2))
            # Independent reload, then fixed deterministic physical quality suite.
            restored, restored_geometry, _ = load_reference_actor(path)
            _, raw, final_trials, eval_seconds = physical_group(runtime, references, schedule, restored, restored_geometry,
                config, seed, config["cycles"], "final", folder, output, behavior,
                [round(s/.02) for s in quality["origins_s"]], all_clips)
            records += raw
            assessed = assess_tracking_quality(final_trials, quality)
            costs = dict(collection_seconds=sum(r["collection_seconds"] for r in cycles),
                critic_seconds=sum(r["critic"]["seconds"] for r in cycles),
                model_fit_seconds=sum(r["model"]["seconds"] for r in cycles if r["model"] is not None),
                actor_seconds=sum(r["actor"]["seconds"] for r in cycles),
                model_diagnostic_scoring_seconds=sum(r["model_diagnostic_score_seconds"] for r in cycles),
                serialization_seconds=sum(r["serialization_seconds"] for r in cycles),
                model_diagnostic_collection_seconds=diagnostic_seconds if model is not None else 0., final_evaluation_seconds=eval_seconds)
            result = dict(method=method, seed=seed, cycles=cycles, actor_optimizer_steps=actor_steps,
                summary=summarize(final_trials), trials=final_trials, quality=assessed, checkpoint=behavior, costs=costs,
                cost_to_target=dict(status="observed-passed-at-final-check" if assessed["quality_passed"] else "not-reached",
                    exact_first_crossing_measured=False, final_check_learning_seconds=sum(v for k, v in costs.items() if k!="final_evaluation_seconds")))
            if extended: result["baseline_reconstruction"] = reconstruction
            runs.append(result)
            print(json.dumps(dict(event="final-quality", method=method, seed=seed, summary=result["summary"], quality_passed=assessed["quality_passed"], costs=costs)), flush=True)
        if len(set(first_value_hashes)) != 1: raise ValueError("matched first-batch critic updates diverged between methods")
    report = dict(format="moonrobo.g1-reference-learning-comparison.v1", config=config, quality_target=quality,
        initialization_sha256=digest(args.actor), reference_manifest_sha256=config["reference_manifest_sha256"],
        initial=initial, common=common, runs=runs, physical_records=records,
        provider_sha256=digest(__file__), learning_provider_sha256=digest(Path(__file__).with_name("reference_learning.py")),
        task_provider_sha256=digest(Path(__file__).with_name("reference_task.py")),
        actor_provider_sha256=digest(Path(__file__).with_name("reference_actor.py")),
        setup_seconds=setup_seconds, provider_seconds=time.perf_counter()-started,
        historical_prior_cost="shared inherited artifact and prior development; not reconstructed as a complete end-to-end development cost",
        physical_execution_allowed=False, release_qualified=False,
        scope="Matched bounded reference learning with shared inherited prior; no exact first crossing, speedup, full SuperMimic reproduction or generalization claim")
    if previous is not None:
        report.update(reused_source_study=str(source), reused_source_report_sha256=digest(source/"report.json"),
            reused_physical_records=reused_count, new_physical_records=len(records)-reused_count,
            cost_scope=("Current provider wall time includes first-three-cycle reconstruction and new anchored-replay training/evaluation. Original collection costs remain in standalone accounting. Both final arms have six cycles and identical episode/update budgets; actual transition totals can differ. No successful quality-matched efficiency follows from failed policies." if anchored else
                "Current provider time includes deterministic refitting of the first three archived cycles, then new cycles and final evaluation. Reused collection costs retain original measurements in standalone learner accounting. This is a larger-budget comparison, not equal-budget efficiency." if extended else
                "Current provider time covers only the new trajectory-state arm and archive restoration. Reused baseline and shared collection costs retain original measurements; standalone learner accounting is separate from newly incurred CPU time."))
    (output/"report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(event="completed", physical_records=len(records), summaries=[dict(method=r["method"], seed=r["seed"], summary=r["summary"], quality_passed=r["quality"]["quality_passed"]) for r in runs], provider_seconds=report["provider_seconds"])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["config", "quality", "actor", "references", "scene", "output"]:
        parser.add_argument("--"+name, required=True)
    parser.add_argument("--reuse-study")
    run(parser.parse_args())
