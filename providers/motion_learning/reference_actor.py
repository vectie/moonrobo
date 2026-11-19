"""Full-reference encoder/decoder and observation-only relative balance feedback."""
from collections import deque
import hashlib
import json
from pathlib import Path

import numpy as np
import torch
from torch import nn

from balance_features import BalanceKinematics, ObservationBalanceHistory
from full_body_reference import FullBodyReference


def load_references(folder):
    folder = Path(folder)
    manifest = json.loads((folder / "manifest.json").read_bytes())
    references = []
    for clip in manifest["clips"]:
        path = folder / clip["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != clip["sha256"] or clip["split"] != "train":
            raise ValueError("reference initialization accepts unchanged training clips only")
        with np.load(path, allow_pickle=False) as archive:
            references.append((clip, FullBodyReference(dict(archive), manifest["layout"])))
    return manifest, references


def reference_observation(current, nu=29):
    # Current reference state is a command, not a future physical observation.
    # Previous controls are deliberately absent from this constructed reference.
    return torch.cat((current[..., :2*nu], current[..., 2*nu:2*nu+3],
        current[..., 2*nu+7:2*nu+10], torch.zeros_like(current[..., :nu])), -1)


def feedback_inputs(obs, features, indices, nu):
    g = obs[..., 2*nu:2*nu+3]
    pitch = torch.atan2(g[..., 0], g[..., 1:].norm(dim=-1))
    roll = torch.atan2(-g[..., 1], -g[..., 2])
    return torch.stack((features[..., [0, 1, 0, 1]], features[..., [3, 4, 3, 4]],
        obs[..., [nu+i for i in indices]], torch.stack((pitch, roll, pitch, roll), -1),
        obs[..., [2*nu+4, 2*nu+3, 2*nu+4, 2*nu+3]]), -1)


class ReferenceActor(nn.Module):
    def __init__(self, goal_dim, nu, lower, upper, feedback_coefficients, indices,
                 history_length=10, future_length=10, width=128, latent_dim=32, output_bound=.6):
        super().__init__()
        self.goal_dim, self.nu = goal_dim, nu
        self.history_length, self.future_length = history_length, future_length
        self.width, self.latent_dim, self.output_bound = width, latent_dim, output_bound
        self.indices = indices
        for name, value in dict(obs_mean=torch.zeros(3*nu+6), obs_scale=torch.ones(3*nu+6),
            goal_mean=torch.zeros(goal_dim), goal_scale=torch.ones(goal_dim),
            lower=torch.as_tensor(lower, dtype=torch.float32), upper=torch.as_tensor(upper, dtype=torch.float32),
            feedback_coefficients=torch.as_tensor(feedback_coefficients, dtype=torch.float32)).items():
            self.register_buffer(name, value.clone())
        self.goal_encoder = nn.Sequential(nn.Linear((future_length+1)*goal_dim+future_length, width), nn.SiLU(),
            nn.Linear(width, 64), nn.SiLU(), nn.Linear(64, latent_dim), nn.Tanh())
        self.observation_encoder = nn.Sequential(nn.Linear(history_length*(3*nu+6), 64), nn.SiLU(), nn.Linear(64, 64), nn.SiLU())
        self.decoder = nn.Sequential(nn.Linear(latent_dim+64, width), nn.SiLU(), nn.Linear(width, nu))
        nn.init.zeros_(self.decoder[-1].weight); nn.init.zeros_(self.decoder[-1].bias)

    def latent_mean(self, history, current, future, valid):
        planned = torch.cat((current[:, None], future), 1)
        encoded = torch.cat((((planned-self.goal_mean)/self.goal_scale).flatten(1), valid.float()), -1)
        latent = self.goal_encoder(encoded)
        observed = self.observation_encoder(((history-self.obs_mean)/self.obs_scale).flatten(1))
        return self.decoder(torch.cat((latent, observed), -1))

    def action_from_latent(self, latent, history, current, actual_features, reference_features):
        residual = self.output_bound * latent.tanh()
        desired_obs = reference_observation(current, self.nu)
        difference = feedback_inputs(history[:, -1], actual_features, self.indices, self.nu) - \
            feedback_inputs(desired_obs, reference_features, self.indices, self.nu)
        feedback = (difference*self.feedback_coefficients).sum(-1).clamp(-.45, .45)
        # Out-of-place scatter keeps the complete actor differentiable for both
        # subsequent PPO and model-based optimization.
        added = torch.zeros_like(residual).scatter(-1,
            torch.tensor(self.indices, device=residual.device)[None].expand(len(residual), -1), feedback)
        action = current[:, :self.nu] + (residual+added).clamp(-self.output_bound, self.output_bound)
        return action.maximum(self.lower).minimum(self.upper)

    def forward(self, history, current, future, valid, actual_features, reference_features):
        latent = self.latent_mean(history, current, future, valid)
        return self.action_from_latent(latent, history, current, actual_features, reference_features)


class ReferenceRunner:
    def __init__(self, actor, geometry, dt):
        self.actor = actor
        self.frames = deque(maxlen=actor.history_length)
        self.actual = ObservationBalanceHistory(geometry, dt, None)
        self.reference = ObservationBalanceHistory(geometry, dt, None)
        self.last_inputs = None

    @torch.no_grad()
    def __call__(self, obs, current, future, valid):
        observation = torch.as_tensor(obs, dtype=torch.float32)
        if not self.frames:
            self.frames.extend([observation]*self.actor.history_length)
        else:
            self.frames.append(observation)
        target = torch.as_tensor(current, dtype=torch.float32)
        actual_feature = self.actual(observation)
        reference_feature = self.reference(reference_observation(target, self.actor.nu))
        self.last_inputs = (torch.stack(list(self.frames))[None], target[None],
            torch.as_tensor(future, dtype=torch.float32)[None], torch.as_tensor(valid)[None],
            actual_feature[None], reference_feature[None])
        return self.actor(*self.last_inputs)[0].numpy()


def save_reference_actor(path, actor, geometry_spec, dt, provenance, critic_status="not-trained"):
    torch.save(dict(format="moonrobo.g1-reference-actor.v1", state_dict=actor.state_dict(),
        architecture=dict(goal_dim=actor.goal_dim, nu=actor.nu, history_length=actor.history_length,
            future_length=actor.future_length, width=actor.width, latent_dim=actor.latent_dim,
            output_bound=actor.output_bound, indices=actor.indices),
        kinematics=geometry_spec, dt_s=dt, provenance=provenance,
        input_schema="actual observation history; current full-body reference; future reference frames and validity mask; two episode-local causal balance filters",
        action_schema="physical position setpoint = current reference joint position + bounded learned and relative feedback residual; actuator bounds applied",
        critic_status=critic_status, physical_execution_allowed=False), path)


def load_reference_actor(path):
    data = torch.load(path, weights_only=True)
    if data["format"] != "moonrobo.g1-reference-actor.v1":
        raise ValueError("expected full-reference actor")
    state = data["state_dict"]
    actor = ReferenceActor(**data["architecture"], lower=state["lower"], upper=state["upper"],
        feedback_coefficients=state["feedback_coefficients"])
    actor.load_state_dict(state); actor.eval()
    return actor, BalanceKinematics(data["kinematics"]), data
