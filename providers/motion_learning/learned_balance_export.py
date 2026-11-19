"""Materialize fitted labels and recorded physics into the existing registry contract."""
import argparse
import gzip
import json
from pathlib import Path

import mujoco
import numpy as np
import torch

from balance_features import BalanceKinematics, make_spec
from cpu_physics import PhysicsRuntime
from learned_balance import LearnedAnkleHead, load_learned_balance
from learned_balance_study import digest, summary, train_points


def replay_from_recorded_states(runtime, episode):
    """Reconstruct geometry/contact trace without advancing or re-running a policy."""
    m, d = runtime.model, runtime.data
    replay = []
    # Contact geometry must use this episode's friction, like the original runtime.
    m.geom_friction[:, 0] = episode["context"][0]
    m.pair_friction[:, :2] = episode["context"][0]
    for step in episode["steps"]:
        state = np.asarray(step["next_state"])
        d.qpos[:], d.qvel[:], d.act[:] = state[:m.nq], state[m.nq:m.nq+m.nv], state[m.nq+m.nv:]
        mujoco.mj_forward(m, d)
        replay.append(dict(time_s=step["time_s"] + runtime.dt, qpos=d.qpos.tolist(), target=step["goal"],
            root_height_m=float(d.xpos[runtime.root, 2]), upright_z=float(d.xmat[runtime.root].reshape(3, 3)[2, 2]),
            contacts=int(d.ncon)))
    return replay


def read_evaluations(runtime, folder, report, short):
    if digest(folder / "evaluation-physics.jsonl.gz") != report["evaluation_log_sha256"]:
        raise ValueError("evaluation archive changed")
    result = {}
    with gzip.open(folder / "evaluation-physics.jsonl.gz", "rt") as stream:
        for line in stream:
            row = json.loads(line)
            trials = []
            for episode, recorded in zip(row["dataset"]["episodes"], row["trials"]):
                if short and recorded["scope"] != "canonical-development":
                    continue
                if episode["id"] != recorded["episode_id"] or len(episode["steps"]) != recorded["steps"]:
                    raise ValueError("recorded trial does not match its physics episode")
                trial = dict(recorded)
                if short:
                    trial["replay"] = replay_from_recorded_states(runtime, episode)
                trials.append(trial)
            result[(row["seed"], row["mode"])] = dict(summary=summary(trials), trials=trials,
                replay_source=("geometry/contact reconstruction from recorded next_state; no policy rerun" if short else
                               "captured during the physical rollout"))
    return result


def run(args):
    import teacher_feedback
    source, long, output = Path(args.study), Path(args.long), Path(args.output)
    fit = json.loads((source / "report.json").read_bytes())
    long_report = json.loads((long / "report.json").read_bytes())
    if long_report["fit_report_sha256"] != digest(source / "report.json"):
        raise ValueError("long evaluation belongs to another fitted study")
    config, collection, experiment, teacher, charter = [json.loads((source / name).read_bytes()) for name in
        ["config.json", "collection.json", "experiment.json", "teacher.json", "charter.json"]]
    if digest(teacher_feedback.__file__) != teacher["provider_sha256"]:
        raise ValueError("teacher relabeling source changed")
    intervention = Path(charter["source_intervention"]) / "intervention-physics.jsonl.gz"
    if digest(intervention) != fit["source_sha256"]:
        raise ValueError("training source changed")
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    geometry = BalanceKinematics(make_spec(runtime.model))
    obs, goals, labels, features, rows = train_points(runtime, geometry, intervention, config, collection,
        lambda: teacher_feedback.BalanceTeacher(runtime, teacher["parameters"]))
    if rows != json.loads((source / "training-sources.json").read_bytes()):
        raise ValueError("exported training manifest differs from the actual fit")
    for window, mode in [(10, "h10"), (None, "full")]:
        lower, upper = runtime.model.actuator_ctrlrange.T
        fitted = LearnedAnkleHead(runtime.names, lower, upper, config["residual_bound_rad"])
        fitted.fit(fitted.inputs(obs, features[window]), goals, labels, config["uncensored_margin_rad"])
        for seed in config["seeds"]:
            _, saved, _, _ = load_learned_balance(source / "policy" / f"actor-{mode}-seed-{seed}.pt")
            if any(not torch.equal(v, saved.state_dict()[k]) for k, v in fitted.state_dict().items()):
                raise ValueError("reconstructed training points do not reproduce the saved head exactly")
    common = output / "common"; common.mkdir(parents=True, exist_ok=True)
    selected = {r["episode_id"] for r in rows}
    offset, chunks = 0, 0
    training = common / "balance-training.jsonl.gz"
    with gzip.open(training, "wt", compresslevel=6) as destination, gzip.open(intervention, "rt") as stream:
        for line in stream:
            record = json.loads(line)
            episodes = [e for e in record["dataset"]["episodes"] if e["id"] in selected]
            if not episodes:
                continue
            targets = []
            for episode in episodes:
                count = len(episode["steps"])
                targets.append(labels[offset:offset+count].tolist()); offset += count
            dataset = {**record["dataset"], "episodes": episodes}
            if chunks == 0:
                with gzip.open(common / "dataset.json.gz", "wt", compresslevel=6) as representative:
                    json.dump(dataset, representative, allow_nan=False)
            destination.write(json.dumps(dict(source_parent_seed=record["seed"], source_mode=record["mode"],
                dataset=dataset, teacher_action_targets=targets,
                target_dtype="float32, exactly reproduces original fitted heads", role="train-only"), allow_nan=False) + "\n")
            chunks += 1
    if offset != len(labels) or chunks != 6:
        raise ValueError("incomplete training archive")
    metadata = dict(training_episodes=len(rows), training_points=len(labels), training_chunks=chunks,
        training_sha256=digest(training), representative_sha256=digest(common / "dataset.json.gz"),
        exact_refit_matches_all_six_heads=True, fit_report_sha256=digest(source / "report.json"),
        long_report_sha256=digest(long / "report.json"), provider_sha256=digest(__file__))
    for scope, folder, report, short in [("ten-second", source, fit, True), ("thirty-second", long, long_report, False)]:
        evaluations = read_evaluations(runtime, folder, report, short)
        for mode in ["h10", "full"]:
            destination = output / f"{scope}-{mode}" / "policy"
            destination.mkdir(parents=True, exist_ok=True)
            runs = []
            for seed in config["seeds"]:
                baseline, candidate = evaluations[(seed, "student")], evaluations[(seed, mode)]
                (destination / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline,
                    candidate=candidate, scope=scope+"-development", physical_execution_allowed=False), allow_nan=False))
                name = f"actor-{mode}-seed-{seed}.pt"
                qualifies = candidate["summary"]["falls"] == 0 and candidate["summary"]["mean_joint_rmse_rad"] <= config["max_mean_joint_rmse_rad"]
                runs.append(dict(seed=seed, selected_update=1, checkpoint=name, latest_checkpoint=name,
                    baseline=baseline["summary"], candidate=candidate["summary"], qualifies=qualifies,
                    checkpoint_sha256=digest(source / "policy" / name)))
            duration = 10 if short else 30
            policy = dict(format="moonrobo.g1-learned-balance-fit.v1", runs=runs,
                experiment={**experiment, "duration_s": duration}, mode=mode, window=10 if mode == "h10" else None,
                seed_semantics="frozen parent training seed; one shared deterministic fitted ankle head per arm",
                head_fit_count=1, selected_update_semantics="one closed-form fit; no optimizer/checkpoint selection",
                source_training=metadata, checkpoint_format="moonrobo.g1-learned-balance-actor.v1",
                qualification_scope=scope+"-development: zero falls and mean joint RMSE <= 0.15 rad",
                collection_role="representative first train chunk; complete train data and separate labels in balance-training.jsonl.gz",
                evaluation_role="complete recorded evaluation, including independent train-family audit for ten-second study",
                evaluation_log_sha256=report["evaluation_log_sha256"], release_qualified=False, physical_execution_allowed=False)
            (destination / "report.json").write_text(json.dumps(policy, indent=2, allow_nan=False))
        (common / f"{scope}-study.json").write_text(json.dumps(dict(fit=fit, evaluation=report, export=metadata), indent=2, allow_nan=False))
    (output / "export.json").write_text(json.dumps(metadata, indent=2, allow_nan=False))
    print(json.dumps(metadata), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["study", "long", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
