"""SuperMimic-style multi-step dynamics and imagined actor/GAE critic updates.

Numerical backend adapted from smc/train.py (MIT, see SMC_LICENSE). Collection,
checkpoint orchestration and experiment registration belong to the runner.
"""

from __future__ import annotations

from contextlib import contextmanager

import torch
from torch import nn

from .distributed import average_gradients
from .mdp import CRITIC_EXTRA, INV_DIM, OBS_DIM, normalize_xi, unflatten_state
from .networks import Critic, Policy, WorldModel

DEFAULTS = {
    "wm_hidden": (2048, 2048, 2048), "pi_hidden": (2048, 1024, 512, 256),
    "critic_hidden": (256, 128), "hist": 10, "goal_frames": 10, "horizon": 32,
    "wm_window": 8, "wm_batches": 10, "wm_batch": 2048, "pi_batch": 4096,
    "lr": 2e-4, "gamma": 0.99, "lam": 0.95, "critic_epochs": 5,
    "critic_minibatches": 4, "observation_noise": True,
}


def lambda_returns(rewards, values, terminated, truncated=None, *, gamma=0.99, lam=0.95):
    """GAE value targets for (H,B) rewards and (H+1,B) frozen values.

Fractional terminated values are soft failure probabilities. True failures
remove bootstrap; truncation cuts the trace but retains V(next_state). This
also supports physical timeout unit tests without treating timeouts as falls.
    """
    if rewards.shape != terminated.shape or values.shape != (rewards.shape[0] + 1, *rewards.shape[1:]):
        raise ValueError("invalid GAE trajectory shapes")
    if truncated is None:
        truncated = torch.zeros_like(terminated, dtype=torch.bool)
    result, carry = [], values[-1]
    for t in range(len(rewards) - 1, -1, -1):
        trace = torch.where(truncated[t].bool(), values[t + 1], carry)
        carry = rewards[t] + gamma * (1 - terminated[t].to(rewards.dtype)) * (
            (1 - lam) * values[t + 1] + lam * trace)
        result.append(carry)
    return torch.stack(result[::-1])


@contextmanager
def frozen_parameters(*modules):
    """Keep gradients through module inputs, but never into its learned weights."""
    prior = [(p, p.requires_grad) for module in modules for p in module.parameters()]
    for p, _ in prior:
        p.requires_grad_(False)
        p.grad = None
    try:
        yield
    finally:
        for p, flag in prior:
            p.requires_grad_(flag)


class AlignedLearner:
    def __init__(self, mdp, config: dict | None = None, device: str = "cpu"):
        self.config = {**DEFAULTS, **(config or {})}
        c = self.config
        self.mdp, self.motion, self.device = mdp, mdp.motion, device
        self.K, self.hist, self.horizon = c["goal_frames"], c["hist"], c["horizon"]
        goal_dim = 73 * self.K
        self.wm = WorldModel(hidden=c["wm_hidden"]).to(device)
        self.pi = Policy(getattr(mdp, "obs_dim", OBS_DIM), goal_dim,
                         hist=self.hist, hidden=c["pi_hidden"]).to(device)
        self.critic = Critic(INV_DIM + CRITIC_EXTRA + goal_dim,
                             hidden=c["critic_hidden"]).to(device)
        self.opt_wm = torch.optim.Adam(self.wm.parameters(), lr=c["lr"])
        self.opt_pi = torch.optim.Adam(self.pi.parameters(), lr=c["lr"], betas=(0.9, 0.95))
        self.opt_v = torch.optim.Adam(self.critic.parameters(), lr=c["lr"])
        self.error_floor = torch.cat((torch.full((3,), 3e-3), torch.full((3,), 5e-3),
                                      torch.full((3,), 2e-2), torch.full((3,), 5e-2),
                                      torch.full((29,), 3e-3), torch.full((29,), 5e-2))).to(device)

    def noise(self, obs):
        return self.mdp.add_noise(obs) if self.config["observation_noise"] else obs

    @torch.no_grad()
    def observe(self, tr):
        """Update dynamics normalizers from a physical transition.

        Collection updates policy obs/goal normalizers once, before acting on
        that observation, as in smc. Do not count the same transition twice.
        """
        S, S1 = unflatten_state(tr["s"]), unflatten_state(tr["s1"])
        self.wm.in_norm.update(self.wm.inputs(S, tr["a"], normalize_xi(tr["xi"])))
        self.wm.out_norm.update(self.wm.targets(S, S1))

    def fit_world_model(self, buffer, batches=None):
        c, losses, last_errors = self.config, [], []
        if not buffer.can_sample_windows(c["wm_window"]):
            raise ValueError("insufficient replay: collect warm-up before fitting or after empty resume")
        for _ in range(c["wm_batches"] if batches is None else batches):
            w = buffer.sample_windows(c["wm_batch"], c["wm_window"])
            S = unflatten_state(w["s"][:, 0])
            preds = []
            for j in range(c["wm_window"]):
                S = self.wm.step(S, w["a"][:, j], normalize_xi(w["xi"][:, j]))
                preds.append(S)
            predicted = tuple(torch.stack([x[i] for x in preds], 1) for i in range(6))
            std = torch.maximum(self.wm.out_norm.std(), self.error_floor)
            error = ((self.wm.state_error(predicted, unflatten_state(w["s1"])) / std) ** 2).mean(-1)
            loss = (error * w["mask"]).sum() / error.shape[0]
            self.opt_wm.zero_grad(set_to_none=True)
            loss.backward()
            average_gradients(self.wm)
            gn = nn.utils.clip_grad_norm_(self.wm.parameters(), 1.0, error_if_nonfinite=True)
            self.opt_wm.step()
            losses.append(float(loss.detach() / c["wm_window"]))
            mask = w["mask"][:, -1]
            last_errors.append(float((error[:, -1].detach() * mask).sum() / mask.sum().clamp(min=1)))
        return {"wm_loss": sum(losses) / max(1, len(losses)),
                "wm_err8": sum(last_errors) / max(1, len(last_errors)), "wm_updates": len(losses)}

    def critic_input(self, S, f, xi_n, goal):
        return torch.cat((self.mdp.critic_features(S, f, xi_n), goal), -1)

    def imagine(self, start, history):
        S, f, a_prev = unflatten_state(start["s"]), start["f"], start["a_prev"]
        xi, xi_n = start["xi"], normalize_xi(start["xi"])
        with torch.no_grad():
            obs = self.noise(self.mdp.obs(unflatten_state(history["s"]),
                                         history["a_prev"], history["xi"], history["f"]))
        goals = [self.motion.goal(f, self.K)]
        states, frames, actions, previous_actions = [S], [f], [], []
        for _ in range(self.horizon):
            previous_actions.append(a_prev)
            a = self.pi(obs, goals[-1])
            S = self.wm.step(S, a, xi_n)
            f = f + 1
            current_obs = self.noise(self.mdp.obs(S, a, xi, f))
            obs = torch.cat((obs[:, 1:], current_obs[:, None]), 1)
            a_prev = a
            states.append(S)
            actions.append(a)
            frames.append(f)
            goals.append(self.motion.goal(f, self.K))
        # smc evaluates analytic heads once over the full H*B trajectory. This
        # avoids 32 separate FK dispatches and keeps the same batch reduction
        # order, without changing the sequential dynamics/policy recurrence.
        all_states = tuple(torch.stack([state[i] for state in states[1:]]).flatten(0, 1)
                           for i in range(6))
        all_frames = torch.stack(frames[1:]).flatten()
        rewards = self.mdp.reward(all_states, all_frames, torch.stack(actions).flatten(0, 1),
                                  torch.stack(previous_actions).flatten(0, 1))
        failures = self.mdp.soft_termination(all_states, all_frames)
        return {"states": states, "frames": frames, "goals": goals, "xi_n": xi_n,
                "rewards": rewards.reshape(self.horizon, -1),
                "failures": failures.reshape(self.horizon, -1)}

    def actor_objective(self, trace):
        rewards, failures = trace["rewards"], trace["failures"]
        survival = torch.cumprod(1 - failures, 0)
        before = torch.cat((torch.ones_like(survival[:1]), survival[:-1]), 0)
        discount = self.config["gamma"] ** torch.arange(len(rewards), device=rewards.device,
                                                        dtype=rewards.dtype)
        tail = self.critic(self.critic_input(trace["states"][-1], trace["frames"][-1],
                                            trace["xi_n"], trace["goals"][-1]))
        objective = ((discount[:, None] * before * rewards).sum(0)
                     + self.config["gamma"] ** len(rewards) * survival[-1] * tail)
        return objective.mean(), before, survival

    def update_policy(self, buffer, train_critic=True):
        c = self.config
        start, history = buffer.sample_starts(c["pi_batch"], self.hist,
                                              motion=self.motion, horizon=self.horizon)
        with frozen_parameters(self.wm, self.critic):
            trace = self.imagine(start, history)
            objective, before, survival = self.actor_objective(trace)
            self.opt_pi.zero_grad(set_to_none=True)
            (-objective).backward()
            average_gradients(self.pi)
            gn = nn.utils.clip_grad_norm_(self.pi.parameters(), 1.0, error_if_nonfinite=True)
            nn.utils.clip_grad_value_(self.pi.parameters(), 0.1)
            self.opt_pi.step()
        # Targets use the very same pre-update imagined trajectory, detached from
        # actor/dynamics. Update critic only after actor BPTT has consumed its tail.
        critic_losses = []
        if train_critic:
            with torch.no_grad():
                all_states = tuple(torch.stack([state[i].detach() for state in trace["states"]]).flatten(0, 1)
                                   for i in range(6))
                all_frames = torch.stack(trace["frames"]).flatten()
                all_goals = torch.stack(trace["goals"]).flatten(0, 1)
                all_xi = trace["xi_n"].unsqueeze(0).expand(self.horizon + 1, -1, -1).flatten(0, 1)
                X = self.critic_input(all_states, all_frames, all_xi, all_goals).reshape(
                    self.horizon + 1, c["pi_batch"], -1)
                self.critic.norm.update(X)
                targets = lambda_returns(trace["rewards"].detach(), self.critic(X),
                                         trace["failures"].detach(), gamma=c["gamma"], lam=c["lam"])
                inputs = X[:-1].flatten(0, 1)
                targets = targets.flatten()
            for _ in range(c["critic_epochs"]):
                order = torch.randperm(len(inputs), device=inputs.device)
                for idx in torch.tensor_split(order, min(c["critic_minibatches"], len(order))):
                    loss = ((self.critic(inputs[idx]) - targets[idx]) ** 2).mean()
                    self.opt_v.zero_grad(set_to_none=True)
                    loss.backward()
                    average_gradients(self.critic)
                    nn.utils.clip_grad_norm_(self.critic.parameters(), 1.0, error_if_nonfinite=True)
                    self.opt_v.step()
                    critic_losses.append(float(loss.detach()))
        return {"pi_loss": float(-objective.detach()),
                "v_loss": sum(critic_losses) / max(1, len(critic_losses)),
                "imag_rew": float((before.detach() * trace["rewards"].detach()).mean() / 0.1),
                "pi_gradnorm": float(gn), "imag_survival": float(survival[-1].detach().mean()),
                "actor_updates": 1, "critic_updates": len(critic_losses),
                "imagined_steps": self.horizon * c["pi_batch"], "critic_tail": True}

    def state_dict(self):
        return {"config": self.config, "wm": self.wm.state_dict(), "pi": self.pi.state_dict(),
                "critic": self.critic.state_dict(), "opt_wm": self.opt_wm.state_dict(),
                "opt_pi": self.opt_pi.state_dict(), "opt_v": self.opt_v.state_dict()}

    def load_state_dict(self, state):
        for key in ("wm", "pi", "critic", "opt_wm", "opt_pi", "opt_v"):
            getattr(self, key).load_state_dict(state[key])
