"""Simulation-only balance feedback for collecting sustained training states."""

import argparse
import hashlib
import itertools
import json
import math
from pathlib import Path

import numpy as np
import mujoco

from cpu_physics import PhysicsRuntime


def support_torque(runtime, feet):
    """Quasistatic vertical support assumption, not applied external forces."""
    m, d = runtime.model, runtime.data
    positions = d.site_xpos[feet]
    com = d.subtree_com[runtime.root]
    weight = m.body_subtreemass[runtime.root] * -m.opt.gravity[2]
    span = positions[0, 1] - positions[1, 1]
    left = float(np.clip((com[1] - positions[1, 1]) / span, 0, 1)) if abs(span) > 1e-6 else .5
    external = np.zeros(m.nv)
    cop_x = np.clip(com[0], positions[:, 0].mean() - .04, positions[:, 0].mean() + .04)
    for site, fraction in zip(feet, [left, 1 - left]):
        point = d.site_xpos[site].copy()
        point[0] = cop_x
        jacobian = np.zeros((3, m.nv))
        mujoco.mj_jac(m, d, jacobian, None, point, int(m.site_bodyid[site]))
        external += jacobian[2] * (weight * fraction)
    return d.qfrc_bias - external


class BalanceTeacher:
    """Privileged simulator feedback; not a learned or hardware policy."""
    def __init__(self, runtime, config):
        self.runtime, self.config = runtime, config
        self.feet = [runtime.model.site(name).id for name in ["left_foot", "right_foot"]]
        self.ankle_pitch = [runtime.names.index(side + "_ankle_pitch_joint") for side in ["left", "right"]]
        self.ankle_roll = [runtime.names.index(side + "_ankle_roll_joint") for side in ["left", "right"]]
        self.hip_pitch = [i for i, name in enumerate(runtime.names) if name.endswith("_hip_pitch_joint")]
        self.hip_roll = [i for i, name in enumerate(runtime.names) if name.endswith("_hip_roll_joint")]
        self.waist_pitch = [i for i, name in enumerate(runtime.names) if name == "waist_pitch_joint"]
        self.last_error = None
        self.velocity = np.zeros(3)

    def measurements(self):
        rt = self.runtime
        rotation = rt.data.xmat[rt.root].reshape(3, 3)
        support = rt.data.site_xpos[self.feet].mean(0)
        error = rt.data.subtree_com[rt.root] - support
        error[2] = 0
        return rotation, support, error

    def __call__(self, observation, goal):
        rt, c = self.runtime, self.config
        rotation, _, error = self.measurements()
        if self.last_error is not None:
            self.velocity = .8 * self.velocity + .2 * (error - self.last_error) / rt.dt
        self.last_error = error.copy()
        local_error, local_velocity = rotation.T @ error, rotation.T @ self.velocity
        gravity = -rotation[2, :]
        pitch = math.atan2(gravity[0], math.hypot(gravity[1], gravity[2]))
        roll = math.atan2(-gravity[1], -gravity[2])
        correction = np.zeros(rt.model.nu)
        correction[self.ankle_pitch] = (c["angle_gain"] * pitch + c["rate_gain"] * rt.data.qvel[4] +
            c["com_gain"] * local_error[0] + c["velocity_gain"] * local_velocity[0] + c["pitch_bias_rad"])
        correction[self.ankle_roll] = (c["angle_gain"] * roll + c["rate_gain"] * rt.data.qvel[3] -
            c["com_gain"] * local_error[1] - c["velocity_gain"] * local_velocity[1])
        correction[self.hip_pitch] = c.get("hip_share", 0) * np.clip(correction[self.ankle_pitch[0]], -c["residual_bound_rad"], c["residual_bound_rad"])
        correction[self.hip_roll] = c.get("hip_share", 0) * np.clip(correction[self.ankle_roll[0]], -c["residual_bound_rad"], c["residual_bound_rad"])
        waist_signal = correction[self.ankle_pitch[0]] - (c["pitch_bias_rad"] if c.get("waist_dynamic_only", False) else 0)
        correction[self.waist_pitch] = -c.get("waist_share", 0) * np.clip(waist_signal, -c["residual_bound_rad"], c["residual_bound_rad"])
        if c.get("support_gain", 0):
            correction += c["support_gain"] * support_torque(rt, self.feet)[rt.v_indices] / rt.model.actuator_gainprm[:, 0]
        correction -= c.get("joint_damping", 0) * rt.data.qvel[rt.v_indices]
        return rt.clip_control(np.asarray(goal) + np.clip(correction, -c["residual_bound_rad"], c["residual_bound_rad"]))


def summarize(trials):
    return dict(trials=len(trials), falls=sum(t["failed"] for t in trials),
                mean_survival_s=float(np.mean([t["simulated_seconds"] for t in trials])),
                mean_joint_rmse_rad=float(np.mean([t["joint_rmse_rad"] for t in trials])))


def evaluate(runtime, experiment, cases, seeds, parameters, keep=False):
    episodes, trials = [], []
    for case, seed in itertools.product(cases, seeds):
        teacher = BalanceTeacher(runtime, parameters) if parameters is not None else None
        episode, trial = runtime.rollout(case, seed, "policy" if teacher else "position", experiment["duration_s"],
            experiment["fall_height_m"], experiment["fall_upright_z"], policy=teacher)
        if keep:
            episodes.append(episode)
            trials.append(trial)
        else:
            trials.append({k: v for k, v in trial.items() if k != "replay"})
    return summarize(trials), episodes, trials


def diagnose(runtime, experiment, seed, parameters=None, case_id=None):
    measurements = []
    case = next(c for c in experiment["cases"] if c["split"] == "train" and
                (c["id"] == case_id if case_id else c["motion"] == "stand"))
    monitor = BalanceTeacher(runtime, dict())
    def capture(rt, step, action, goal):
        if step % 10:
            return
        rotation, support, error = monitor.measurements()
        measurements.append(dict(time_s=step * rt.dt, height_m=float(rt.data.xpos[rt.root, 2]),
            upright_z=float(rotation[2, 2]), com_minus_support_m=error.tolist(),
            root_angular_velocity=rt.data.qvel[3:6].tolist(), support_m=support.tolist(),
            joint_error_rad=(rt.data.qpos[rt.q_indices] - goal).tolist(),
            ankle_residual_rad=(action - goal)[monitor.ankle_pitch + monitor.ankle_roll].tolist(),
            applied_torque_nm=rt.data.actuator_force.tolist(), contacts=int(rt.data.ncon)))
    teacher = BalanceTeacher(runtime, parameters) if parameters is not None else None
    _, trial = runtime.rollout(case, seed, "policy" if teacher else "position", experiment["duration_s"],
        experiment["fall_height_m"], experiment["fall_upright_z"], trace_callback=capture, policy=teacher)
    return dict(trial={k: v for k, v in trial.items() if k != "replay"}, measurements=measurements,
                joint_names=runtime.names)


def run(args):
    experiment = json.loads(Path(args.experiment).read_text())
    config = json.loads(Path(args.config).read_text())
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    if args.command == "diagnose":
        parameters = json.loads(Path(args.teacher).read_text())["parameters"] if args.teacher else None
        report = diagnose(runtime, experiment, args.seed if args.seed is not None else config["development_seeds"][0], parameters, args.case)
        (output / "diagnosis.json").write_text(json.dumps(report, indent=2, allow_nan=False))
        print(json.dumps(dict(trial=report["trial"], measurements=[
            {k: row[k] for k in ["time_s", "height_m", "upright_z", "com_minus_support_m", "root_angular_velocity", "contacts", "ankle_residual_rad"]}
            for row in report["measurements"]])))
        return
    if args.command == "fit":
        cases = [c for c in experiment["cases"] if c["split"] == "train"]
        baseline = evaluate(runtime, experiment, cases, config["development_seeds"], None)[0]
        rows = []
        best = None
        for values in itertools.product(*[config["grid"][key] for key in config["grid"]]):
            parameters = {**config["fixed"], **dict(zip(config["grid"], values))}
            summary = evaluate(runtime, experiment, cases, config["development_seeds"], parameters)[0]
            rank = (-summary["falls"], summary["mean_survival_s"], -summary["mean_joint_rmse_rad"])
            rows.append(dict(parameters=parameters, summary=summary))
            if best is None or rank > best[0]:
                best = (rank, parameters, summary)
                print(json.dumps(dict(candidate=len(rows), best=rows[-1])), flush=True)
        report = dict(format="moonrobo.g1-balance-teacher.v1", kind="handcrafted-simulator-feedback",
            config=config, parameters=best[1], development=best[2], baseline=baseline, candidates=rows,
            provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            experiment=experiment, physical_execution_allowed=False)
        (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
        return
    selected = json.loads(Path(args.teacher).read_text())
    seeds = config["evaluation_seeds"] if args.command == "evaluate" else config["development_seeds"] if args.command == "develop" else config["collection_seeds"]
    cases = experiment["cases"] if args.command == "evaluate" else [c for c in experiment["cases"] if c["split"] == "train"]
    summary, episodes, trials = evaluate(runtime, experiment, cases, seeds, selected["parameters"], keep=True)
    digest = hashlib.sha256(Path(args.teacher).read_bytes()).hexdigest()
    for episode, trial in zip(episodes, trials):
        episode["id"] += "-balance-teacher-" + digest[:16]
        trial["episode_id"] = episode["id"]
    report = dict(format="moonrobo.g1-balance-teacher-evaluation.v1", kind="handcrafted-simulator-feedback",
        teacher_sha256=digest, experiment=experiment, summary=summary, trials=trials,
        seeds=seeds, physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    (output / "dataset.json").write_text(json.dumps(runtime.dataset(episodes, experiment["source_revision"]), allow_nan=False))
    print(json.dumps(dict(summary=summary, output=str(output), trials=[{k: t[k] for k in ["case_id", "seed", "simulated_seconds", "failed", "joint_rmse_rad"]} for t in trials])))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["diagnose", "fit", "evaluate", "collect", "develop"])
    for name in ["scene", "experiment", "config", "output"]:
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--teacher")
    parser.add_argument("--case")
    parser.add_argument("--seed", type=int)
    run(parser.parse_args())
