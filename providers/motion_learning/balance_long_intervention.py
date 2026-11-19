"""Long teacher/channel interventions on the remaining wave and joint-sine failures."""
import argparse
import gzip
import json
from pathlib import Path
import time

import numpy as np
import torch

from balance_features import ObservationAnkleFeedback, ObservationBalanceHistory
from balance_intervention import blend_actions, joint_groups
from cpu_physics import PhysicsRuntime
from learned_balance import load_learned_balance
from learned_balance_study import digest, summary
from temporal_actor import TemporalRunner


def prior_learned(fit_folder, long_folder):
    result = {}
    for folder, scope in [(long_folder, "thirty-second-development"), (fit_folder, "train-family-audit")]:
        report = json.loads((folder / "report.json").read_bytes())
        if digest(folder / "evaluation-physics.jsonl.gz") != report["evaluation_log_sha256"]:
            raise ValueError("prior physical evaluation changed")
        with gzip.open(folder / "evaluation-physics.jsonl.gz", "rt") as stream:
            for line in stream:
                row = json.loads(line)
                if row["mode"] != "full":
                    continue
                for episode, trial in zip(row["dataset"]["episodes"], row["trials"]):
                    wanted = trial["scope"] == scope and (trial["case_id"] == "wave" if folder == long_folder else
                        trial["case_id"].startswith("joint-sines-"))
                    if wanted:
                        result[(row["seed"], trial["case_id"], trial["seed"])] = episode["steps"]
    return result


def probe(runtime, parent, head, geometry, spec, case, reset, mode, config, teacher_factory):
    teacher = teacher_factory()
    groups = joint_groups(runtime.names)
    runner = None if parent is None else TemporalRunner(runtime, parent, case, reset)
    history = None if geometry is None else ObservationBalanceHistory(geometry, runtime.dt, window=None)
    lower, upper = runtime.model.actuator_ctrlrange.T
    fixed = None if spec is None else ObservationAnkleFeedback(spec, teacher.config, lower, upper)
    segments, measurements = {}, []
    last = None
    index = 0
    def predict(obs, goal):
        nonlocal index, last
        oracle = teacher(obs, goal)
        rotation, support, error = teacher.measurements()
        local_error, local_velocity = rotation.T @ error, rotation.T @ teacher.velocity
        action = oracle
        feature = learned = derived = student = None
        if runner is not None:
            student = runner(obs, goal)
            with torch.no_grad():
                observed, target = torch.tensor(obs, dtype=torch.float32), torch.tensor(goal, dtype=torch.float32)
                feature = history(observed)
                learned = head(observed, target, feature).numpy()
                derived = fixed(observed, target, feature).numpy()
            action = student.copy()
            if mode == "learned_full":
                action[head.indices] = learned
            elif mode == "derived_fixed_ankle":
                action[head.indices] = derived
            else:
                group = {"oracle_ankle": "ankle", "oracle_ankle_waist": "ankle_waist", "oracle_lower": "lower"}[mode]
                action = blend_actions(student, oracle, groups[group])
        phase = "first-ten-seconds" if index * runtime.dt < 10 else "after-ten-seconds"
        if phase not in segments:
            segments[phase] = dict(points=0, ankle_saturated=0, oracle_ankle_saturated=0,
                action_squared={key: 0. for key in ["parent_ankle", "derived_ankle", "learned_ankle", "parent_other"]},
                velocity_squared=0., feature_points=0)
        stats = segments[phase]; stats["points"] += 1
        bound = teacher.config["residual_bound_rad"]
        stats["ankle_saturated"] += int(np.sum(np.abs(action[groups["ankle"]] - goal[groups["ankle"]]) >= bound - 2e-6))
        stats["oracle_ankle_saturated"] += int(np.sum(np.abs(oracle[groups["ankle"]] - goal[groups["ankle"]]) >= bound - 2e-6))
        if runner is not None:
            for name, actual in [("parent_ankle", student[groups["ankle"]]), ("derived_ankle", derived), ("learned_ankle", learned)]:
                # Head order is left pitch/roll then right pitch/roll, matching the model ankle group.
                stats["action_squared"][name] += float(np.square(actual - oracle[groups["ankle"]]).sum())
            other = [i for i in range(runtime.model.nu) if i not in groups["ankle"]]
            stats["action_squared"]["parent_other"] += float(np.square(student[other] - oracle[other]).sum())
            stats["velocity_squared"] += float(np.square(feature.numpy()[3:] - local_velocity).sum())
            stats["feature_points"] += 1
        last = dict(step=index, time_s=index*runtime.dt, root_height_m=float(runtime.data.xpos[runtime.root, 2]),
            upright_z=float(rotation[2, 2]), local_com_error_m=local_error.tolist(),
            true_filtered_velocity_m_s=local_velocity.tolist(), foot_site_height_m=runtime.data.site_xpos[teacher.feet, 2].tolist(),
            support_m=support.tolist(), contacts=int(runtime.data.ncon),
            actual_ankle=action[groups["ankle"]].tolist(), oracle_ankle=oracle[groups["ankle"]].tolist(),
            actual_waist_pitch=action[groups["ankle_waist"][-1:]].tolist(),
            oracle_waist_pitch=oracle[groups["ankle_waist"][-1:]].tolist(),
            joint_rmse_by_group_rad={g: float(np.sqrt(np.square(np.asarray(obs)[ids] - goal[ids]).mean()))
                for g, ids in groups.items()},
            observation_feature=None if feature is None else feature.tolist(),
            derived_ankle=None if derived is None else derived.tolist(),
            learned_ankle=None if learned is None else learned.tolist())
        if index % config["diagnostic_stride"] == 0:
            measurements.append(last)
        index += 1
        return action
    episode, trial = runtime.rollout(case, reset, "policy", config["duration_s"],
        config["fall_height_m"], config["fall_upright_z"], policy=predict)
    if measurements[-1]["step"] != last["step"]:
        measurements.append(last)
    for stats in segments.values():
        stats["ankle_saturation_fraction"] = stats["ankle_saturated"] / (4*stats["points"])
        stats["oracle_ankle_saturation_fraction"] = stats["oracle_ankle_saturated"] / (4*stats["points"])
        if stats["feature_points"]:
            stats["action_rmse_rad"] = {key: (value/(stats["feature_points"] * (25 if key == "parent_other" else 4)))**.5
                for key, value in stats["action_squared"].items()}
            stats["velocity_rmse_m_s"] = (stats["velocity_squared"]/(3*stats["feature_points"]))**.5
    return episode, {k: v for k, v in trial.items() if k != "replay"}, dict(segments=segments, measurements=measurements)


def run(args):
    import teacher_feedback
    config = json.loads(Path(args.config).read_bytes())
    fit, long = Path(args.study), Path(args.long)
    experiment, collection, selected = [json.loads((fit / name).read_bytes()) for name in ["experiment.json", "collection.json", "teacher.json"]]
    if digest(teacher_feedback.__file__) != selected["provider_sha256"]:
        raise ValueError("teacher implementation changed")
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    prior = prior_learned(fit, long)
    wave = next(c for c in experiment["cases"] if c["id"] == "wave")
    sines = [c for c in collection["cases"] if c["motion"] == "random_joint_sines"]
    if len(prior) != 15 or len(sines) != 3:
        raise ValueError("missing predeclared prior conditions")
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    factory = lambda: teacher_feedback.BalanceTeacher(runtime, selected["parameters"])
    rows, start, repeated = [], time.perf_counter(), 0
    log = output / "intervention-physics.jsonl.gz"
    with gzip.open(log, "wt", compresslevel=6) as stream:
        for seed in [*config["seeds"], None]:
            if seed is None:
                parent = head = geometry = spec = None
                modes = ["teacher_all"]
                conditions = [(wave, r, None) for r in config["wave_reset_seeds"]]
                conditions += [(c, config["sine_reset_seed_base"] + 10000*s, s) for s in config["seeds"] for c in sines]
            else:
                path = fit / "policy" / f"actor-full-seed-{seed}.pt"
                parent, head, geometry, metadata = load_learned_balance(path); spec = metadata["kinematics"]
                initial = {k: v.clone() for k, v in parent.state_dict().items()}
                initial_head = {k: v.clone() for k, v in head.state_dict().items()}
                modes = config["modes"]
                conditions = [(wave, r, seed) for r in config["wave_reset_seeds"]]
                conditions += [(c, config["sine_reset_seed_base"] + 10000*seed, seed) for c in sines]
            for mode in modes:
                episodes, trials, diagnostics = [], [], []
                for case, reset, context_parent in conditions:
                    episode, trial, diagnostic = probe(runtime, parent, head, geometry, spec, case, reset, mode, config, factory)
                    if mode == "learned_full":
                        original = prior[(seed, case["id"], reset)]
                        if len(episode["steps"]) < len(original):
                            raise ValueError("shadow probes shortened the original learned episode")
                        for old, new in zip(original, episode["steps"]):
                            if any(old[k] != new[k] for k in old if k != "truncated"):
                                raise ValueError("shadow probes changed recorded learned physics")
                        repeated += 1
                    episode["id"] += f'-long-intervention-{seed}-{mode}'
                    trial.update(episode_id=episode["id"], scope="wave-development" if case["id"] == "wave" else "sine-training-family-audit",
                        context_parent_seed=context_parent)
                    episodes.append(episode); trials.append(trial); diagnostics.append(diagnostic)
                stream.write(json.dumps(dict(seed=seed, mode=mode, dataset=runtime.dataset(episodes, experiment["source_revision"]),
                    trials=trials, diagnostics=diagnostics), allow_nan=False) + "\n"); stream.flush()
                row = dict(seed=seed, mode=mode, episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes),
                    summaries={scope: summary([t for t in trials if t["scope"] == scope]) for scope in ["wave-development", "sine-training-family-audit"]},
                    trials=trials, segments=[dict(case_id=t["case_id"], seed=t["seed"], scope=t["scope"], **d["segments"]) for t, d in zip(trials, diagnostics)],
                    checkpoint_sha256=None if seed is None else digest(path))
                rows.append(row)
                print(json.dumps({k: v for k, v in row.items() if k not in ["trials", "segments"]}), flush=True)
                if parent is not None and (any(not torch.equal(v, parent.state_dict()[k]) for k, v in initial.items()) or
                    any(not torch.equal(v, head.state_dict()[k]) for k, v in initial_head.items())):
                    raise ValueError("interventions changed the frozen model")
    pooled = []
    for mode in [*config["modes"], "teacher_all"]:
        for scope in ["wave-development", "sine-training-family-audit"]:
            trials = [t for row in rows if row["mode"] == mode for t in row["trials"] if t["scope"] == scope]
            pooled.append(dict(mode=mode, scope=scope, **summary(trials)))
    report = dict(format="moonrobo.g1-balance-long-intervention.v1", config=config, rows=rows, pooled=pooled,
        exact_prior_learned_episodes=repeated, actor_and_head_unchanged=True,
        fit_report_sha256=digest(fit / "report.json"), long_report_sha256=digest(long / "report.json"),
        teacher_sha256=digest(fit / "teacher.json"), provider_sha256=digest(__file__), physics_log_sha256=digest(log),
        wall_seconds=time.perf_counter()-start, learned_policy_qualified=False, physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(pooled=pooled, wall_seconds=report["wall_seconds"])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "study", "long", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
