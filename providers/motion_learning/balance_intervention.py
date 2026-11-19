"""Frozen-policy balance-channel and teacher-memory interventions in MuJoCo."""
import argparse
from collections import deque
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from temporal_actor import TemporalRunner, load_temporal
from temporal_training import evaluate


class WindowTeacher:
    """Recompute the teacher's world-error EMA from at most N error frames."""
    def __init__(self, teacher, frames):
        self.teacher = teacher
        self.errors = deque(maxlen=frames - 1)

    def __call__(self, obs, goal):
        error = self.teacher.measurements()[2].copy()
        history = list(self.errors)
        velocity = np.zeros(3)
        for a, b in zip(history, history[1:]):
            velocity = .8 * velocity + .2 * (b - a) / self.teacher.runtime.dt
        self.teacher.velocity = velocity
        self.teacher.last_error = history[-1].copy() if history else None
        action = self.teacher(obs, goal)
        self.errors.append(error)
        return action


def joint_groups(names):
    ankle = [i for i, n in enumerate(names) if "_ankle_" in n]
    waist = [i for i, n in enumerate(names) if n == "waist_pitch_joint"]
    return dict(ankle=ankle, ankle_waist=ankle + waist,
        lower=[i for i, n in enumerate(names) if any(p in n for p in ["_hip_", "_knee_", "_ankle_"])],
        other=[i for i in range(len(names)) if i not in ankle + waist], all=list(range(len(names))))


def blend_actions(student, teacher, indices):
    action = student.copy()
    action[indices] = teacher[indices]
    return action


def probe_trial(runtime, actor, case, reset_seed, mode, config, teacher_factory):
    runner = TemporalRunner(runtime, actor, case, reset_seed)
    full = teacher_factory()
    windows = {str(n): WindowTeacher(teacher_factory(), n) for n in [1, 10, 50]}
    groups = joint_groups(runtime.names)
    errors = {name: np.zeros(runtime.model.nu) for name in ["student", "1", "10", "50"]}
    velocity_error = {name: 0. for name in windows}
    measurements, last_measurement, count = [], None, 0
    def predict(obs, goal):
        nonlocal count, last_measurement
        student = runner(obs, goal)
        teacher = full(obs, goal)
        alternatives = {name: window(obs, goal) for name, window in windows.items()}
        errors["student"][:] += np.square(student - teacher)
        rotation = full.measurements()[0]
        for name, value in alternatives.items():
            errors[name][:] += np.square(value - teacher)
            velocity_error[name] += float(np.square((rotation.T @ (windows[name].teacher.velocity - full.velocity))[:2]).sum())
        last_measurement = dict(step=count, time_s=count * runtime.dt,
            root_height_m=float(runtime.data.xpos[runtime.root, 2]),
            upright_z=float(rotation[2, 2]), local_com_error_m=(rotation.T @ full.last_error).tolist(),
            local_filtered_velocity_m_s=(rotation.T @ full.velocity).tolist(),
            h10_local_filtered_velocity_m_s=(rotation.T @ windows["10"].teacher.velocity).tolist(),
            student_ankle_waist=student[groups["ankle_waist"]].tolist(),
            teacher_ankle_waist=teacher[groups["ankle_waist"]].tolist(),
            h10_teacher_ankle_waist=alternatives["10"][groups["ankle_waist"]].tolist())
        if count % 5 == 0:
            measurements.append(last_measurement)
        count += 1
        if mode == "student":
            return student
        if mode in ["ankle", "ankle_waist", "lower"]:
            return blend_actions(student, teacher, groups[mode])
        if mode == "teacher":
            return teacher
        return alternatives[{"teacher_no_memory": "1", "teacher_h10": "10", "teacher_h50": "50"}[mode]]
    episode, trial = runtime.rollout(case, reset_seed, "policy", config["duration_s"],
        config["fall_height_m"], config["fall_upright_z"], policy=predict)
    if measurements[-1]["step"] != last_measurement["step"]:
        measurements.append(last_measurement)
    shadow = {}
    for name, squared in errors.items():
        shadow[name] = dict(per_joint_rmse_rad=np.sqrt(squared / count).tolist(),
            group_rmse_rad={group: float(np.sqrt(squared[ids].mean() / count)) for group, ids in groups.items()})
        if name != "student":
            shadow[name]["local_velocity_rmse_m_s"] = (velocity_error[name] / (2 * count)) ** .5
    return episode, trial, dict(samples=count, shadow=shadow, measurements=measurements)


def summarize(trials):
    return dict(trials=len(trials), falls=sum(t["failed"] for t in trials),
        mean_survival_s=float(np.mean([t["simulated_seconds"] for t in trials])),
        mean_joint_rmse_rad=float(np.mean([t["joint_rmse_rad"] for t in trials])))


def run(args):
    import teacher_feedback
    config, collection, experiment, teacher = [json.loads(Path(p).read_bytes()) for p in [args.config, args.collection, args.experiment, args.teacher]]
    if hashlib.sha256(Path(teacher_feedback.__file__).read_bytes()).hexdigest() != teacher["provider_sha256"]:
        raise ValueError("intervention teacher source changed")
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    groups = joint_groups(runtime.names)
    if [len(groups[g]) for g in ["ankle", "ankle_waist", "lower", "all"]] != [4, 5, 12, 29]:
        raise ValueError("expected declared G1 intervention channels")
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    source_report = json.loads((Path(args.policies) / "report.json").read_bytes())
    rows = []
    log_path = output / "intervention-physics.jsonl.gz"
    with gzip.open(log_path, "wt", compresslevel=6) as stream:
        for seed in config["seeds"]:
            path = Path(args.policies) / f"actor-seed-{seed}.pt"
            actor, metadata = load_temporal(path)
            source_row = next(r for r in source_report["runs"] if r["seed"] == seed)
            if metadata["selected_update"] != source_row["selected_update"]:
                raise ValueError("intervention parent selection differs")
            initial = {k: v.clone() for k, v in actor.state_dict().items()}
            # Direct repeats verify that shadow queries do not mutate physics.
            direct_student, direct_student_episodes = evaluate(runtime, experiment, config["canonical_reset_seeds"], actor)
            direct_teacher_episodes = []
            factory = lambda: teacher_feedback.BalanceTeacher(runtime, teacher["parameters"])
            for case in experiment["cases"]:
                for reset in config["canonical_reset_seeds"]:
                    episode, _ = runtime.rollout(case, reset, "policy", config["duration_s"], config["fall_height_m"],
                        config["fall_upright_z"], policy=factory())
                    direct_teacher_episodes.append(episode)
            for mode in config["modes"]:
                episodes, trials, diagnostics = [], [], []
                for scope, cases, resets in [
                        ("train", collection["cases"], [config["train_reset_seed_base"] + 10000 * seed]),
                        ("canonical-development", experiment["cases"], config["canonical_reset_seeds"])]:
                    canonical_index = 0
                    for case in cases:
                        for reset in resets:
                            episode, trial, diagnostic = probe_trial(runtime, actor, case, reset, mode, config, factory)
                            if scope == "canonical-development" and mode in ["student", "teacher"]:
                                direct = direct_student_episodes if mode == "student" else direct_teacher_episodes
                                if episode["steps"] != direct[canonical_index]["steps"]:
                                    raise ValueError("shadow teacher/actor changed direct canonical physics")
                                canonical_index += 1
                            episode["id"] += f"-policy-{seed}-{mode}-{scope}"
                            trial = {k: v for k, v in trial.items() if k != "replay"}
                            trial.update(scope=scope, mode=mode)
                            episodes.append(episode); trials.append(trial); diagnostics.append(diagnostic)
                dataset = runtime.dataset(episodes, collection["source_revision"])
                stream.write(json.dumps(dict(seed=seed, mode=mode, dataset=dataset, trials=trials, diagnostics=diagnostics), allow_nan=False) + "\n")
                summaries = {scope: summarize([t for t in trials if t["scope"] == scope]) for scope in ["train", "canonical-development"]}
                # Scalar shadow summaries share each trial's actual state/action
                # history; they do not splice observations from another mode.
                scalar_diagnostics = []
                for trial, diagnostic in zip(trials, diagnostics):
                    scalar_diagnostics.append(dict(case_id=trial["case_id"], reset_seed=trial["seed"], scope=trial["scope"],
                        samples=diagnostic["samples"], shadow=diagnostic["shadow"]))
                row = dict(seed=seed, mode=mode, summaries=summaries,
                    transitions=sum(len(e["steps"]) for e in episodes), episodes=len(episodes), diagnostics=scalar_diagnostics,
                    trials=trials, actor_sha256=hashlib.sha256(path.read_bytes()).hexdigest(), direct_baselines_match=True)
                rows.append(row)
                print(json.dumps({k: v for k, v in row.items() if k not in ["diagnostics", "trials"]}), flush=True)
            if any(not torch.equal(v, actor.state_dict()[k]) for k, v in initial.items()):
                raise ValueError("intervention mutated the incoming actor or normalization")
    report = dict(format="moonrobo.g1-balance-intervention.v1", config=config, rows=rows,
        joint_names=runtime.names, groups={name: [runtime.names[i] for i in ids] for name, ids in groups.items()},
        source_policy_report_sha256=hashlib.sha256((Path(args.policies) / "report.json").read_bytes()).hexdigest(),
        teacher_sha256=hashlib.sha256(Path(args.teacher).read_bytes()).hexdigest(),
        provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        physics_log_sha256=hashlib.sha256(log_path.read_bytes()).hexdigest(), actor_and_normalization_unchanged=True,
        scope="Frozen learned actors with privileged teacher channel substitutions and full-teacher memory ablations. No fitting, checkpoint selection or learned-policy qualification. Canonical motions are development diagnostics; windowed teacher outcomes do not prove neural H10 impossibility.",
        verification_rollouts=len(config["seeds"]) * len(experiment["cases"]) * len(config["canonical_reset_seeds"]) * 2,
        learned_policy_qualified=False, physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "collection", "experiment", "teacher", "policies", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
