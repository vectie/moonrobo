"""Finite-task temporal value calibration and differentiable return tails."""
import copy
import hashlib
import json

import mujoco
import numpy as np
import torch
from torch import nn

from actor_update_probe import scaled_actor
from policy import gravity, observation, physical_return_targets, step_reward
from temporal_actor import TemporalRunner, episode_points, load_temporal, preview_goals
from temporal_probe import physical_return


class TemporalValue(nn.Module):
    def __init__(self, stats, spec):
        super().__init__()
        self.spec = spec
        for name, value in stats.items():
            self.register_buffer(name, value.clone())
        features = len(self.state_mean) + spec["history_length"] * len(self.obs_mean) + (spec["future_length"] + 1) * len(self.goal_mean) + len(self.context_mean) + 1
        self.net = nn.Sequential(nn.Linear(features, spec["width"]), nn.SiLU(),
            nn.Linear(spec["width"], 64), nn.SiLU(), nn.Linear(64, 1))
        nn.init.zeros_(self.net[-1].weight); nn.init.zeros_(self.net[-1].bias)

    def forward(self, state, history, goals, context, remaining):
        live = (state[:, 2] >= self.spec["fall_height_m"]) & (-gravity(state)[:, 2] >= self.spec["fall_upright_z"])
        state = (state - self.state_mean) / self.state_scale
        state = torch.cat((torch.zeros_like(state[:, :2]), state[:, 2:]), -1)
        encoded = torch.cat((state, ((history - self.obs_mean) / self.obs_scale).flatten(1),
            ((goals - self.goal_mean) / self.goal_scale).flatten(1),
            (context - self.context_mean) / self.context_scale, remaining[:, None] / self.spec["duration_s"]), -1)
        raw = self.net(encoded).squeeze(-1)
        steps = remaining.clamp_min(0) / self.spec["dt_s"]
        bound = 3 * (1 - self.spec["gamma"] ** steps) / (1 - self.spec["gamma"])
        return torch.where(live, bound * torch.tanh(raw / 300), torch.zeros_like(raw))


def make_value(model, actor, config):
    stats = {name: getattr(model, name) for name in ["state_mean", "state_scale", "context_mean", "context_scale"]}
    stats.update({name: getattr(actor.base, name) for name in ["obs_mean", "obs_scale", "goal_mean", "goal_scale"]})
    spec = dict(history_length=10, future_length=10, width=config["critic_width"],
        gamma=config["gamma"], dt_s=.02, duration_s=config["duration_s"],
        fall_height_m=config.get("fall_height_m", .35), fall_upright_z=config.get("fall_upright_z", .5),
        target="finite remaining episode soft return; zero at actual fall or original task end")
    return TemporalValue(stats, spec)


def load_value(path):
    _, data = load_temporal(path)
    if data.get("critic_status") != "finite-horizon-physical-return":
        raise ValueError("checkpoint has no calibrated temporal value model")
    weights = data["critic"]
    names = ["state_mean", "state_scale", "context_mean", "context_scale", "obs_mean", "obs_scale", "goal_mean", "goal_scale"]
    value = TemporalValue({name: weights[name] for name in names}, data["critic_spec"])
    value.load_state_dict(weights); value.eval()
    return value


def finite_imagination(model, actor, critic, state, history, goals, context, remaining, config):
    """Caller supplies starts with >= H32 time remaining; critic sees the H32 history."""
    previous = history[:, -1, -len(actor.base.goal_mean):]
    total, survival = torch.zeros(len(state)), torch.ones(len(state))
    for t in range(config["horizon"]):
        action = actor(history[:, -actor.history_length:], goals[:, t], goals[:, t + 1:t + 1 + actor.future_length])
        state = model(state, action, context)
        reward, continuation = step_reward(state, action, previous, goals[:, t], actor.body["q_indices"], config["target_height_m"])
        total = total + config["gamma"] ** t * survival * reward
        survival = survival * continuation
        history = torch.cat((history[:, 1:], observation(state, action, actor.body)[:, None]), 1)
        previous = action
    if config["actor_critic_bootstrap"]:
        horizon = config["horizon"]
        tail = critic(state, history, goals[:, horizon:horizon + 11], context, remaining - horizon * .02)
        total = total + config["gamma"] ** horizon * survival * tail
    return total.mean()


def episode_value_points(runtime, episode, case, actor, config):
    history, goal, future, action = episode_points(runtime, episode, case, 10, 10)
    state = torch.tensor([s["state"] for s in episode["steps"]], dtype=torch.float32)
    next_state = torch.tensor([s["next_state"] for s in episode["steps"]], dtype=torch.float32)
    context = torch.tensor(episode["context"], dtype=torch.float32)[None].expand(len(state), -1)
    remaining = config["duration_s"] - torch.tensor([s["time_s"] for s in episode["steps"]], dtype=torch.float32)
    with torch.no_grad():
        reward, continuation = step_reward(next_state, action, history[:, -1, -runtime.model.nu:], goal,
            actor.body["q_indices"], config["target_height_m"])
        target = physical_return_targets(reward, continuation,
            torch.tensor([s["terminated"] for s in episode["steps"]]), 0, config["gamma"])
    return (state, history, torch.cat((goal[:, None], future), 1), context, remaining), target


def collect_value_data(runtime, actor, collection, config, reset_seed, capture=False):
    episodes, points, targets, origins = [], [], [], []
    for case in collection["cases"]:
        if case["split"] != "train":
            raise ValueError("temporal value data must be training-only")
        runner = TemporalRunner(runtime, actor, case, reset_seed)
        snapshots = {}
        def trace(rt, step, action, goal):
            if capture and case["id"] in config["probe_cases"] and step in config["probe_steps"]:
                integration = np.empty(mujoco.mj_stateSize(rt.model, mujoco.mjtState.mjSTATE_INTEGRATION))
                mujoco.mj_getState(rt.model, rt.data, integration, mujoco.mjtState.mjSTATE_INTEGRATION)
                snapshots[step] = integration.tolist()
        episode, _ = runtime.rollout(case, reset_seed, "policy", config["duration_s"],
            config["fall_height_m"], config["fall_upright_z"], policy=runner, trace_callback=trace)
        inputs, target = episode_value_points(runtime, episode, case, actor, config)
        episodes.append(episode); points.append(inputs); targets.append(target)
        for step, integration in snapshots.items():
            origins.append(dict(case=case, reset_seed=reset_seed, start_step=step, integration=integration,
                state=episode["steps"][step]["state"], history=inputs[1][step].tolist(),
                nominal=episode["reference_nominal_rad"], reference_schedule=episode.get("reference_schedule"),
                context=episode["context"], remaining_steps=round(config["duration_s"] / runtime.dt) - step,
                reference=episode["steps"][step:step + config["horizon"]],
                reference_full_steps=len(episode["steps"]) - step))
    return episodes, tuple(torch.cat([p[i] for p in points]) for i in range(5)), torch.cat(targets), origins


def actor_replay(runtime, episodes, cases, config):
    pieces = []
    for episode in episodes:
        case = cases[episode["case_id"]]
        history, goal, _, _ = episode_points(runtime, episode, case, 10, 0)
        future = torch.tensor(np.asarray([preview_goals(runtime, case, np.asarray(episode["reference_nominal_rad"]),
            np.asarray(episode["reference_offset_rad"]) if "reference_offset_rad" in episode else None,
            episode.get("reference_schedule"), s["time_s"], config["horizon"] + 10) for s in episode["steps"]]), dtype=torch.float32)
        state = torch.tensor([s["state"] for s in episode["steps"]], dtype=torch.float32)
        context = torch.tensor(episode["context"], dtype=torch.float32)[None].expand(len(state), -1)
        remaining = config["duration_s"] - torch.tensor([s["time_s"] for s in episode["steps"]], dtype=torch.float32)
        keep = remaining >= (config["horizon"] + 1) * runtime.dt
        pieces.append(tuple(v[keep] for v in (state, history, torch.cat((goal[:, None], future), 1), context, remaining)))
    return tuple(torch.cat([p[i] for p in pieces]) for i in range(5))


def fit_value(value, optimizer, points, targets, config, generator):
    before = value_error(value, points, targets)
    for p in value.parameters():
        p.requires_grad_(True)
    for _ in range(config["critic_fit_steps"]):
        indices = torch.randint(len(targets), (config["critic_batch_size"],), generator=generator)
        loss = ((value(*(p[indices] for p in points)) - targets[indices]) / 100).square().mean()
        if not torch.isfinite(loss):
            raise ValueError("nonfinite temporal critic calibration")
        optimizer.zero_grad(); loss.backward()
        torch.nn.utils.clip_grad_norm_(value.parameters(), 1); optimizer.step()
    for p in value.parameters():
        p.requires_grad_(False); p.grad = None
    return dict(before=before, after=value_error(value, points, targets))


@torch.no_grad()
def value_error(value, points, targets):
    predicted = torch.cat([value(*(p[i:i + 256] for p in points)) for i in range(0, len(targets), 256)])
    return dict(points=len(targets), mae=float((predicted - targets).abs().mean()),
        rmse=float((predicted - targets).square().mean().sqrt()), mean_prediction=float(predicted.mean()), mean_target=float(targets.mean()))


def physical_direction_probe(runtime, model, actor, value, origins, config):
    from temporal_probe import command_schedule
    tensor = lambda key: torch.tensor([o[key] for o in origins], dtype=torch.float32)
    goals = torch.tensor(np.asarray([command_schedule(runtime, o, config["horizon"] + 11) for o in origins]))
    batch = (tensor("state"), tensor("history"), goals, tensor("context"), torch.tensor([o["remaining_steps"] * runtime.dt for o in origins]))
    candidate = copy.deepcopy(actor)
    optimizer = torch.optim.Adam(candidate.parameters(), lr=config["actor_learning_rate"])
    before = finite_imagination(model, candidate, value, *batch, config)
    optimizer.zero_grad(); (-before / config["horizon"]).backward()
    norm = float(torch.nn.utils.clip_grad_norm_(candidate.parameters(), 1)); optimizer.step()
    old = dict(actor.named_parameters())
    delta = {name: p.detach() - old[name].detach() for name, p in candidate.named_parameters()}
    records, errors = [], []
    for origin in origins:
        physical_origin = {**origin, "history": origin["history"][-actor.history_length:]}
        base, states, actions = physical_return(runtime, physical_origin, actor, config)
        reference = origin["reference"]
        if len(states) != len(reference) or base["steps"] != origin["reference_full_steps"]:
            raise ValueError("temporal value probe restore length differs")
        error = max(float(np.max(np.abs(np.asarray(v) - np.asarray([s[key] for s in reference]))))
            for v, key in [(states, "next_state"), (actions, "applied_action")])
        if error > 1e-8:
            raise ValueError("temporal value probe restore differs")
        errors.append(error)
        after = physical_return(runtime, physical_origin, candidate, config)[0]
        records.append(dict(case=origin["case"]["id"], start_step=origin["start_step"], baseline=base, candidate=after))
    with torch.no_grad():
        predicted = float(finite_imagination(model, candidate, value, *batch, config) - before.detach())
    result = dict(origins=len(origins), gradient_norm=norm, predicted_change=predicted, maximum_restore_error=max(errors),
        local_physical_change=float(np.mean([r["candidate"]["local_return"] - r["baseline"]["local_return"] for r in records])),
        full_physical_change=float(np.mean([r["candidate"]["full_return"] - r["baseline"]["full_return"] for r in records])), records=records)
    return result, delta
