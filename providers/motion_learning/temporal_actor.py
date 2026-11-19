"""Causal observation histories and planned goal previews for the G1 actor."""
import math

import numpy as np
import torch
from torch import nn

from cpu_physics import sample_joint_sines, sample_pose_offset
from policy import Actor, observation, step_reward


def causal_history(observations, times, length, dt):
    if length < 1 or len(observations) != len(times) or not len(times):
        raise ValueError("nonempty aligned observations and positive history required")
    starts, current = [0], 0
    for i in range(1, len(times)):
        if not math.isclose(times[i] - times[i - 1], dt, rel_tol=1e-6, abs_tol=dt * 1e-6):
            current = i
        starts.append(current)
    indices = torch.arange(len(times))[:, None] - torch.arange(length - 1, -1, -1)[None]
    indices = torch.maximum(indices, torch.tensor(starts)[:, None])
    return observations[indices]


def preview_goals(runtime, case, nominal, pose_offset, schedule, time_s, count):
    if not count:
        return np.empty((0, runtime.model.nu), dtype=np.float32)
    return np.asarray([runtime.reference(nominal, case["motion"], time_s + (i + 1) * runtime.dt,
        pose_offset, schedule) for i in range(count)], dtype=np.float32)


class TemporalActor(nn.Module):
    def __init__(self, base, history_length, future_length, width=64):
        super().__init__()
        self.base, self.body = base, base.body
        self.history_length, self.future_length, self.adapter_width = history_length, future_length, width
        features = history_length * len(base.obs_mean) + (1 + future_length) * len(base.goal_mean)
        self.adapter = nn.Sequential(nn.Linear(features, width), nn.SiLU(),
            nn.Linear(width, width), nn.SiLU(), nn.Linear(width, len(base.goal_mean)))
        nn.init.zeros_(self.adapter[-1].weight)
        nn.init.zeros_(self.adapter[-1].bias)

    def latent_mean(self, history, goal, future):
        encoded = [(history - self.base.obs_mean) / self.base.obs_scale,
                   ((goal - self.base.goal_mean) / self.base.goal_scale)[:, None]]
        features = [encoded[0].flatten(1), encoded[1].flatten(1)]
        if self.future_length:
            features.append(((future - self.base.goal_mean) / self.base.goal_scale).flatten(1))
        return self.base.latent_mean(history[:, -1], goal) + self.adapter(torch.cat(features, -1))

    def forward(self, history, goal, future):
        return self.base.action_from_latent(self.latent_mean(history, goal, future), goal)


class TemporalRunner:
    def __init__(self, runtime, actor, case, seed):
        self.runtime, self.actor, self.case, self.seed = runtime, actor, case, seed
        self.frames, self.index = None, 0
        self.nominal = self.offset = self.schedule = None
        self.last_inputs = None

    def __call__(self, obs, goal):
        rt, actor = self.runtime, self.actor
        if self.frames is None:
            self.nominal = rt.data.qpos[rt.q_indices].copy()
            self.offset = sample_pose_offset(rt.names, self.case, self.seed) if self.case["motion"] == "pose_offset" else None
            self.schedule = sample_joint_sines(rt.names, self.case, self.seed) if self.case["motion"] == "random_joint_sines" else None
            self.frames = [torch.tensor(obs, dtype=torch.float32)] * actor.history_length
        else:
            self.frames = self.frames[1:] + [torch.tensor(obs, dtype=torch.float32)]
        history = torch.stack(self.frames)[None]
        expected = rt.reference(self.nominal, self.case["motion"], self.index * rt.dt, self.offset, self.schedule)
        if not np.allclose(expected, goal, atol=1e-10, rtol=1e-10):
            raise ValueError("planned reference and physical current goal disagree")
        future = torch.tensor(preview_goals(rt, self.case, self.nominal, self.offset, self.schedule,
                                           self.index * rt.dt, actor.future_length))[None]
        goal_tensor = torch.tensor(goal, dtype=torch.float32)[None]
        self.last_inputs = (history, goal_tensor, future)
        self.index += 1
        with torch.no_grad():
            return actor(*self.last_inputs)[0].numpy()


def episode_points(runtime, episode, case, history_length, future_length, targets=None):
    steps = episode["steps"]
    if episode["split"] != "train":
        raise ValueError("temporal supervision accepts train episodes only")
    if any(s["terminated"] or s["truncated"] for s in steps[:-1]):
        raise ValueError("history cannot cross a reset boundary")
    obs = torch.tensor([s["observation"] for s in steps], dtype=torch.float32)
    history = causal_history(obs, [s["time_s"] for s in steps], history_length, runtime.dt)
    goal = torch.tensor([s["goal"] for s in steps], dtype=torch.float32)
    nominal = np.asarray(episode["reference_nominal_rad"])
    offset = np.asarray(episode["reference_offset_rad"]) if "reference_offset_rad" in episode else None
    expected = np.asarray([runtime.reference(nominal, case["motion"], s["time_s"], offset, episode.get("reference_schedule")) for s in steps])
    if not np.allclose(expected, goal.numpy(), atol=1e-6, rtol=1e-6):
        raise ValueError("stored current goals differ from their declared reference schedule")
    future = torch.tensor(np.asarray([preview_goals(runtime, case, nominal, offset, episode.get("reference_schedule"),
        s["time_s"], future_length) for s in steps]), dtype=torch.float32)
    values = [s["applied_action"] for s in steps] if targets is None else targets
    if len(values) != len(steps):
        raise ValueError("teacher targets do not match the physical episode")
    return history, goal, future, torch.tensor(values, dtype=torch.float32)


def save_temporal(actor, metadata, config, path, update, evidence, critic=None):
    payload = dict(format="moonrobo.g1-temporal-actor.v1", actor=actor.state_dict(), body=actor.body,
        base_config=metadata["config"], config=config, model_ref=metadata["model_ref"],
        history_length=actor.history_length, future_length=actor.future_length, adapter_width=actor.adapter_width,
        selected_update=update, critic_status="not-trained", initialization=evidence)
    if critic is not None:
        payload.update(critic=critic.state_dict(), critic_spec=critic.spec,
            critic_status="finite-horizon-physical-return")
    torch.save(payload, path)


def load_temporal(path):
    data = torch.load(path, weights_only=True)
    return temporal_from_payload(data)


def temporal_from_payload(data):
    """Restore an embedded frozen parent without a temporary checkpoint file."""
    if data["format"] != "moonrobo.g1-temporal-actor.v1":
        raise ValueError("expected a temporal actor checkpoint")
    weights = data["actor"]
    names = ["obs_mean", "obs_scale", "goal_mean", "goal_scale", "lower", "upper"]
    base = Actor({name: weights["base." + name] for name in names}, data["base_config"], data["body"])
    actor = TemporalActor(base, data["history_length"], data["future_length"], data["adapter_width"])
    actor.load_state_dict(weights)
    actor.eval()
    return actor, data


def temporal_imagination(dynamics, actor, critic, initial, history, goals, context, config):
    """Known goal schedule, causal predicted history; no future physical observations."""
    state, previous = initial, history[:, -1, -len(actor.base.goal_mean):]
    total, survival = torch.zeros(len(state)), torch.ones(len(state))
    states, rewards, continuations = [state], [], []
    for t in range(config["horizon"]):
        goal, future = goals[:, t], goals[:, t + 1:t + 1 + actor.future_length]
        action = actor(history, goal, future)
        state = dynamics(state, action, context)
        reward, continuation = step_reward(state, action, previous, goal, actor.body["q_indices"], config["target_height_m"])
        total = total + config["gamma"] ** t * survival * reward
        survival = survival * continuation
        history = torch.cat((history[:, 1:], observation(state, action, actor.body)[:, None]), 1)
        previous = action
        states.append(state); rewards.append(reward); continuations.append(continuation)
    if config.get("actor_critic_bootstrap", False):
        # This optional diagnostic uses a current-goal critic, not a future-aware value model.
        total = total + config["gamma"] ** config["horizon"] * survival * critic(state, goals[:, config["horizon"]], context)
    return total.mean(), torch.stack(states, 1), torch.stack(rewards, 1), torch.stack(continuations, 1)
