"""Shared full-body objective and differentiable controller memory for RL."""
import torch
from torch import nn
import numpy as np

from balance_features import quaternion_matrix, rotation_vector, skew, sequence_features
from policy import gravity
from reference_actor import reference_observation


def observer_memory(obs, features, nu=29):
    return torch.cat((features[..., :3], obs[..., 2*nu:2*nu+6], features[..., 3:]), -1)


def observer_advance(geometry, obs, memory, dt, error=None):
    """Current-decision memory -> next-decision features, without truncating EMA."""
    nu = geometry.nu
    e0, g0, w0, v0 = memory[..., :3], memory[..., 3:6], memory[..., 6:9], memory[..., 9:12]
    g, w = obs[..., 2*nu:2*nu+3], obs[..., 2*nu+3:2*nu+6]
    e = geometry.from_observations(obs) if error is None else error
    transport = rotation_vector(-.5*dt*(w+w0))
    unit, previous = g/g.norm(dim=-1, keepdim=True).clamp_min(1e-12), g0/g0.norm(dim=-1, keepdim=True).clamp_min(1e-12)
    predicted = (transport @ previous[..., None]).squeeze(-1)
    cross = skew(torch.linalg.cross(predicted, unit))
    identity = torch.eye(3, dtype=obs.dtype, device=obs.device)
    correction = identity + cross + (cross @ cross)/(1+(predicted*unit).sum(-1)).clamp_min(1e-8)[..., None, None]
    transport = correction @ transport
    v = .8*(transport @ v0[..., None]).squeeze(-1)+.2*(e-(transport @ e0[..., None]).squeeze(-1))/dt
    features = torch.cat((e, v), -1)
    return features, observer_memory(obs, features, nu)


def reference_reward(geometry, state, action, previous, desired_positions, desired_quaternion, desired_joints, dt=.02):
    """The same next-state reward in physics and imagination; not the paper's full reward."""
    local_p, local_r = geometry.body_poses(state[..., 7:36])
    rotation = quaternion_matrix(state[..., 3:7])
    positions = state[..., None, :3] + (rotation[..., None, :, :] @ local_p[..., None]).squeeze(-1)
    body_squared = (positions-desired_positions).square().sum(-1).mean(-1)
    root_squared = (positions[..., 0, :]-desired_positions[..., 0, :]).square().sum(-1)
    q = state[..., 3:7]/state[..., 3:7].norm(dim=-1, keepdim=True).clamp_min(1e-12)
    r = desired_quaternion/desired_quaternion.norm(dim=-1, keepdim=True).clamp_min(1e-12)
    # Sign-invariant smooth local orientation distance; avoids acos gradients at 1.
    orientation_squared = 4*(1-(q*r).sum(-1).square()).clamp_min(0)
    joint_squared = (state[..., 7:36]-desired_joints).square().mean(-1)
    reward = dt*(torch.exp(-body_squared/.05**2)+.5*torch.exp(-root_squared/.05**2)+
        .5*torch.exp(-orientation_squared/.1**2)+torch.exp(-joint_squared/.03**2)-
        .01*((action-previous)/.1).square().mean(-1))
    g = gravity(torch.cat((state[..., :3], q, state[..., 7:]), -1))
    fallen = (state[..., 2] < .35) | (-g[..., 2] < .5)
    # Reuse FK for the next observer rather than evaluating the body twice.
    centers = local_p + (local_r @ geometry.com_positions[..., None]).squeeze(-1)
    com = (centers*geometry.mass_fraction[..., None]).sum(-2)
    feet = local_p[..., geometry.site_bodies, :] + (local_r[..., geometry.site_bodies, :, :] @ geometry.site_positions[..., None]).squeeze(-1)
    difference = com-feet.mean(-2)
    error = difference-g*(difference*g).sum(-1, keepdim=True)
    return reward, fallen, error


class ReferenceSchedule:
    """Learner-side commands only: no source controls, source observations or solver state."""
    def __init__(self, references, geometry, origins):
        self.length = references[0][1].steps
        if any(ref.steps != self.length for _, ref in references):
            raise ValueError("this bounded comparison requires equal clip lengths")
        self.goals = torch.tensor(np.stack([r.goals for _, r in references]), dtype=torch.float32)
        self.positions = torch.tensor(np.stack([r.arrays["body_position"] for _, r in references]), dtype=torch.float32)
        self.quaternions = torch.tensor(np.stack([r.arrays["state"][:, 3:7] for _, r in references]), dtype=torch.float32)
        self.dt = references[0][1].dt
        self.reference_features = {}
        with torch.no_grad():
            for origin in origins:
                for clip in range(len(references)):
                    goals = self.goals[clip, origin:]
                    self.reference_features[(clip, origin)] = sequence_features(geometry,
                        reference_observation(goals), self.dt, window=None)

    def command(self, clips, steps, future_length):
        steps = steps.clamp_max(self.length)
        indices = steps[:, None]+torch.arange(1, future_length+1)[None]
        return self.goals[clips, steps], self.goals[clips[:, None], indices.clamp_max(self.length)], indices <= self.length

    def features(self, clips, origins, steps):
        return torch.stack([self.reference_features[(int(c), int(o))][min(int(s), self.length)-int(o)]
            for c, o, s in zip(clips, origins, steps)])


class ReferenceValue(nn.Module):
    def __init__(self, actor, state_mean, state_scale, clips):
        super().__init__()
        self.register_buffer("state_mean", state_mean.clone())
        self.register_buffer("state_scale", state_scale.clone())
        self.register_buffer("obs_mean", actor.obs_mean.clone()); self.register_buffer("obs_scale", actor.obs_scale.clone())
        self.register_buffer("goal_mean", actor.goal_mean.clone()); self.register_buffer("goal_scale", actor.goal_scale.clone())
        self.clips = clips
        n = 71+actor.history_length*len(actor.obs_mean)+actor.goal_dim+6+2+clips+2+4
        self.net = nn.Sequential(nn.Linear(n, 128), nn.SiLU(), nn.Linear(128, 64), nn.SiLU(), nn.Linear(64, 1))
        nn.init.zeros_(self.net[-1].weight); nn.init.zeros_(self.net[-1].bias)

    def forward(self, state, history, current, features, reference_features, context, clips, steps, remaining, root_position, root_quaternion):
        relative = torch.cat((state[..., :3]-root_position, state[..., 3:]), -1)
        inputs = torch.cat(((relative-self.state_mean)/self.state_scale,
            ((history-self.obs_mean)/self.obs_scale).flatten(1), (current-self.goal_mean)/self.goal_scale,
            features[..., 3:]/.2, reference_features[..., 3:]/.2, context,
            torch.nn.functional.one_hot(clips, self.clips).to(state.dtype),
            steps[:, None]/1500, remaining[:, None]/1500, root_quaternion), -1)
        return 6*torch.tanh(self.net(inputs).squeeze(-1)/6)
