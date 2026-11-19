"""Physical action branches from restored pre-fall training states."""

import argparse
import hashlib
import json
import math
from pathlib import Path

import mujoco
import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from policy import load_actor


def branch_rollout(runtime, origin, case, predict, delta, config, episode_id):
    original_data = runtime.data
    runtime.data = mujoco.MjData(runtime.model)
    m, d = runtime.model, runtime.data
    try:
        mujoco.mj_setState(m, d, np.array(origin["integration"]), mujoco.mjtState.mjSTATE_INTEGRATION)
        mujoco.mj_forward(m, d)
        previous, goal = np.array(origin["previous"]), np.array(origin["goal"])
        steps, replay, errors = [], [], []
        for i in range(config["branch_steps"]):
            before, obs = runtime.state(), runtime.observation(previous)
            requested = np.asarray(predict(obs, goal))
            pulse = delta if i < config["pulse_steps"] else np.zeros_like(delta)
            action = runtime.clip_control(requested + pulse)
            d.ctrl[:] = action
            mujoco.mj_step(m, d, nstep=runtime.substeps)
            mujoco.mj_forward(m, d)
            after = runtime.state()
            if not np.isfinite(after).all():
                raise ValueError("nonfinite physical branch")
            height = float(d.xpos[runtime.root, 2])
            upright = float(d.xmat[runtime.root].reshape(3, 3)[2, 2])
            fallen = height < config["fall_height_m"] or upright < config["fall_upright_z"]
            error = float(np.square(d.qpos[runtime.q_indices] - goal).mean())
            errors.append(error)
            t = (origin["start_step"] + i) * runtime.dt
            steps.append(dict(time_s=t, state=before, observation=obs, applied_action=action.tolist(),
                next_state=after, goal=goal.tolist(), reward=math.exp(-error / .09),
                terminated=fallen, truncated=not fallen and i == config["branch_steps"] - 1))
            replay.append(dict(time_s=t + runtime.dt, qpos=d.qpos.tolist(), target=goal.tolist(),
                root_height_m=height, upright_z=upright, contacts=int(d.ncon)))
            previous = action.copy()
            if fallen:
                break
        episode = dict(id=episode_id, source_family=case["family"], split="train",
            context=[float(case["friction"]), 1.0], steps=steps,
            parent_episode_id=origin["parent_episode_id"], parent_step=origin["start_step"],
            perturbation_rad=delta.tolist(), pulse_steps=config["pulse_steps"])
        trial = dict(episode_id=episode_id, case_id=case["id"], parent_step=origin["start_step"],
            steps=len(steps), failed=steps[-1]["terminated"], end_reason="fall" if steps[-1]["terminated"] else "branch_time_limit",
            branch_seconds=len(steps) * runtime.dt, parent_elapsed_seconds=origin["start_step"] * runtime.dt,
            joint_rmse_rad=math.sqrt(sum(errors) / len(errors)), replay=replay)
        return episode, trial
    finally:
        runtime.data = original_data


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    torch.set_num_threads(config["cpu_threads"])
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    episodes, trials, parents, omitted, digests = [], [], [], [], {}
    restore_errors = []
    for policy_seed, reset_seed in zip(config["policy_seeds"], config["reset_seeds"]):
        path = Path(args.policies) / f"actor-seed-{policy_seed}.pt"
        actor, _ = load_actor(path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        digests[str(path)] = digest
        def predict(obs, goal):
            with torch.no_grad():
                return actor(torch.tensor(obs, dtype=torch.float32)[None],
                             torch.tensor(goal, dtype=torch.float32)[None])[0].numpy()
        for case in experiment["cases"]:
            if case["split"] != "train":
                continue
            if case["motion"] not in ["stand", "pose_offset"]:
                raise ValueError("branch goals must be constant within the training episode")
            origins, controls = {}, []
            def capture(rt, step, action, goal):
                controls.append(action)
                if step in config["snapshot_steps"]:
                    state = np.empty(mujoco.mj_stateSize(rt.model, mujoco.mjtState.mjSTATE_INTEGRATION))
                    mujoco.mj_getState(rt.model, rt.data, state, mujoco.mjtState.mjSTATE_INTEGRATION)
                    origins[step] = dict(integration=state.tolist(), start_step=step,
                        previous=(controls[step - 1] if step else rt.clip_control(rt.data.qpos[rt.q_indices])).tolist(),
                        goal=goal.tolist())
            parent, parent_trial = runtime.rollout(case, reset_seed, "policy", experiment["duration_s"],
                config["fall_height_m"], config["fall_upright_z"], policy=predict, trace_callback=capture)
            parent_id = parent["id"] + "-" + digest[:12]
            for start in config["snapshot_steps"]:
                if start not in origins:
                    omitted.append(dict(parent_episode_id=parent_id, start_step=start, reason="parent-already-ended"))
                    continue
                origin = origins[start]
                origin["parent_episode_id"] = parent_id
                rng = np.random.default_rng(np.random.SeedSequence([reset_seed, policy_seed, start, 1931]))
                delta = np.clip(rng.normal(0, config["pulse_std_rad"], runtime.model.nu),
                                -config["pulse_clip_rad"], config["pulse_clip_rad"])
                for sign in [0, 1, -1]:
                    episode_id = f"{parent_id}-step-{start}-branch-{sign}"
                    episode, trial = branch_rollout(runtime, origin, case, predict, sign * delta, config, episode_id)
                    trial["pulse_sign"] = sign
                    if sign == 0:
                        recorded = parent["steps"][start:start + len(episode["steps"])]
                        if len(recorded) != len(episode["steps"]):
                            raise ValueError("unperturbed branch length differs from parent")
                        error = max(float(np.max(np.abs(np.array(a[key]) - np.array(b[key]))))
                                    for a, b in zip(recorded, episode["steps"])
                                    for key in ["state", "next_state", "observation", "applied_action"])
                        restore_errors.append(error)
                        if error > 1e-8:
                            raise ValueError("unperturbed branch does not reproduce the original policy: " + str(error))
                    episodes.append(episode)
                    trials.append(trial)
            parents.append(dict(episode_id=parent_id, case_id=case["id"], policy_seed=policy_seed,
                reset_seed=reset_seed, steps=len(parent["steps"]), end_reason=parent_trial["end_reason"],
                origins=list(origins.values())))
    dataset = runtime.dataset(episodes, experiment["source_revision"])
    dataset["dataset_id"] = "g1-counterfactual-physical-branches"
    dataset["provenance"] += "; restored training-only pre-fall integration states, antithetic finite action pulses; original source-family ownership retained"
    summary = dict(episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes),
        falls=sum(t["failed"] for t in trials), branch_time_limits=sum(not t["failed"] for t in trials),
        after_two_second_transitions=sum(s["time_s"] >= 2 for e in episodes for s in e["steps"]),
        maximum_unperturbed_replay_error=max(restore_errors), omitted_origins=len(omitted))
    report = dict(format="moonrobo.g1-counterfactual-collection.v1", config=config, experiment=experiment,
        checkpoint_sha256=digests, summary=summary, parents=parents, omitted=omitted, trials=trials,
        physical_execution_allowed=False, scope="Training data, not qualification trials. Branch time starts at parent elapsed time; finite branch limits are truncations, not successful ten-second control.")
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "dataset.json").write_text(json.dumps(dataset, allow_nan=False))
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    (output / "summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False))
    print(json.dumps(summary))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["policies", "scene", "config", "experiment", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
