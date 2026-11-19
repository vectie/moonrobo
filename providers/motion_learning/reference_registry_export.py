"""Build compact platform traces from sealed-candidate physics and motion arrays."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import mujoco
import numpy as np

from cpu_physics import PhysicsRuntime


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def trial_summary(trials):
    return dict(trials=len(trials), falls=sum(t["failed"] for t in trials),
        mean_survival_s=sum(t["simulated_seconds"] for t in trials)/len(trials),
        mean_joint_rmse_rad=sum(t["joint_rmse_rad"] for t in trials)/len(trials))


def trace_trial(runtime, reference, record, trial, arrays, include_reference):
    m, d = runtime.model, runtime.data
    m.geom_friction[:, 0] = record["context"][0]
    m.pair_friction[:, :2] = record["context"][0]
    origin = record["origin_step"]
    replay = []
    root_index = runtime.root-1
    for i, state in enumerate(arrays["next_state"]):
        d.qpos[:], d.qvel[:], d.act[:] = state[:m.nq], state[m.nq:m.nq+m.nv], state[m.nq+m.nv:]
        mujoco.mj_normalizeQuat(m, d.qpos)
        d.ctrl[:] = arrays["applied_action"][i]
        mujoco.mj_forward(m, d)
        desired = reference["body_position"][origin+i+1]
        target = reference["state"][origin+i+1]
        replay.append(dict(time_s=(i+1)*runtime.dt, root_height_m=float(d.xpos[runtime.root, 2]),
            upright_z=float(d.xmat[runtime.root].reshape(3, 3)[2, 2]), contacts=int(d.ncon),
            root_position_error_m=float(np.linalg.norm(d.xpos[runtime.root]-desired[root_index])),
            body_position_error_m=float(np.sqrt(np.mean(np.sum((d.xpos[1:]-desired)**2, axis=-1)))),
            root_orientation_error_rad=float(np.arccos(np.clip((np.trace(reference["body_rotation"][origin+i+1, root_index] @ d.xmat[runtime.root].reshape(3, 3).T)-1)/2, -1, 1))),
            joint_rmse_rad=float(np.sqrt(np.mean((state[runtime.q_indices]-target[runtime.q_indices])**2)))))
    result = dict(trial, seed=reference["source_reset_seed"], reference_start_time_s=origin*runtime.dt,
        end_reason="fall" if trial["failed"] else "time_limit", replay=replay)
    if include_reference:
        result["reference_replay"] = [dict(time_s=(i-origin)*runtime.dt,
            root_height_m=float(reference["body_position"][i, root_index, 2]),
            upright_z=float(reference["body_rotation"][i, root_index, 2, 2]))
            for i in range(origin+1, len(reference["state"]))]
    return result


def run(args):
    source, references, output = Path(args.study), Path(args.references), Path(args.output)
    report = json.loads((source/"report.json").read_bytes())
    proof = json.loads(Path(args.verification).read_bytes())
    if proof["source_report_sha256"] != digest(source/"report.json") or not proof["native_verification"]["all_episodes_validated"]:
        raise ValueError("reference registration needs matching complete native verification")
    manifest = json.loads((references/"manifest.json").read_bytes())
    if digest(references/"manifest.json") != report["reference_manifest_sha256"]:
        raise ValueError("reference manifest changed")
    runtime = PhysicsRuntime(args.scene, manifest["layout"]["dt_s"])
    loaded = {}
    for clip in manifest["clips"]:
        if digest(references/clip["file"]) != clip["sha256"]:
            raise ValueError("reference clip changed")
        with np.load(references/clip["file"], allow_pickle=False) as archive:
            loaded[clip["id"]] = {**dict(archive), "source_reset_seed": clip["source_reset_seed"]}
    (output/"policy").mkdir(parents=True, exist_ok=True)
    (output/"collection").mkdir(exist_ok=True)
    materialized = {}
    representative = False
    for evaluation in report["evaluations"]+[report["baseline"]]:
        trials = {t["episode_id"]: t for t in evaluation["trials"]}
        converted = []
        for record in evaluation["records"]:
            if digest(source/record["file"]) != record["sha256"]:
                raise ValueError("recorded reference physics changed")
            with np.load(source/record["file"], allow_pickle=False) as archive:
                a = dict(archive)
            reference = loaded[record["reference_id"]]
            converted.append(trace_trial(runtime, reference, record, trials[record["episode_id"]], a,
                include_reference=evaluation["label"] != "zero-output"))
            if not representative:
                from full_body_reference import FullBodyReference
                full = FullBodyReference(reference, manifest["layout"])
                origin = record["origin_step"]
                steps = [dict(time_s=i*runtime.dt, state=a["state"][i].tolist(), observation=a["observation"][i].tolist(),
                    applied_action=a["applied_action"][i].tolist(), next_state=a["next_state"][i].tolist(),
                    goal=full.goals[origin+i+1].tolist(), reward=float(a["reward"][i]),
                    terminated=bool(a["terminated"][i]), truncated=bool(a["truncated"][i])) for i in range(record["steps"])]
                episode = dict(id=record["episode_id"], source_family=record["source_family"], split=record["split"],
                    context=record["context"], steps=steps)
                dataset = runtime.dataset([episode], "reference-initialization")
                dataset.update(model_ref=manifest["model_ref"], goal_axes=manifest["layout"]["goal_axes"],
                    provenance="First evaluated policy episode only; fitted corpus is all source reference clips")
                with gzip.open(output/"collection/dataset.json.gz", "wt", compresslevel=6) as stream:
                    json.dump(dataset, stream, allow_nan=False, separators=(",", ":"))
                representative = True
        materialized[evaluation["label"]] = converted
    protocol = dict(kind="reference-remainder", clip_duration_s=30, origins_s=report["quality_target"]["origins_s"],
        scope=report["quality_target"]["scope"], duration_semantics="Each origin runs the remaining reference, 30/20/10 s; correlated known training clips")
    runs = []
    baseline = materialized["zero-output"]
    for fit, evaluation in zip(report["fits"], report["evaluations"]):
        seed = fit["seed"]
        candidates = materialized[evaluation["label"]]
        physics = dict(baseline=dict(summary=trial_summary(baseline), trials=baseline),
            candidate=dict(summary=trial_summary(candidates), trials=candidates,
                pooled_metrics=evaluation["summary"], quality=evaluation["quality"]),
            baseline_role="zero learned residual with the same fixed actual-minus-reference balance feedback; same 27 conditions reused for each training seed",
            evaluation_protocol=protocol, tracking_quality_target=report["quality_target"],
            replay_source="pose/contact reconstruction from recorded states; planned reference continues to its declared end even if a policy falls",
            physical_execution_allowed=False)
        (output/"policy"/f"physics-seed-{seed}.json").write_text(json.dumps(physics, allow_nan=False, separators=(",", ":")))
        runs.append(dict(seed=seed, selected_update=fit["updates"], baseline=trial_summary(baseline),
            candidate=trial_summary(candidates), qualifies=evaluation["quality"]["quality_passed"],
            checkpoint=Path(fit["checkpoint"]).name, latest_checkpoint=Path(fit["checkpoint"]).name))
    policy = dict(format="moonrobo.g1-reference-policy-fit.v1", runs=runs,
        experiment=dict(duration_s=30, control_dt_s=runtime.dt), evaluation_protocol=protocol,
        checkpoint_format="moonrobo.g1-reference-actor.v1", qualification_scope=report["quality_target"],
        seed_semantics="independent new reference encoder/decoder fits; shared fixed learned feedback and corpus",
        mean_joint_rmse_semantics="arithmetic mean of per-trial RMSE; physical report also retains pooled metrics",
        collection_role="first evaluated policy episode only; not fitted data. Complete fitted reference states and source-control labels in collection/reference clips",
        physical_record_role="all 108 saved numeric trajectories, linked by reference ID/hash and origin in reference-study.json",
        reference_manifest_sha256=report["reference_manifest_sha256"], research_report_sha256=digest(source/"report.json"),
        native_verification_sha256=digest(args.verification), release_qualified=False, physical_execution_allowed=False)
    (output/"policy/report.json").write_text(json.dumps(policy, indent=2, allow_nan=False))
    metadata = dict(format="moonrobo.g1-reference-registry-export.v1", provider_sha256=digest(__file__),
        source_report_sha256=digest(source/"report.json"), verification_sha256=digest(args.verification),
        runs=runs, physical_episodes=sum(len(e["records"]) for e in report["evaluations"]+[report["baseline"]]),
        reference_clips=len(manifest["clips"]), physical_execution_allowed=False)
    (output/"export.json").write_text(json.dumps(metadata, indent=2, allow_nan=False))
    print(json.dumps(metadata), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["study", "references", "verification", "scene", "output"]:
        parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
