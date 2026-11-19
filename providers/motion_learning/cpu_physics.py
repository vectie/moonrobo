"""Headless MuJoCo runtime producing MoonRobo learning transitions and trials.

This is the numerical provider, not a hardware controller or a job scheduler.
Setup, invocation and cross-language verification belong in MoonBit scripts.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import time

import mujoco
import numpy as np


def sample_pose_offset(names, case, seed):
    """Independent per-episode goals; no canonical motion clips are sampled."""
    limits = case["goal_offset_rad"]
    if any(not math.isfinite(limits[group]) or limits[group] < 0 for group in ["lower", "waist", "upper"]):
        raise ValueError("pose offset amplitudes must be finite and nonnegative")
    amplitudes = np.array([limits["waist" if name.startswith("waist_") else
                                 "upper" if any(part in name for part in ["shoulder", "elbow", "wrist"]) else "lower"]
                           for name in names])
    # Separate RNG leaves existing reset/exploration sequences unchanged.
    rng = np.random.default_rng(np.random.SeedSequence([seed, 1729]))
    return amplitudes * rng.uniform(-1, 1, len(names))


def sample_joint_sines(names, case, seed):
    limits = case["goal_offset_rad"]
    amplitudes = np.array([limits["waist" if name.startswith("waist_") else
        "upper" if any(part in name for part in ["shoulder", "elbow", "wrist"]) else "lower"] for name in names])
    rng = np.random.default_rng(np.random.SeedSequence([seed, 2718]))
    return dict(amplitude=(amplitudes * rng.uniform(.3, 1, len(names))).tolist(),
        bias=(amplitudes * rng.uniform(-.2, .2, len(names))).tolist(),
        frequency_hz=rng.uniform(.15, .65, len(names)).tolist(), phase_rad=rng.uniform(-math.pi, math.pi, len(names)).tolist())


class PhysicsRuntime:
    def __init__(self, scene, control_dt=0.02):
        self.scene = Path(scene).resolve()
        self.model = mujoco.MjModel.from_xml_path(str(self.scene))
        self.data = mujoco.MjData(self.model)
        self.substeps = round(control_dt / self.model.opt.timestep)
        if self.substeps < 1 or not math.isclose(
            self.substeps * self.model.opt.timestep, control_dt, rel_tol=1e-9
        ):
            raise ValueError("control period must be a positive multiple of physics timestep")
        self.dt = control_dt
        m = self.model
        # This provider initially targets a floating-base body with scalar
        # position actuators, matching Menagerie's G1 scene_mjx.xml.
        if m.njnt < 2 or m.jnt_type[0] != mujoco.mjtJoint.mjJNT_FREE or m.nu == 0:
            raise ValueError("expected floating base and scalar joint actuators")
        self.joints = m.actuator_trnid[:, 0].copy()
        if not np.all(m.actuator_trntype == mujoco.mjtTrn.mjTRN_JOINT):
            raise ValueError("only joint transmissions are supported")
        if not np.all(m.jnt_type[self.joints] == mujoco.mjtJoint.mjJNT_HINGE):
            raise ValueError("only scalar hinge actuator targets are supported")
        # Position servo gain/bias identity; motor/velocity semantics differ.
        if not np.allclose(m.actuator_biasprm[:, 1], -m.actuator_gainprm[:, 0]):
            raise ValueError("expected position servos")
        self.q_indices = m.jnt_qposadr[self.joints]
        self.v_indices = m.jnt_dofadr[self.joints]
        self.root = int(m.jnt_bodyid[0])
        self.names = [m.joint(int(j)).name for j in self.joints]
        self.base_disable = int(m.opt.disableflags)

    def state(self):
        return np.concatenate((self.data.qpos, self.data.qvel, self.data.act)).tolist()

    def observation(self, previous):
        d = self.data
        gravity = -d.xmat[self.root].reshape(3, 3)[2, :]
        return np.concatenate((d.qpos[self.q_indices], d.qvel[self.v_indices],
                               gravity, d.qvel[3:6], previous)).tolist()

    def reference(self, nominal, motion, t, pose_offset=None, reference_schedule=None):
        target = nominal.copy()
        if motion == "pose_offset":
            if pose_offset is None or pose_offset.shape != nominal.shape:
                raise ValueError("pose-offset reference needs one offset per actuator")
            return self.clip_control(target + pose_offset)
        elif motion == "random_joint_sines":
            if reference_schedule is None:
                raise ValueError("joint-sine reference requires its declared schedule")
            schedule = reference_schedule
            return self.clip_control(target + np.asarray(schedule["bias"]) + np.asarray(schedule["amplitude"]) *
                np.sin(2 * math.pi * np.asarray(schedule["frequency_hz"]) * t + np.asarray(schedule["phase_rad"])))
        elif motion == "arm_wave":
            for i, name in enumerate(self.names):
                if "shoulder_pitch" in name:
                    target[i] += 0.12 * math.sin(2 * math.pi * 0.5 * t)
        elif motion == "waist_sway":
            for i, name in enumerate(self.names):
                if "waist_yaw" in name:
                    target[i] += 0.08 * math.sin(2 * math.pi * 0.5 * t)
        elif motion != "stand":
            raise ValueError("unknown reference motion: " + motion)
        return target

    def clip_control(self, target):
        m = self.model
        return np.where(m.actuator_ctrllimited,
                        np.clip(target, m.actuator_ctrlrange[:, 0], m.actuator_ctrlrange[:, 1]),
                        target)

    def rollout(self, case, seed, controller, seconds, fall_height=0.35, fall_upright=0.5,
                action_noise_std=0.0, policy=None, trace_callback=None):
        m, d = self.model, self.data
        key = mujoco.mj_name2id(m, mujoco.mjtObj.mjOBJ_KEY, case["keyframe"])
        if key < 0:
            raise ValueError("missing keyframe: " + case["keyframe"])
        mujoco.mj_resetDataKeyframe(m, d, key)
        m.opt.disableflags = self.base_disable
        if controller == "unpowered":
            m.opt.disableflags |= int(mujoco.mjtDisableBit.mjDSBL_ACTUATION)
        elif controller not in ("position", "policy"):
            raise ValueError("unknown controller: " + controller)
        if controller == "policy" and policy is None:
            raise ValueError("policy controller needs an inference callback")
        friction = float(case["friction"])
        if not math.isfinite(friction) or friction <= 0:
            raise ValueError("friction must be finite and positive")
        # Explicit contact pairs override geom friction in the G1 scene.
        m.geom_friction[:, 0] = friction
        m.pair_friction[:, :2] = friction
        rng = np.random.default_rng(seed)
        if not math.isfinite(action_noise_std) or action_noise_std < 0:
            raise ValueError("action noise must be finite and nonnegative")
        d.qvel[self.v_indices] = rng.normal(0, 0.01, m.nu)
        mujoco.mj_forward(m, d)
        nominal = d.qpos[self.q_indices].copy()
        pose_offset = sample_pose_offset(self.names, case, seed) if case["motion"] == "pose_offset" else None
        reference_schedule = sample_joint_sines(self.names, case, seed) if case["motion"] == "random_joint_sines" else None
        previous = self.clip_control(nominal)
        count = round(seconds / self.dt)
        if count < 1 or not math.isclose(count * self.dt, seconds, rel_tol=1e-9):
            raise ValueError("duration must be a positive multiple of control_dt")
        steps, replay, errors = [], [], []
        start = time.perf_counter()
        for i in range(count):
            goal = self.reference(nominal, case["motion"], i * self.dt, pose_offset, reference_schedule)
            before = self.state()
            observation = self.observation(previous)
            if controller == "unpowered":
                action = np.zeros(m.nu)
            else:
                requested = goal if controller == "position" else np.asarray(policy(observation, goal))
                if requested.shape != (m.nu,) or not np.isfinite(requested).all():
                    raise ValueError("policy must return one finite setpoint per actuator")
                action = self.clip_control(requested + rng.normal(0, action_noise_std, m.nu))
            if trace_callback is not None:
                trace_callback(self, i, action.copy(), goal.copy())
            d.ctrl[:] = action
            mujoco.mj_step(m, d, nstep=self.substeps)
            mujoco.mj_forward(m, d)
            after = self.state()
            if not np.isfinite(after).all():
                raise ValueError("nonfinite simulator state")
            height = float(d.xpos[self.root, 2])
            upright = float(d.xmat[self.root].reshape(3, 3)[2, 2])
            fallen = height < fall_height or upright < fall_upright
            error = float(np.mean(np.square(d.qpos[self.q_indices] - goal)))
            errors.append(error)
            steps.append(dict(time_s=i * self.dt, state=before, observation=observation,
                              applied_action=action.tolist(), next_state=after,
                              goal=goal.tolist(), reward=math.exp(-error / 0.09),
                              terminated=fallen, truncated=not fallen and i == count - 1))
            replay.append(dict(time_s=(i + 1) * self.dt, qpos=d.qpos.tolist(),
                               target=goal.tolist(), root_height_m=height,
                               upright_z=upright, contacts=int(d.ncon)))
            previous = action.copy()
            if fallen:
                break
        elapsed = time.perf_counter() - start
        episode_id = f'{case["id"]}-{controller}-seed-{seed}'
        episode = dict(id=episode_id, source_family=case["family"], split=case["split"],
                       context=[friction, float(controller != "unpowered")], steps=steps,
                       case_id=case["id"], reference_nominal_rad=nominal.tolist())
        if pose_offset is not None:
            episode["reference_offset_rad"] = pose_offset.tolist()
        if reference_schedule is not None:
            episode["reference_schedule"] = reference_schedule
        trial = dict(episode_id=episode_id, case_id=case["id"], seed=seed,
                     controller=controller, split=case["split"], steps=len(steps),
                     failed=steps[-1]["terminated"], joint_rmse_rad=math.sqrt(sum(errors) / len(errors)),
                     min_root_height_m=min(f["root_height_m"] for f in replay),
                     simulated_seconds=len(steps) * self.dt, wall_seconds=elapsed,
                     end_reason="fall" if steps[-1]["terminated"] else "time_limit",
                     replay=replay)
        return episode, trial

    def dataset(self, episodes, source_revision):
        m = self.model
        def axes(prefix, count, unit):
            return [dict(name=f"{prefix}.{i}", unit=unit) for i in range(count)]
        q_axes = axes("qpos", m.nq, "rad")
        for i in range(3):
            q_axes[i]["unit"] = "m"
        for i in range(3, 7):
            q_axes[i]["unit"] = "1"
        v_axes = axes("qvel", m.nv, "rad/s")
        for i in range(3):
            v_axes[i]["unit"] = "m/s"
        joint_axes = lambda suffix, unit: [dict(name=n + suffix, unit=unit) for n in self.names]
        return dict(format="moonrobo.motion-dataset.v1", dataset_id="g1-cpu-physics",
                    model_ref=f"mujoco-menagerie:{source_revision}:unitree_g1/scene_mjx.xml",
                    provenance="MuJoCo CPU transitions; original procedural references, not mocap or hardware",
                    frame_convention="MuJoCo qpos/qvel; world Z up; free-root quaternion wxyz; gravity in root frame",
                    dt_s=self.dt, state_axes=q_axes + v_axes + axes("activation", m.na, "1"),
                    observation_axes=joint_axes(".position", "rad") + joint_axes(".velocity", "rad/s") +
                    axes("projected_gravity", 3, "1") + axes("root_angular_velocity", 3, "rad/s") +
                    joint_axes(".previous_setpoint", "rad"),
                    action_axes=joint_axes(".setpoint", "rad"), goal_axes=joint_axes(".target", "rad"),
                    context_axes=[dict(name="sliding_friction", unit="1"),
                                  dict(name="actuation_enabled", unit="1")], episodes=episodes)


def run(args):
    experiment = json.loads(Path(args.experiment).read_text())
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    episodes, trials = [], []
    for case in experiment["cases"]:
        for seed in experiment["seeds"]:
            for controller in experiment["controllers"]:
                episode, trial = runtime.rollout(
                    case, seed, controller, experiment["duration_s"],
                    experiment["fall_height_m"], experiment["fall_upright_z"],
                    experiment.get("action_noise_std_rad", 0.0))
                episodes.append(episode)
                trials.append(trial)
    dataset = runtime.dataset(episodes, experiment["source_revision"])
    summaries = []
    for controller in experiment["controllers"]:
        selected = [t for t in trials if t["controller"] == controller]
        total_steps = sum(t["steps"] for t in selected)
        summaries.append(dict(controller=controller, trials=len(selected),
                              failed_trials=sum(t["failed"] for t in selected),
                              pooled_joint_rmse_rad=math.sqrt(sum(t["joint_rmse_rad"] ** 2 * t["steps"] for t in selected) / total_steps),
                              steps=total_steps,
                              control_steps_per_second=total_steps / sum(t["wall_seconds"] for t in selected)))
    report = dict(format="moonrobo.physics-evaluation.v1", evidence_class="physics-simulation",
                  purpose="CPU collection and scoring baseline; not PPO or SuperMimic performance",
                  mujoco_version=mujoco.__version__, numpy_version=np.__version__,
                  scene_sha256=hashlib.sha256(runtime.scene.read_bytes()).hexdigest(),
                  provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  experiment_sha256=hashlib.sha256(Path(args.experiment).read_bytes()).hexdigest(),
                  source_revision=experiment["source_revision"], experiment=experiment,
                  dataset_file="dataset.json", summaries=summaries, trials=trials)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "dataset.json").write_text(json.dumps(dataset, allow_nan=False))
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(output=str(output), summaries=summaries)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", required=True)
    parser.add_argument("--experiment", required=True)
    parser.add_argument("--output", required=True)
    run(parser.parse_args())
