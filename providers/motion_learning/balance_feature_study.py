"""Validate observation-derived balance features, then run fixed feedback diagnostics."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import mujoco
import numpy as np
import torch

from balance_features import (BalanceKinematics, ObservationAnkleFeedback, ObservationBalanceHistory,
    causal_velocity, make_spec, observation_transports, sequence_features)
from balance_intervention import WindowTeacher
from cpu_physics import PhysicsRuntime
from temporal_actor import TemporalRunner, load_temporal


def errors(actual, expected):
    difference = np.asarray(actual) - np.asarray(expected)
    return dict(count=int(difference.size), squared_error=float(np.square(difference).sum()),
        maximum_error=float(np.abs(difference).max()), rmse=float(np.sqrt(np.square(difference).mean())))


def reference_episode(runtime, episode, factory):
    # Privileged state is consumed only in the verification path, never by
    # the observation-derived modules or the sensor-feedback controller.
    teacher, short = factory(), WindowTeacher(factory(), 10)
    error, velocity, short_velocity, rotation, action, short_action = [], [], [], [], [], []
    m, d = runtime.model, runtime.data
    for step in episode["steps"]:
        state = np.asarray(step["state"])
        d.qpos[:] = state[:m.nq]; d.qvel[:] = state[m.nq:m.nq+m.nv]; d.act[:] = state[m.nq+m.nv:]
        mujoco.mj_forward(m, d)
        actual = teacher(step["observation"], step["goal"])
        abbreviated = short(step["observation"], step["goal"])
        r = d.xmat[runtime.root].reshape(3, 3).copy()
        error.append(r.T @ teacher.last_error)
        velocity.append(r.T @ teacher.velocity); short_velocity.append(r.T @ short.teacher.velocity)
        rotation.append(r); action.append(actual); short_action.append(abbreviated)
    return [np.asarray(v) for v in [error, velocity, short_velocity, rotation, action, short_action]]


def random_geometry(runtime, spec, config):
    geometry = {name: BalanceKinematics(spec, dtype=dtype) for name, dtype in [("float64", torch.float64), ("float32", torch.float32)]}
    m, d = runtime.model, runtime.data
    random = np.random.default_rng(config["random_pose_seed"])
    key = m.key("home").id
    points, gravity, truth = [], [], []
    for _ in range(config["random_pose_count"]):
        mujoco.mj_resetDataKeyframe(m, d, key)
        d.qpos[:3] = random.uniform(-20, 20, 3)
        quaternion = random.normal(size=4); quaternion /= np.linalg.norm(quaternion)
        d.qpos[3:7] = quaternion
        d.qpos[runtime.q_indices] += random.uniform(-.15, .15, m.nu)
        mujoco.mj_forward(m, d)
        rotation = d.xmat[runtime.root].reshape(3, 3)
        foot = d.site_xpos[[m.site("left_foot").id, m.site("right_foot").id]].mean(0)
        difference = d.subtree_com[runtime.root] - foot; difference[2] = 0
        points.append(d.qpos[runtime.q_indices].copy()); gravity.append(-rotation[2].copy())
        truth.append(rotation.T @ difference)
    rows = []
    for name, model in geometry.items():
        dtype = model.positions.dtype
        predicted = model(torch.tensor(np.asarray(points), dtype=dtype), torch.tensor(np.asarray(gravity), dtype=dtype)).detach().numpy()
        result = errors(predicted, truth)
        if result["maximum_error"] > (1e-10 if name == "float64" else 2e-6):
            raise ValueError("root-relative random-pose kinematics differ from native reference")
        rows.append(dict(dtype=name, **result))
    return rows


def verify_log(runtime, spec, feedback, config, source, output, factory):
    geometry = {name: BalanceKinematics(spec, dtype=dtype) for name, dtype in [("float64", torch.float64), ("float32", torch.float32)]}
    rows = []
    with gzip.open(source, "rt") as stream:
        for line in stream:
            record = json.loads(line)
            if record["mode"] not in config["source_modes"]:
                continue
            for episode, trial in zip(record["dataset"]["episodes"], record["trials"]):
                observation = np.asarray([s["observation"] for s in episode["steps"]])
                goals = torch.tensor([s["goal"] for s in episode["steps"]], dtype=torch.float64)
                expected, full_velocity, short_velocity, rotations, full_actions, short_actions = reference_episode(runtime, episode, factory)
                obs64 = torch.tensor(observation, dtype=torch.float64)
                predicted = geometry["float64"].from_observations(obs64)
                position_error = errors(predicted.detach().numpy(), expected)
                if position_error["maximum_error"] > 1e-10:
                    raise ValueError("recorded observation geometry differs from reference")
                # An oracle transport is used only to isolate estimator error.
                oracle = torch.tensor(np.concatenate((np.eye(3)[None], rotations[1:].transpose(0, 2, 1) @ rotations[:-1])), dtype=torch.float64)
                oracle_rows = []
                for window, target in [(10, short_velocity), (None, full_velocity)]:
                    velocity = causal_velocity(predicted, oracle, runtime.dt, window)
                    check = errors(velocity.detach().numpy(), target)
                    if check["maximum_error"] > 1e-9:
                        raise ValueError("causal velocity recurrence differs from reference")
                    oracle_rows.append(dict(window="full" if window is None else window, **check))
                exact = torch.cat((torch.tensor(expected), torch.tensor(full_velocity)), -1)
                replayed = feedback(obs64, goals, exact).detach().numpy()
                action_check = errors(replayed, full_actions[:, feedback.indices])
                if action_check["maximum_error"] > 1e-10:
                    raise ValueError("fixed ankle feedback differs from original teacher formula")
                estimates = []
                for name, model in geometry.items():
                    obs = torch.tensor(observation, dtype=model.positions.dtype)
                    error = model.from_observations(obs)
                    for method in config["transport_methods"]:
                        transform = observation_transports(obs[:, 2*model.nu:2*model.nu+3], obs[:, 2*model.nu+3:2*model.nu+6], runtime.dt, method)
                        for window, target, actions in [(10, short_velocity, short_actions), (None, full_velocity, full_actions)]:
                            velocity = causal_velocity(error, transform, runtime.dt, window)
                            feature = torch.cat((error, velocity), -1).to(torch.float64)
                            predicted_actions = feedback(obs64, goals, feature).detach().numpy()
                            estimates.append(dict(dtype=name, method=method, window="full" if window is None else window,
                                velocity=errors(velocity.detach().numpy(), target), ankle_action=errors(predicted_actions, actions[:, feedback.indices])))
                rows.append(dict(parent_seed=record["seed"], source_mode=record["mode"], episode_id=episode["id"],
                    case_id=episode["case_id"], split=episode["split"], scope=trial["scope"], points=len(observation),
                    geometry=position_error, oracle_transport=oracle_rows, exact_feedback=action_check, estimates=estimates))
            print(json.dumps(dict(verified_parent=record["seed"], mode=record["mode"], episodes=len(record["dataset"]["episodes"]))), flush=True)
    (output / "feature-verification.json").write_text(json.dumps(dict(rows=rows,
        scope="Recorded states supply verification truth only. Derived geometry and transports use observation columns and static model constants; no fitting."), indent=2, allow_nan=False))
    return rows


def control(runtime, spec, teacher, config, experiment, policies, output, factory):
    geometry = BalanceKinematics(spec, dtype=torch.float32)
    lower, upper = runtime.model.actuator_ctrlrange.T
    feedback = ObservationAnkleFeedback(spec, teacher["parameters"], lower.copy(), upper.copy(), dtype=torch.float32)
    rows = []
    path = output / "feature-feedback-physics.jsonl.gz"
    with gzip.open(path, "wt", compresslevel=6) as stream:
        for seed in config["seeds"]:
            actor_path = Path(policies) / f"actor-seed-{seed}.pt"
            actor, _ = load_temporal(actor_path)
            initial = {k: v.clone() for k, v in actor.state_dict().items()}
            for mode in config["control_modes"]:
                episodes, trials = [], []
                maximum_offline_error = 0.
                for case in experiment["cases"]:
                    for reset in config["control_reset_seeds"]:
                        runner = TemporalRunner(runtime, actor, case, reset)
                        history = ObservationBalanceHistory(geometry, runtime.dt)
                        oracle = WindowTeacher(factory(), 10)
                        online = []
                        def predict(obs, goal):
                            student = runner(obs, goal)
                            with torch.no_grad():
                                observed = torch.tensor(obs, dtype=torch.float32)
                                feature = history(observed)
                                online.append(feature)
                                derived = feedback(observed, torch.tensor(goal, dtype=torch.float32), feature).numpy()
                            if mode == "student":
                                return student
                            if mode == "oracle_h10_ankle":
                                student[feedback.indices] = oracle(obs, goal)[feedback.indices]
                            else:
                                student[feedback.indices] = derived
                            return student
                        episode, trial = runtime.rollout(case, reset, "policy", config["duration_s"],
                            config["fall_height_m"], config["fall_upright_z"], policy=predict)
                        with torch.no_grad():
                            offline = sequence_features(geometry, torch.tensor([s["observation"] for s in episode["steps"]], dtype=torch.float32), runtime.dt)
                            error = float((torch.stack(online) - offline).abs().max())
                            maximum_offline_error = max(error, maximum_offline_error)
                            torch.testing.assert_close(torch.stack(online), offline, atol=2e-5, rtol=1e-4)
                        episode["id"] += f"-features-policy-{seed}-{mode}"
                        trial["episode_id"] = episode["id"]
                        episodes.append(episode); trials.append({k: v for k, v in trial.items() if k != "replay"})
                summary = dict(trials=len(trials), falls=sum(t["failed"] for t in trials),
                    mean_survival_s=float(np.mean([t["simulated_seconds"] for t in trials])),
                    mean_joint_rmse_rad=float(np.mean([t["joint_rmse_rad"] for t in trials])))
                stream.write(json.dumps(dict(seed=seed, mode=mode, dataset=runtime.dataset(episodes, experiment["source_revision"]), trials=trials), allow_nan=False) + "\n")
                row = dict(seed=seed, mode=mode, summary=summary, maximum_online_offline_feature_error=maximum_offline_error,
                    episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes), trials=trials,
                    actor_sha256=hashlib.sha256(actor_path.read_bytes()).hexdigest())
                rows.append(row)
                print(json.dumps({k: v for k, v in row.items() if k != "trials"}), flush=True)
            if any(not torch.equal(value, actor.state_dict()[key]) for key, value in initial.items()):
                raise ValueError("feature-feedback study changed learned actor weights")
    return rows, hashlib.sha256(path.read_bytes()).hexdigest()


def run(args):
    import teacher_feedback
    config = json.loads(Path(args.config).read_bytes())
    teacher = json.loads(Path(args.teacher).read_bytes())
    if hashlib.sha256(Path(teacher_feedback.__file__).read_bytes()).hexdigest() != teacher["provider_sha256"]:
        raise ValueError("feature-verification teacher source changed")
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene)
    spec = make_spec(runtime.model)
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    (output / "kinematics.json").write_text(json.dumps(spec, indent=2, allow_nan=False))
    factory = lambda: teacher_feedback.BalanceTeacher(runtime, teacher["parameters"])
    lower, upper = runtime.model.actuator_ctrlrange.T
    feedback = ObservationAnkleFeedback(spec, teacher["parameters"], lower.copy(), upper.copy(), dtype=torch.float64)
    source = Path(args.intervention) / "intervention-physics.jsonl.gz"
    source_report = json.loads((Path(args.intervention) / "report.json").read_bytes())
    if hashlib.sha256(source.read_bytes()).hexdigest() != source_report["physics_log_sha256"]:
        raise ValueError("feature verification input changed")
    poses = random_geometry(runtime, spec, config)
    verified = verify_log(runtime, spec, feedback, config, source, output, factory)
    experiment = json.loads(Path(args.experiment).read_bytes())
    rows, log_sha = control(runtime, spec, teacher, config, experiment, args.policies, output, factory)
    report = dict(format="moonrobo.g1-observation-balance-features.v1", config=config,
        kinematics_sha256=hashlib.sha256((output / "kinematics.json").read_bytes()).hexdigest(),
        input_log_sha256=source_report["physics_log_sha256"], random_pose_geometry=poses,
        verified_episodes=len(verified), verified_points=sum(r["points"] for r in verified),
        verification_sha256=hashlib.sha256((output / "feature-verification.json").read_bytes()).hexdigest(),
        control=rows, control_log_sha256=log_sha, provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        feature_provider_sha256=hashlib.sha256(Path(__file__).with_name("balance_features.py").read_bytes()).hexdigest(),
        learned_policy_qualified=False, physical_execution_allowed=False,
        scope="Static-model FK from observed q/gravity and causal gyro/gravity frame transport; recorded privileged state used only as verification truth. Fixed-gain ankle feedback is diagnostic, not learned-policy training/qualification. Nominal simulation geometry/IMU only, no hardware calibration or noisy-sensor guarantee.")
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "teacher", "intervention", "experiment", "policies", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
