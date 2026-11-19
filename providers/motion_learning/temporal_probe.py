"""Paired temporal-actor parameter directions in restored dynamic physics."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import mujoco
import numpy as np
import torch

from actor_update_probe import scaled_actor
from cpu_physics import PhysicsRuntime
from dynamics import load_model
from policy import step_reward
from temporal_actor import TemporalRunner, load_temporal, temporal_imagination


def command_schedule(runtime, origin, count):
    return np.asarray([runtime.reference(np.asarray(origin["nominal"]), origin["case"]["motion"],
        (origin["start_step"] + t) * runtime.dt, None, origin["reference_schedule"])
        for t in range(count)], dtype=np.float32)


def collect_origins(runtime, actor, experiment, config):
    origins, omitted = [], []
    for case in experiment["cases"]:
        if case["id"] not in config["case_ids"]:
            continue
        if case["split"] != "train" or case["motion"] not in ["stand", "random_joint_sines"]:
            raise ValueError("temporal probe accepts declared training motions only")
        for seed in config["reset_seeds"]:
            runner = TemporalRunner(runtime, actor, case, seed)
            captured = {}
            def capture(rt, step, action, goal):
                if step in config["snapshot_steps"]:
                    integration = np.empty(mujoco.mj_stateSize(rt.model, mujoco.mjtState.mjSTATE_INTEGRATION))
                    mujoco.mj_getState(rt.model, rt.data, integration, mujoco.mjtState.mjSTATE_INTEGRATION)
                    captured[step] = dict(case=case, reset_seed=seed, start_step=step,
                        state=rt.state(), integration=integration.tolist(), history=runner.last_inputs[0][0].tolist(),
                        nominal=runner.nominal.tolist(), reference_schedule=runner.schedule,
                        context=[float(case["friction"]), 1.0], remaining_steps=round(experiment["duration_s"] / rt.dt) - step)
            episode, _ = runtime.rollout(case, seed, "policy", experiment["duration_s"],
                config["fall_height_m"], config["fall_upright_z"], policy=runner, trace_callback=capture)
            for step in config["snapshot_steps"]:
                if step not in captured:
                    omitted.append(dict(case=case["id"], reset_seed=seed, start_step=step))
                    continue
                origin = captured[step]
                origin["reference"] = episode["steps"][step:step + config["horizon"]]
                origin["reference_full_steps"] = len(episode["steps"]) - step
                origins.append(origin)
    return origins, omitted


def physical_return(runtime, origin, actor, config):
    """Restore exact simulator integration state, causal memory and reference phase."""
    original = runtime.data
    runtime.data = mujoco.MjData(runtime.model)
    m, d = runtime.model, runtime.data
    m.opt.disableflags = runtime.base_disable
    m.geom_friction[:, 0] = origin["context"][0]
    m.pair_friction[:, :2] = origin["context"][0]
    history = torch.tensor(origin["history"], dtype=torch.float32)[None]
    goals = command_schedule(runtime, origin, origin["remaining_steps"] + actor.future_length)
    previous = history[0, -1, -m.nu:].numpy().copy()
    states, actions = [], []
    total, survival, local, failed = 0.0, 1.0, None, False
    try:
        mujoco.mj_setState(m, d, np.asarray(origin["integration"]), mujoco.mjtState.mjSTATE_INTEGRATION)
        mujoco.mj_forward(m, d)
        with torch.no_grad():
            for t in range(origin["remaining_steps"]):
                goal = torch.tensor(goals[t])[None]
                future = torch.tensor(goals[t + 1:t + 1 + actor.future_length])[None]
                action = runtime.clip_control(actor(history, goal, future)[0].numpy())
                d.ctrl[:] = action
                mujoco.mj_step(m, d, nstep=runtime.substeps)
                mujoco.mj_forward(m, d)
                state = torch.tensor(runtime.state(), dtype=torch.float32)[None]
                reward, continuation = step_reward(state, torch.tensor(action)[None], torch.tensor(previous)[None],
                    goal, actor.body["q_indices"], config["target_height_m"])
                total += config["gamma"] ** t * survival * float(reward[0])
                survival *= float(continuation[0])
                failed = bool(d.xpos[runtime.root, 2] < config["fall_height_m"] or
                    d.xmat[runtime.root].reshape(3, 3)[2, 2] < config["fall_upright_z"])
                if t < config["horizon"]:
                    states.append(runtime.state()); actions.append(action.tolist())
                if t + 1 == config["horizon"]:
                    local = total
                previous = action.copy()
                history = torch.cat((history[:, 1:], torch.tensor(runtime.observation(previous), dtype=torch.float32)[None, None]), 1)
                if failed:
                    break
        return dict(local_return=total if local is None else local, full_return=total, steps=t + 1,
            failed=failed, local_steps=len(states)), states, actions
    finally:
        runtime.data = original


def imagined_returns(model, actor, batch, config):
    result = temporal_imagination(model, actor, None, *batch, config)
    rewards, continuation = result[2], result[3]
    survival = torch.cat((torch.ones_like(continuation[:, :1]), continuation[:, :-1]), 1).cumprod(1)
    discount = torch.tensor([config["gamma"] ** t for t in range(config["horizon"])])
    return (rewards * survival * discount).sum(1)


def adam_direction(model, actor, batch, config):
    candidate = copy.deepcopy(actor)
    optimizer = torch.optim.Adam(candidate.parameters(), lr=config["actor_learning_rate"])
    objective = temporal_imagination(model, candidate, None, *batch, config)[0]
    optimizer.zero_grad(); (-objective / config["horizon"]).backward()
    norm = float(torch.nn.utils.clip_grad_norm_(candidate.parameters(), 1))
    if not np.isfinite(norm):
        raise ValueError("nonfinite temporal probe gradient")
    optimizer.step()
    original = dict(actor.named_parameters())
    return {name: p.detach() - original[name].detach() for name, p in candidate.named_parameters()}, norm


def open_loop_errors(model, origins, config):
    records = []
    with torch.no_grad():
        for i, origin in enumerate(origins):
            state = torch.tensor(origin["state"], dtype=torch.float32)[None]
            context = torch.tensor(origin["context"], dtype=torch.float32)[None]
            for t, step in enumerate(origin["reference"]):
                state = model(state, torch.tensor(step["applied_action"], dtype=torch.float32)[None], context)
                if t + 1 in config["prediction_steps"]:
                    target = torch.tensor(step["next_state"], dtype=torch.float32)[None]
                    # Absolute horizontal translation is deliberately excluded.
                    mse = ((state[:, 2:] - target[:, 2:]) / model.state_scale[2:]).square().mean()
                    records.append(dict(origin=i, steps=t + 1, normalized_mse=float(mse),
                        root_height_error_m=float(abs(state[0, 2] - target[0, 2]))))
    return records


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    model, metadata = load_model(args.dynamics)
    dynamics_sha = hashlib.sha256(Path(args.dynamics).read_bytes()).hexdigest()
    for p in model.parameters():
        p.requires_grad_(False); p.grad = None
    initial_model = copy.deepcopy(model.state_dict())
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    records, summaries, origins_by_seed, predictions, bindings, centered = [], [], [], [], [], []
    maximum_restore_error = 0.0
    start = time.perf_counter()
    for seed in config["policy_seeds"]:
        incoming_path = Path(args.incoming) / f"actor-seed-{seed}.pt"
        refined_path = Path(args.refined) / f"actor-seed-{seed}.pt"
        actor, actor_meta = load_temporal(incoming_path)
        refined, refined_meta = load_temporal(refined_path)
        incoming_sha = hashlib.sha256(incoming_path.read_bytes()).hexdigest()
        if (refined_meta["initialization"]["sha256"] != incoming_sha or
            refined_meta["initialization"]["dynamics_sha256"] != dynamics_sha or
            actor_meta["model_ref"] != metadata["layout"]["model_ref"] or
            metadata["layout"]["dt_s"] != runtime.dt):
            raise ValueError("temporal checkpoint/dynamics origin differs from declared refinement")
        for name, buffer in actor.named_buffers():
            if not torch.equal(buffer, dict(refined.named_buffers())[name]):
                raise ValueError("selected refinement changed frozen normalization")
        origins, omitted = collect_origins(runtime, actor, experiment, config)
        if not origins:
            raise ValueError("no temporal origins")
        tensor = lambda key: torch.tensor([o[key] for o in origins], dtype=torch.float32)
        schedules = np.asarray([command_schedule(runtime, o, config["horizon"] + actor.future_length + 1) for o in origins])
        batch = (tensor("state"), tensor("history"), torch.tensor(schedules), tensor("context"))
        baselines = []
        for origin in origins:
            outcome, states, actions = physical_return(runtime, origin, actor, config)
            reference = origin["reference"]
            if len(states) != len(reference) or outcome["steps"] != origin["reference_full_steps"]:
                raise ValueError("resumed temporal rollout length differs")
            error = max(float(np.max(np.abs(np.asarray(values) - np.asarray([s[key] for s in reference]))))
                for values, key in [(states, "next_state"), (actions, "applied_action")])
            if error > 1e-8:
                raise ValueError("resumed temporal trajectory differs: " + str(error))
            maximum_restore_error = max(maximum_restore_error, error)
            baselines.append(outcome)
        with torch.no_grad():
            predicted_before = imagined_returns(model, actor, batch, config).numpy()
        delta, norm = adam_direction(model, actor, batch, config)
        actual_delta = {name: p.detach() - dict(actor.named_parameters())[name].detach() for name, p in refined.named_parameters()}
        directions = dict(on_policy_adam=delta, selected_refinement=actual_delta)
        torch.save(dict(actor=actor.state_dict(), directions=directions, config=config,
            incoming_sha256=incoming_sha, refined_sha256=hashlib.sha256(refined_path.read_bytes()).hexdigest()),
            output / f"directions-seed-{seed}.pt")
        prediction = open_loop_errors(model, origins, config)
        predictions.append(dict(seed=seed, records=prediction))
        for label, direction in directions.items():
            nonzero = any(bool(torch.count_nonzero(v)) for v in direction.values())
            outcomes_by_scale = {}
            predicted_by_scale = {}
            for multiplier in config["multipliers"]:
                candidate = scaled_actor(actor, direction, multiplier)
                with torch.no_grad():
                    predicted = imagined_returns(model, candidate, batch, config).numpy()
                outcomes = [physical_return(runtime, origin, candidate, config)[0] for origin in origins] if multiplier and nonzero else baselines
                outcomes_by_scale[multiplier] = outcomes
                predicted_by_scale[multiplier] = predicted
                for i, (before, after) in enumerate(zip(baselines, outcomes)):
                    records.append(dict(seed=seed, direction=label, multiplier=multiplier, origin=i,
                        predicted_before=float(predicted_before[i]), predicted_after=float(predicted[i]), baseline=before, candidate=after))
                for subset in ["all", "dynamic", "stand", "late"]:
                    ids = [i for i, o in enumerate(origins) if subset == "all" or
                        subset == "dynamic" and o["case"]["motion"] == "random_joint_sines" or
                        subset == "stand" and o["case"]["motion"] == "stand" or subset == "late" and o["start_step"] >= 100]
                    mean = lambda values: float(np.mean(values)) if len(values) else None
                    row = dict(seed=seed, direction=label, multiplier=multiplier, subset=subset, origins=len(ids),
                        nonzero_direction=nonzero, predicted_change=mean([predicted[i] - predicted_before[i] for i in ids]),
                        local_physical_change=mean([outcomes[i]["local_return"] - baselines[i]["local_return"] for i in ids]),
                        full_physical_change=mean([outcomes[i]["full_return"] - baselines[i]["full_return"] for i in ids]),
                        full_improves_fraction=mean([outcomes[i]["full_return"] > baselines[i]["full_return"] for i in ids]),
                        mean_steps_change=mean([outcomes[i]["steps"] - baselines[i]["steps"] for i in ids]),
                        baseline_falls=sum(baselines[i]["failed"] for i in ids), candidate_falls=sum(outcomes[i]["failed"] for i in ids))
                    summaries.append(row)
                    if subset == "all" and multiplier == 1:
                        print(json.dumps(row), flush=True)
            scale = config["centered_scale"]
            for i, origin in enumerate(origins):
                plus, minus = outcomes_by_scale[scale][i], outcomes_by_scale[-scale][i]
                centered.append(dict(seed=seed, direction=label, origin=i, nonzero_direction=nonzero,
                    model_slope=float((predicted_by_scale[scale][i] - predicted_by_scale[-scale][i]) / (2 * scale)),
                    local_physics_slope=(plus["local_return"] - minus["local_return"]) / (2 * scale),
                    full_physics_slope=(plus["full_return"] - minus["full_return"]) / (2 * scale)))
        binding = dict(seed=seed, incoming_sha256=incoming_sha, refined_sha256=hashlib.sha256(refined_path.read_bytes()).hexdigest(),
            selected_update=refined_meta["selected_update"], history_length=actor.history_length, future_length=actor.future_length,
            actor_gradient_norm=norm, origins=len(origins), omitted=omitted)
        bindings.append(binding)
        origins_by_seed.append(dict(seed=seed, origins=origins))
    if any(not torch.equal(v, model.state_dict()[k]) for k, v in initial_model.items()) or any(p.grad is not None for p in model.parameters()):
        raise ValueError("probe changed the frozen world model")
    summary = dict(format="moonrobo.g1-temporal-probe.v1", config=config, experiment=experiment, bindings=bindings,
        summaries=summaries, centered=centered, open_loop_predictions=predictions, maximum_restore_error=maximum_restore_error,
        dynamics_sha256=dynamics_sha, dynamics_training_batch_sha256=metadata["training_batch_sha256"],
        provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), elapsed_seconds=time.perf_counter() - start,
        dynamics_unchanged=True, physical_execution_allowed=False,
        scope="Training-only dynamic/control origins. Same causal histories and absolute reference phases in imagined/restored physics. Fresh on-policy Adam and actual previously selected parameter deltas are probes, not new selected policies. Local H32 and remaining-to-10s physical returns have no critic bootstrap; origins overlap within episodes.")
    (output / "report.json").write_text(json.dumps(dict(**summary, origins=origins_by_seed, records=records), indent=2, allow_nan=False))
    (output / "summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "experiment", "incoming", "refined", "dynamics", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
