"""Test actual Adam actor-parameter directions in restored closed-loop physics."""

import argparse
import copy
import hashlib
import json
from pathlib import Path

import mujoco
import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from critic_probe import load_critic
from dynamics import WindowBatch, load_model
from policy import imagined_rollout, load_actor, step_reward


def scaled_actor(actor, delta, multiplier):
    result = copy.deepcopy(actor)
    with torch.no_grad():
        for name, parameter in result.named_parameters():
            parameter.add_(delta[name] * multiplier)
    return result


def adam_direction(model, actor, critic, batch, config):
    candidate = copy.deepcopy(actor)
    optimizer = torch.optim.Adam(candidate.parameters(), lr=config["actor_learning_rate"])
    objective = imagined_rollout(model, candidate, critic, *batch, config)[0]
    optimizer.zero_grad()
    (-objective / config["horizon"]).backward()
    norm = float(torch.nn.utils.clip_grad_norm_(candidate.parameters(), 1.0))
    optimizer.step()
    original = dict(actor.named_parameters())
    delta = {name: value.detach() - original[name].detach() for name, value in candidate.named_parameters()}
    return delta, float(objective.detach()), norm


def physical_window(runtime, origin, actor, critic, config):
    original = runtime.data
    runtime.data = mujoco.MjData(runtime.model)
    m, d = runtime.model, runtime.data
    friction = origin["context"][0]
    m.geom_friction[:, 0] = friction
    m.pair_friction[:, :2] = friction
    try:
        mujoco.mj_setState(m, d, np.array(origin["integration"]), mujoco.mjtState.mjSTATE_INTEGRATION)
        mujoco.mj_forward(m, d)
        previous = np.array(origin["previous"])
        goal = torch.tensor(origin["goal"], dtype=torch.float32)[None]
        context = torch.tensor(origin["context"], dtype=torch.float32)[None]
        total, survival, failed, states, actions = 0.0, 1.0, False, [], []
        with torch.no_grad():
            for t in range(config["horizon"]):
                obs = torch.tensor(runtime.observation(previous), dtype=torch.float32)[None]
                action = runtime.clip_control(actor(obs, goal)[0].numpy())
                d.ctrl[:] = action
                mujoco.mj_step(m, d, nstep=runtime.substeps)
                mujoco.mj_forward(m, d)
                state = torch.tensor(runtime.state(), dtype=torch.float32)[None]
                reward, continuation = step_reward(state, torch.tensor(action)[None],
                    torch.tensor(previous)[None], goal, actor.body["q_indices"], config["target_height_m"])
                total += config["gamma"] ** t * survival * float(reward[0])
                survival *= float(continuation[0])
                states.append(runtime.state()); actions.append(action.tolist())
                previous = action.copy()
                failed = d.xpos[runtime.root, 2] < config["fall_height_m"] or d.xmat[runtime.root].reshape(3, 3)[2, 2] < config["fall_upright_z"]
                if failed:
                    survival = 0.0
                    break
            tail = config["gamma"] ** len(states) * survival * float(critic(state, goal, context)[0]) if config.get("actor_critic_bootstrap", True) else 0.0
        return dict(reward_return=total, bootstrapped_return=total + tail, critic_tail=tail,
                    failed=bool(failed), steps=len(states)), states, actions
    finally:
        runtime.data = original


def collect_origins(runtime, actor, experiment, config):
    origins, omitted = [], []
    def predict(obs, goal):
        with torch.no_grad():
            return actor(torch.tensor(obs, dtype=torch.float32)[None],
                         torch.tensor(goal, dtype=torch.float32)[None])[0].numpy()
    for case in experiment["cases"]:
        if case["split"] != "train":
            continue
        if case["motion"] not in ["stand", "pose_offset"]:
            raise ValueError("this probe uses constant-goal training families")
        for seed in config["reset_seeds"]:
            captured, controls = {}, []
            def capture(rt, step, action, goal):
                controls.append(action)
                if step in config["snapshot_steps"]:
                    integration = np.empty(mujoco.mj_stateSize(rt.model, mujoco.mjtState.mjSTATE_INTEGRATION))
                    mujoco.mj_getState(rt.model, rt.data, integration, mujoco.mjtState.mjSTATE_INTEGRATION)
                    captured[step] = dict(case=case["id"], reset_seed=seed, start_step=step,
                        time_s=step * rt.dt, state=rt.state(), integration=integration.tolist(),
                        previous=(controls[step - 1] if step else rt.clip_control(rt.data.qpos[rt.q_indices])).tolist(),
                        goal=goal.tolist(), context=[float(case["friction"]), 1.0])
            episode, _ = runtime.rollout(case, seed, "policy", experiment["duration_s"],
                config["fall_height_m"], config["fall_upright_z"], policy=predict, trace_callback=capture)
            for start in config["snapshot_steps"]:
                if start not in captured:
                    omitted.append(dict(case=case["id"], reset_seed=seed, start_step=start))
                    continue
                origin = captured[start]
                origin["reference"] = episode["steps"][start:start + config["horizon"]]
                origins.append(origin)
    return origins, omitted


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    replay = WindowBatch(args.train, "train")
    model, metadata = load_model(args.dynamics)
    if replay.digest != metadata["training_batch_sha256"] or replay.layout != metadata["layout"]:
        raise ValueError("probe replay must match the frozen world model")
    for parameter in model.parameters():
        parameter.requires_grad_(False)
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    records, summaries, saved_origins, checkpoints = [], [], [], {}
    restore_errors = []
    for seed in config["policy_seeds"]:
        checkpoint = Path(args.policies) / f"actor-seed-{seed}.pt"
        checkpoints[str(checkpoint)] = hashlib.sha256(checkpoint.read_bytes()).hexdigest()
        actor, actor_meta = load_actor(checkpoint)
        critic, _ = load_critic(checkpoint)
        for parameter in critic.parameters():
            parameter.requires_grad_(False)
        settings = {**actor_meta["config"], **config}
        origins, omitted = collect_origins(runtime, actor, experiment, settings)
        n = len(origins)
        if not n:
            raise ValueError("no physical origins")
        tensor = lambda name: torch.tensor([o[name] for o in origins], dtype=torch.float32)
        recent = (tensor("state"), tensor("previous"), tensor("goal"), tensor("context"))
        torch.manual_seed(config["sampling_seed"] + seed)
        indices = torch.randint(len(replay.state), (n,))
        offline = (replay.state[indices, 0], replay.observation[indices, 0, -runtime.model.nu:],
                   replay.goal[indices, 0], replay.context[indices])
        baselines = []
        for origin in origins:
            baseline, states, actions = physical_window(runtime, origin, actor, critic, settings)
            reference = origin.pop("reference")
            if len(states) != len(reference):
                raise ValueError("restored closed-loop length changed")
            error = max(float(np.max(np.abs(np.array(values) - np.array([s[key] for s in reference]))))
                        for values, key in [(states, "next_state"), (actions, "applied_action")])
            if error > 1e-8:
                raise ValueError("restored closed-loop physics differs: " + str(error))
            restore_errors.append(error)
            baselines.append(baseline)
        directions = {}
        for label, batch in [("replay", offline), ("on-policy", recent)]:
            delta, before, norm = adam_direction(model, actor, critic, batch, settings)
            directions[label] = delta
            with torch.no_grad():
                recent_before = float(imagined_rollout(model, actor, critic, *recent, settings)[0])
            for multiplier in config["multipliers"]:
                candidate = scaled_actor(actor, delta, multiplier)
                with torch.no_grad():
                    predicted = float(imagined_rollout(model, candidate, critic, *batch, settings)[0])
                    predicted_recent = float(imagined_rollout(model, candidate, critic, *recent, settings)[0])
                outcomes = []
                for i, origin in enumerate(origins):
                    result = baselines[i] if multiplier == 0 else physical_window(runtime, origin, candidate, critic, settings)[0]
                    outcomes.append(result)
                    records.append(dict(policy_seed=seed, distribution=label, multiplier=multiplier,
                        case=origin["case"], reset_seed=origin["reset_seed"], start_step=origin["start_step"],
                        baseline=baselines[i], candidate=result))
                summaries.append(dict(policy_seed=seed, distribution=label, multiplier=multiplier,
                    origins=n, omitted_origins=len(omitted), actor_gradient_norm=norm,
                    model_fit_objective_change=predicted - before,
                    model_recent_objective_change=predicted_recent - recent_before,
                    physical_bootstrapped_change=float(np.mean([r["bootstrapped_return"] - b["bootstrapped_return"] for r, b in zip(outcomes, baselines)])),
                    physical_reward_change=float(np.mean([r["reward_return"] - b["reward_return"] for r, b in zip(outcomes, baselines)])),
                    physical_improves_fraction=float(np.mean([r["bootstrapped_return"] > b["bootstrapped_return"] for r, b in zip(outcomes, baselines)])),
                    baseline_falls=sum(b["failed"] for b in baselines), candidate_falls=sum(r["failed"] for r in outcomes)))
        torch.save(dict(actor=actor.state_dict(), critic=critic.state_dict(), config=actor_meta["config"],
                        body=actor.body, directions=directions), output / f"directions-seed-{seed}.pt")
        saved_origins.append(dict(policy_seed=seed, origins=origins, omitted=omitted))
    report = dict(format="moonrobo.g1-actor-update-probe.v1", config=config, experiment=experiment,
        training_batch_sha256=replay.digest, dynamics_sha256=hashlib.sha256(Path(args.dynamics).read_bytes()).hexdigest(),
        checkpoint_sha256=checkpoints, maximum_restore_error=max(restore_errors), summaries=summaries,
        origins=saved_origins, records=records, physical_execution_allowed=False,
        scope="One fresh-optimizer Adam step per distribution. Same restored origins and fixed critic; physical reward and critic-bootstrapped return are separate. No full ten-second qualification or release selection.")
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    (output / "summary.json").write_text(json.dumps({k: v for k, v in report.items() if k not in ["origins", "records"]}, indent=2, allow_nan=False))
    print(json.dumps(dict(report=str(output / "report.json"), maximum_restore_error=max(restore_errors))))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["train", "dynamics", "policies", "scene", "config", "experiment", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
