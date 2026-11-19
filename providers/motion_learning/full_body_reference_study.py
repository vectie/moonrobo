"""Collect fresh train-only full-body references and test physical re-tracking."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import time

import mujoco
import numpy as np

from cpu_physics import PhysicsRuntime
from full_body_reference import FullBodyReference, capture_frame, layout_for, replay_reference


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(args):
    import teacher_feedback
    config = json.loads(Path(args.config).read_bytes())
    collection = json.loads(Path(args.collection).read_bytes())
    teacher_path = Path(args.teacher_study) / "teacher.json"
    teacher = json.loads(teacher_path.read_bytes())
    if digest(teacher_feedback.__file__) != teacher["provider_sha256"]:
        raise ValueError("reference source teacher implementation changed")
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    layout = layout_for(runtime)
    output = Path(args.output)
    (output / "clips").mkdir(parents=True, exist_ok=True)
    start_time = time.perf_counter()
    clips, collection_trials, replay_trials = [], [], []
    collection_seconds, replay_seconds = 0., 0.
    with gzip.open(output / "source-physics.jsonl.gz", "wt", compresslevel=6) as sources, \
            gzip.open(output / "replay-physics.jsonl.gz", "wt", compresslevel=6) as replays:
        for case in collection["cases"]:
            if case["split"] != "train":
                raise ValueError("new reference development accepts training families only")
            frames = []
            started = time.perf_counter()
            episode, trial = runtime.rollout(case, config["source_reset_seed"], "policy", config["duration_s"],
                config["fall_height_m"], config["fall_upright_z"],
                policy=teacher_feedback.BalanceTeacher(runtime, teacher["parameters"]),
                trace_callback=lambda rt, i, action, goal: frames.append(capture_frame(rt)))
            frames.append(capture_frame(runtime))
            collection_seconds += time.perf_counter()-started
            trial.pop("replay")
            collection_trials.append(trial)
            sources.write(json.dumps(dict(dataset=runtime.dataset([episode], collection["source_revision"]),
                trial=trial), allow_nan=False, separators=(",", ":"))+"\n")
            if trial["failed"]:
                raise ValueError("a failed source is retained but cannot become a successful reference")
            arrays = {key: np.stack([f[key] for f in frames]) for key in frames[0]}
            arrays.update(source_setpoint=np.asarray([s["applied_action"] for s in episode["steps"]]),
                source_goal=np.asarray([s["goal"] for s in episode["steps"]]),
                observation=np.asarray([s["observation"] for s in episode["steps"]]))
            clip_file = output / "clips" / (case["id"]+".npz")
            np.savez_compressed(clip_file, **arrays)
            # Read back actual artifact bytes. All replay and preview consumers
            # below use the serialized clip, rather than the collection objects.
            with np.load(clip_file, allow_pickle=False) as archive:
                reference = FullBodyReference(dict(archive), layout)
            clip = dict(id=case["id"], source_family=case["family"], split=case["split"],
                case=case, source_reset_seed=config["source_reset_seed"], source_episode_id=episode["id"],
                file=str(clip_file.relative_to(output)), sha256=digest(clip_file),
                frames=reference.frames, steps=reference.steps, duration_s=reference.steps*runtime.dt,
                source_teacher_sha256=digest(teacher_path), source_trial=trial)
            clips.append(clip)
            for origin_s in config["replay_origins_s"]:
                origin = round(origin_s/runtime.dt)
                if not np.isclose(origin*runtime.dt, origin_s):
                    raise ValueError("replay origin is not a control boundary")
                for mode in config["modes"]:
                    started = time.perf_counter()
                    replay, result = replay_reference(runtime, reference, case, origin, mode,
                        config["fall_height_m"], config["fall_upright_z"])
                    replay_seconds += time.perf_counter()-started
                    dataset = runtime.dataset([replay], collection["source_revision"])
                    dataset.update(dataset_id="g1-full-body-reference-"+case["id"],
                        goal_axes=layout["goal_axes"],
                        provenance="Fresh successful procedural teacher physics; full-body reference targets; source controls excluded from goal")
                    replays.write(json.dumps(dict(reference_id=case["id"], reference_sha256=clip["sha256"],
                        dataset=dataset, trial=result), allow_nan=False, separators=(",", ":"))+"\n")
                    replay_trials.append(result)
                    print(json.dumps(dict(reference_id=case["id"], **result)), flush=True)
    manifest = dict(format="moonrobo.g1-full-body-reference.v1", evidence_class="physics-simulation",
        model_ref=runtime.dataset([], collection["source_revision"])["model_ref"],
        scene_sha256=digest(runtime.scene), mujoco_version=mujoco.__version__, layout=layout,
        provenance="New training-family procedural teacher trajectories; no mocap, canonical/audit data, demo material or hardware",
        source_physics_sha256=digest(output / "source-physics.jsonl.gz"), clips=clips,
        physical_execution_allowed=False)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False))
    summaries = []
    for mode in config["modes"]:
        trials = [t for t in replay_trials if t["controller"] == mode]
        count = sum(t["steps"] for t in trials)
        metrics = ["joint_rmse_rad", "body_position_rmse_m", "root_position_rmse_m", "root_orientation_rmse_rad",
            "joint_speed_rmse_rad_per_s", "root_linear_speed_rmse_m_per_s", "root_angular_speed_rmse_rad_per_s"]
        summaries.append(dict(controller=mode, trials=len(trials), falls=sum(t["failed"] for t in trials),
            steps=count, simulated_seconds=sum(t["simulated_seconds"] for t in trials),
            requested_seconds=sum(t["requested_seconds"] for t in trials),
            max_state_component_error=max(t["max_state_component_error"] for t in trials),
            **{k: float(np.sqrt(sum(t[k]**2*t["steps"] for t in trials)/count)) for k in metrics}))
    report = dict(format="moonrobo.g1-full-body-reference-study.v1", config=config,
        manifest_sha256=digest(output / "manifest.json"), replay_sha256=digest(output / "replay-physics.jsonl.gz"),
        provider_sha256=digest(__file__), reference_provider_sha256=digest(Path(__file__).with_name("full_body_reference.py")),
        teacher_sha256=digest(teacher_path), collection_trials=collection_trials, replay_trials=replay_trials,
        summaries=summaries, collection_seconds=collection_seconds, replay_seconds=replay_seconds,
        provider_seconds=time.perf_counter()-start_time,
        training_updates=0, release_qualified=False, physical_execution_allowed=False,
        scope="Source-setpoint replay is a feasibility oracle, not a deployable or learned tracker. Joint-position baseline is not the sustained v2 actor. No learning-efficiency or motion generalization result.")
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(summaries=summaries, provider_seconds=report["provider_seconds"])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["config", "collection", "teacher-study", "scene", "output"]:
        parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
