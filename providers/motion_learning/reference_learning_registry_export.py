"""Numerically reconstruct registered RL candidate/baseline traces from physics."""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np

from cpu_physics import PhysicsRuntime
from full_body_reference import FullBodyReference
from reference_registry_export import digest, trace_trial, trial_summary


def comparison_baseline(report, method, seed):
    baseline_method = report["config"].get("reused_baseline_method", "prefix-only")
    if method == baseline_method:
        return report["initial"], "Shared zero-output prior"
    baseline = next(r for r in report["runs"] if r["method"]==baseline_method and r["seed"]==seed)
    if baseline_method == "prefix-only":
        role = "Fixed reset-only trained policy with the same training seed"
    elif baseline_method == "replay-prefix-extended":
        role = "Fixed six-cycle recent-FIFO trained policy with the same training seed"
    else:
        role = f"Fixed {len(baseline['cycles'])}-cycle trajectory-state trained policy with the same training seed"
    return baseline, role


def run(args):
    source, output = Path(args.study), Path(args.output)
    report = json.loads((source/"report.json").read_bytes())
    proof = json.loads(Path(args.verification).read_bytes())
    if proof["source_report_sha256"] != digest(source/"report.json") or not proof["native_verification"]["all_records_validated"]:
        raise ValueError("reference RL export requires complete matching native verification")
    refs = Path(json.loads((source/"charter.json").read_bytes())["references"])
    manifest = json.loads((refs/"manifest.json").read_bytes())
    if digest(refs/"manifest.json") != report["reference_manifest_sha256"]: raise ValueError("reference changed")
    loaded = {}
    for clip in manifest["clips"]:
        if digest(refs/clip["file"]) != clip["sha256"]: raise ValueError("clip changed")
        with np.load(refs/clip["file"], allow_pickle=False) as f:
            loaded[clip["id"]] = {**dict(f), "source_reset_seed": clip["source_reset_seed"]}
    runtime = PhysicsRuntime(args.scene, manifest["layout"]["dt_s"])
    records = {r["episode_id"]: r for r in report["physical_records"]}
    traces = {}
    def materialize(trials, planned):
        result = []
        for trial in trials:
            key = (trial["episode_id"], planned)
            if key not in traces:
                record = records[trial["episode_id"]]
                path = source/record["file"]
                if digest(path) != record["sha256"]: raise ValueError("physics changed")
                with np.load(path, allow_pickle=False) as f: arrays = dict(f)
                traces[key] = trace_trial(runtime, loaded[record["reference_id"]], record, trial, arrays, planned)
            result.append(traces[key])
        return result
    protocol = dict(kind="reference-remainder", clip_duration_s=30, origins_s=report["quality_target"]["origins_s"],
        scope=report["quality_target"]["scope"], duration_semantics="Remaining 30/20/10 s from known reference origins")
    runs = []
    for candidate in [r for r in report["runs"] if r["method"]==args.method]:
        seed = candidate["seed"]
        baseline, baseline_role = comparison_baseline(report, args.method, seed)
        base = materialize(baseline["trials"], False)
        selected = materialize(candidate["trials"], True)
        physics = dict(baseline=dict(summary=trial_summary(base), trials=base),
            candidate=dict(summary=trial_summary(selected), trials=selected, pooled_metrics=candidate["summary"], quality=candidate["quality"]),
            baseline_role=baseline_role,
            evaluation_protocol=protocol, tracking_quality_target=report["quality_target"],
            training=dict(method=args.method, actor_origin_sampling="reset-starts" if args.method=="prefix-only" else "trajectory-states",
                cycles=len(candidate["cycles"]), model_replay_mode=candidate["cycles"][-1]["model"].get("replay_mode", "recent-fifo"),
                model_replay_window_capacity=report["config"]["model_replay_windows"],
                initial_anchor_windows=candidate["cycles"][-1]["model"].get("anchor_windows", 0),
                shared_initial_actor_sha256=report["initialization_sha256"], source_study_sha256=digest(source/"report.json"),
                physical_records_new=report["new_physical_records"], physical_records_reused=report["reused_physical_records"]),
            replay_source="MuJoCo pose/contact reconstruction of float32 saved states; original scalar quality from float64 physics",
            physical_execution_allowed=False)
        (output/"policy"/f"physics-seed-{seed}.json").write_text(json.dumps(physics, allow_nan=False, separators=(",", ":")))
        runs.append(dict(seed=seed, selected_update=candidate["actor_optimizer_steps"], baseline=trial_summary(base),
            candidate=trial_summary(selected), qualifies=candidate["quality"]["quality_passed"],
            checkpoint=f"actor-seed-{seed}.pt", latest_checkpoint=f"actor-seed-{seed}.pt"))
    record = next(r for r in report["physical_records"] if r["role"]=="common-first-collection")
    with np.load(source/record["file"], allow_pickle=False) as f: arrays = dict(f)
    reference = FullBodyReference(loaded[record["reference_id"]], manifest["layout"])
    steps = [dict(time_s=i*runtime.dt, state=arrays["state"][i].tolist(), observation=arrays["observation"][i].tolist(),
        applied_action=arrays["applied_action"][i].tolist(), next_state=arrays["next_state"][i].tolist(),
        goal=reference.goals[record["origin_step"]+i+1].tolist(), reward=float(arrays["reward"][i]),
        terminated=bool(arrays["terminated"][i]), truncated=bool(arrays["truncated"][i])) for i in range(record["steps"])]
    dataset = runtime.dataset([dict(id=record["episode_id"], source_family=record["source_family"], split="train", context=record["context"], steps=steps)], "reference-learning-representative")
    dataset.update(model_ref=manifest["model_ref"], goal_axes=manifest["layout"]["goal_axes"],
        provenance="One common training episode only; all paired physical archives are separately registered")
    with gzip.open(output/"collection/dataset.json.gz", "wt", compresslevel=6) as stream:
        json.dump(dataset, stream, allow_nan=False, separators=(",", ":"))
    policy = dict(format="moonrobo.g1-reference-learning-fit.v1", runs=runs,
        experiment=dict(duration_s=30, control_dt_s=runtime.dt), evaluation_protocol=protocol,
        qualification_scope=report["quality_target"], method=args.method,
        checkpoint_format="moonrobo.g1-reference-actor.v1", training_scope="Shared inherited actor prior; independent seeded learning; known reference coverage",
        mean_joint_rmse_semantics="Arithmetic mean of trial RMSEs; pooled source metrics retained separately",
        collection_role=f"One common training episode, not the entire fitting corpus; all {len(records)} paired numeric archives are registered",
        release_qualified=False, physical_execution_allowed=False)
    (output/"policy/report.json").write_text(json.dumps(policy, indent=2, allow_nan=False))
    (output/"export.json").write_text(json.dumps(dict(format="moonrobo.g1-reference-learning-registry-export.v1", method=args.method,
        source_report_sha256=digest(source/"report.json"), verification_sha256=digest(args.verification),
        physical_episodes=len(records), reference_clips=len(loaded), runs=runs, physical_execution_allowed=False), indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["study", "verification", "scene", "method", "output"]: parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
