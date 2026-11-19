"""Physics-derived motion references, separate from source controls and observations.

This is a local G1 reference representation, not a reconstruction of the
unspecified per-frame encoder layout in SuperMimic. Source controls are retained
only to test physical feasibility; they are never part of the actor goal.
"""
import math

import mujoco
import numpy as np


def reference_axes(joint_names, body_names):
    result = []
    def add(prefix, names, unit):
        result.extend(dict(name=prefix + name, unit=unit) for name in names)
    add("reference.joint_position.", joint_names, "rad")
    add("reference.joint_velocity.", joint_names, "rad/s")
    add("reference.gravity_root.", ["x", "y", "z"], "1")
    add("reference.root_height.", ["z"], "m")
    add("reference.root_linear_velocity_root.", ["x", "y", "z"], "m/s")
    add("reference.root_angular_velocity_root.", ["x", "y", "z"], "rad/s")
    for body in body_names:
        add("reference.body_position_root." + body + ".", ["x", "y", "z"], "m")
    for body in body_names:
        add("reference.body_rotation_root." + body + ".", ["c0x", "c0y", "c0z", "c1x", "c1y", "c1z"], "1")
    return result


def encode_goal(state, body_positions, body_rotations, q_indices, v_indices, nq, root_index):
    """Reference-only encoding invariant to world XY translation and world yaw.

    The root frame includes tilt. Rotation columns are concatenated column by
    column, rather than interleaving their rows. No current robot pose is used.
    """
    state = np.asarray(state)
    root_r = body_rotations[root_index]
    root_p = body_positions[root_index]
    relative_positions = (body_positions - root_p) @ root_r
    relative_rotations = np.einsum("ij,bjk->bik", root_r.T, body_rotations)
    columns = relative_rotations[..., :, :2].swapaxes(-1, -2).reshape(-1)
    return np.concatenate((state[q_indices], state[nq + v_indices], -root_r[2],
        [root_p[2]], state[nq:nq+3] @ root_r, state[nq+3:nq+6],
        relative_positions.reshape(-1), columns))


def capture_frame(runtime):
    m, d = runtime.model, runtime.data
    integration = np.empty(mujoco.mj_stateSize(m, mujoco.mjtState.mjSTATE_INTEGRATION))
    mujoco.mj_getState(m, d, integration, mujoco.mjtState.mjSTATE_INTEGRATION)
    velocities = np.empty((m.nbody-1, 6))
    for i in range(1, m.nbody):
        mujoco.mj_objectVelocity(m, d, mujoco.mjtObj.mjOBJ_BODY, i, velocities[i-1], 0)
    return dict(state=np.asarray(runtime.state()), integration=integration,
        body_position=d.xpos[1:].copy(), body_rotation=d.xmat[1:].reshape(-1, 3, 3).copy(),
        body_quaternion=d.xquat[1:].copy(), body_object_velocity_world=velocities,
        contacts=np.asarray(d.ncon), time_s=np.asarray(d.time))


class FullBodyReference:
    def __init__(self, arrays, layout):
        self.arrays, self.layout = arrays, layout
        self.frames = len(arrays["state"])
        self.steps = self.frames - 1
        self.dt = layout["dt_s"]
        if self.steps < 1 or arrays["source_setpoint"].shape != (self.steps, len(layout["joint_names"])):
            raise ValueError("a reference needs T controls and T+1 state frames")
        if not np.allclose(np.diff(arrays["time_s"]), self.dt, atol=1e-10, rtol=1e-8):
            raise ValueError("reference timestamps must follow the control cadence")
        self.goals = np.asarray([encode_goal(s, p, r, np.asarray(layout["q_indices"]),
            np.asarray(layout["v_indices"]), layout["nq"], layout["root_body_index"])
            for s, p, r in zip(arrays["state"], arrays["body_position"], arrays["body_rotation"])])
        if self.goals.shape != (self.frames, len(layout["goal_axes"])) or not np.isfinite(self.goals).all():
            raise ValueError("reference goal layout or finite values disagree")

    def preview(self, step, length=10):
        """Targets after the upcoming control intervals; pad with an explicit mask.

        At control index i, row zero is reference frame i+1, not frame i.
        Clamped tail rows are padding, not additional physically valid frames.
        """
        if not 0 <= step < self.steps or length < 1:
            raise ValueError("preview needs a valid control index and positive length")
        indices = step + np.arange(1, length+1)
        return self.goals[np.minimum(indices, self.steps)], indices <= self.steps


def layout_for(runtime):
    m = runtime.model
    names = [m.body(i).name for i in range(1, m.nbody)]
    return dict(nq=m.nq, nv=m.nv, na=m.na, nu=m.nu, joint_names=runtime.names,
        body_names=names, q_indices=runtime.q_indices.tolist(), v_indices=runtime.v_indices.tolist(),
        root_body_index=runtime.root-1, dt_s=runtime.dt,
        goal_axes=reference_axes(runtime.names, names),
        state_convention="MuJoCo qpos then qvel then act; free-root quaternion wxyz; world Z up; root angular qvel local",
        integration_convention="mjSTATE_INTEGRATION, including solver warm start and user inputs; pinned MuJoCo only",
        body_velocity_convention="mj_objectVelocity(mjOBJ_BODY, flg_local=0), angular xyz then linear xyz",
        preview_convention="at action i use frames i+1..i+K; repeat end only with valid=false mask",
        actor_goal_excludes=["source_setpoint", "source_goal", "integration", "actual_robot_global_pose"],
        actor_goal_frame="reference root frame including tilt; root height in world; world XY and yaw removed")


def replay_reference(runtime, reference, case, start, mode, fall_height=.35, fall_upright=.5,
                     policy=None, preview_length=10):
    """Score source controls or a position-only baseline, with one restored reset.

    Only the initial integration state is restored. Subsequent states evolve in
    MuJoCo and are never overwritten by reference frames.
    """
    if mode not in ("source-setpoint", "joint-position", "policy") or not 0 <= start < reference.steps:
        raise ValueError("invalid reference replay mode or start")
    if (mode == "policy") != (policy is not None):
        raise ValueError("only policy mode accepts an inference callback")
    m, d = runtime.model, runtime.data
    mujoco.mj_resetData(m, d)
    m.opt.disableflags = runtime.base_disable
    m.geom_friction[:, 0] = case["friction"]
    m.pair_friction[:, :2] = case["friction"]
    mujoco.mj_setState(m, d, reference.arrays["integration"][start], mujoco.mjtState.mjSTATE_INTEGRATION)
    # Derivatives are recomputed by mj_step. Avoid an extra solver evaluation
    # before the first step, which needlessly changes the warm-start history.
    previous = reference.arrays["source_setpoint"][start-1].copy() if start else reference.arrays["observation"][0, -m.nu:].copy()
    steps, q_errors, body_errors, root_errors, orientation_errors = [], [], [], [], []
    joint_speed_errors, root_linear_speed_errors, root_angular_speed_errors = [], [], []
    max_state_error = 0.
    for i in range(start, reference.steps):
        # mj_setState restores qpos/qvel, not derived xmat. The initial
        # observation's gravity is from the saved reference; later ones are live.
        if i == start:
            observation = reference.arrays["observation"][start].copy()
            observation[-m.nu:] = previous
        else:
            observation = runtime.observation(previous)
        before = runtime.state()
        target = reference.arrays["state"][i+1]
        goal, _ = reference.preview(i, 1)
        if mode == "source-setpoint":
            requested = reference.arrays["source_setpoint"][i]
        elif mode == "joint-position":
            requested = target[runtime.q_indices]
        else:
            preview, valid = reference.preview(i, preview_length)
            # Copy reference inputs so a consumer cannot mutate the next target.
            requested = np.asarray(policy(np.asarray(observation).copy(), reference.goals[i].copy(),
                preview.copy(), valid.copy()))
            if requested.shape != (m.nu,) or not np.isfinite(requested).all():
                raise ValueError("reference policy must return one finite setpoint per actuator")
        action = runtime.clip_control(requested)
        d.ctrl[:] = action
        mujoco.mj_step(m, d, nstep=runtime.substeps)
        mujoco.mj_forward(m, d)
        after = np.asarray(runtime.state())
        max_state_error = max(max_state_error, float(np.max(np.abs(after-target))))
        q_errors.append(float(np.mean((after[runtime.q_indices]-target[runtime.q_indices])**2)))
        body_errors.append(float(np.mean(np.sum((d.xpos[1:]-reference.arrays["body_position"][i+1])**2, axis=-1))))
        root_errors.append(float(np.sum((d.xpos[runtime.root]-reference.arrays["body_position"][i+1, runtime.root-1])**2)))
        r = d.xmat[runtime.root].reshape(3, 3)
        desired_r = reference.arrays["body_rotation"][i+1, runtime.root-1]
        angle = math.acos(float(np.clip((np.trace(desired_r @ r.T)-1)/2, -1, 1)))
        orientation_errors.append(angle**2)
        velocity_error = d.qvel-reference.arrays["state"][i+1, m.nq:m.nq+m.nv]
        joint_speed_errors.append(float(np.mean(velocity_error[runtime.v_indices]**2)))
        root_linear_speed_errors.append(float(np.mean(velocity_error[:3]**2)))
        root_angular_speed_errors.append(float(np.mean(velocity_error[3:6]**2)))
        fallen = bool(d.xpos[runtime.root, 2] < fall_height or r[2, 2] < fall_upright)
        steps.append(dict(time_s=(i-start)*runtime.dt, state=before, observation=np.asarray(observation).tolist(),
            applied_action=action.tolist(), next_state=after.tolist(), goal=goal[0].tolist(),
            reward=math.exp(-body_errors[-1]/.3**2), terminated=fallen,
            truncated=not fallen and i == reference.steps-1))
        previous = action.copy()
        if fallen:
            break
    ident = f'{case["id"]}-reference-{mode}-start-{start}'
    episode = dict(id=ident, source_family=case["family"], split=case["split"],
        context=[case["friction"], 1.], steps=steps, case_id=case["id"], reference_start_step=start)
    trial = dict(episode_id=ident, case_id=case["id"], controller=mode, reference_start_step=start,
        steps=len(steps), failed=steps[-1]["terminated"], simulated_seconds=len(steps)*runtime.dt,
        requested_seconds=(reference.steps-start)*runtime.dt,
        joint_rmse_rad=math.sqrt(np.mean(q_errors)), body_position_rmse_m=math.sqrt(np.mean(body_errors)),
        root_position_rmse_m=math.sqrt(np.mean(root_errors)), root_orientation_rmse_rad=math.sqrt(np.mean(orientation_errors)),
        joint_speed_rmse_rad_per_s=math.sqrt(np.mean(joint_speed_errors)),
        root_linear_speed_rmse_m_per_s=math.sqrt(np.mean(root_linear_speed_errors)),
        root_angular_speed_rmse_rad_per_s=math.sqrt(np.mean(root_angular_speed_errors)),
        max_state_component_error=max_state_error)
    return episode, trial


def assess_tracking_quality(trials, config):
    """An engineering coverage gate, independent of scalar training reward."""
    expected = {(case, round(origin/config["dt_s"])) for case in config["reference_ids"]
        for origin in config["origins_s"]}
    cells = [(t["case_id"], t["reference_start_step"]) for t in trials]
    complete = len(cells) == len(expected) and set(cells) == expected
    failures = []
    for trial in trials:
        reasons = []
        if trial["failed"] or not math.isclose(trial["simulated_seconds"], trial["requested_seconds"], abs_tol=1e-10):
            reasons.append("incomplete-trajectory")
        for metric, limit in config["maximum_per_trial"].items():
            if not math.isfinite(trial[metric]) or trial[metric] > limit:
                reasons.append(metric)
        if reasons:
            failures.append(dict(episode_id=trial["episode_id"], reasons=reasons))
    return dict(scope=config["scope"], trials=len(trials), expected_trials=len(expected),
        coverage_complete=complete, failed_quality_trials=len(failures), failures=failures,
        quality_passed=complete and not failures, release_qualified=False, physical_execution_allowed=False)
