"""A fitted observation-only ankle head with an explicitly frozen temporal parent."""
import torch
from torch import nn

from balance_features import BalanceKinematics, ObservationBalanceHistory
from temporal_actor import TemporalRunner, temporal_from_payload


class LearnedAnkleHead(nn.Module):
    def __init__(self, joint_names, lower, upper, residual_bound=.3):
        super().__init__()
        self.nu, self.residual_bound = len(joint_names), residual_bound
        self.indices = [joint_names.index(side + "_ankle_" + axis + "_joint")
            for side in ["left", "right"] for axis in ["pitch", "roll"]]
        self.register_buffer("lower", torch.as_tensor(lower, dtype=torch.float32)[self.indices].clone())
        self.register_buffer("upper", torch.as_tensor(upper, dtype=torch.float32)[self.indices].clone())
        self.register_buffer("mean", torch.zeros(4, 3))
        self.register_buffer("scale", torch.ones(4, 3))
        # Each joint uses horizontal error, its causal velocity, own joint speed, and bias.
        self.weight = nn.Parameter(torch.zeros(4, 4))
        self.input_names = ["error_m", "velocity_m_per_s", "joint_speed_rad_per_s"]

    def inputs(self, observations, features):
        axes = [0, 1, 0, 1]
        return torch.stack((features[..., axes], features[..., [3+a for a in axes]],
            observations[..., [self.nu+i for i in self.indices]]), -1)

    def residual(self, inputs):
        z = (inputs - self.mean) / self.scale
        return (z * self.weight[:, :-1]).sum(-1) + self.weight[:, -1]

    def forward(self, observations, goals, features):
        requested = goals[..., self.indices] + self.residual(self.inputs(observations, features)).clamp(
            -self.residual_bound, self.residual_bound)
        return requested.maximum(self.lower).minimum(self.upper)

    @torch.no_grad()
    def fit(self, inputs, goals, targets, margin=2e-6):
        """OLS on uncensored labels only; saturated commands are not latent residuals.

        Normalization and all sixteen coefficients are fitted on training points.
        Each joint has its own uncensored sample mask. No teacher gains are inputs.
        """
        x, g, y = inputs.double(), goals[..., self.indices].double(), targets[..., self.indices].double()
        self.mean.copy_(x.mean(0)); self.scale.copy_(x.std(0, unbiased=False).clamp_min(1e-6))
        z = (x - self.mean.double()) / self.scale.double()
        design = torch.cat((z, torch.ones_like(z[..., :1])), -1)
        rows = []
        for joint in range(4):
            residual = y[:, joint] - g[:, joint]
            mask = ((residual.abs() < self.residual_bound - margin) &
                (y[:, joint] > self.lower[joint].double() + margin) &
                (y[:, joint] < self.upper[joint].double() - margin))
            matrix, target = design[mask, joint], residual[mask]
            solution = torch.linalg.lstsq(matrix, target, driver="gelsd")
            if int(solution.rank) != x.shape[-1] + 1:
                raise ValueError("uncensored training design is not full rank")
            self.weight[joint].copy_(solution.solution)
            rows.append(dict(uncensored_points=int(mask.sum()), rank=int(solution.rank),
                condition_number=float(solution.singular_values.max() / solution.singular_values.min()),
                residual_fit_rmse_rad=float((matrix @ solution.solution - target).square().mean().sqrt())))
        raw = self.weight[:, :-1] / self.scale
        bias = self.weight[:, -1] - (raw * self.mean).sum(-1)
        return dict(joints=rows, raw_coefficients=torch.cat((raw, bias[:, None]), -1).tolist(),
            coefficient_order=self.input_names + ["bias_rad"],
            method="per-joint float64 OLS on uncensored labels; train-only normalization; float32 inference")


class LearnedBalanceRunner:
    def __init__(self, runtime, parent, head, geometry, case, seed, window, method="gravity_gyro"):
        self.parent = TemporalRunner(runtime, parent, case, seed)
        self.head = head
        self.history = ObservationBalanceHistory(geometry, runtime.dt, window, method)
        self.last_feature = self.last_parent = None

    @torch.no_grad()
    def __call__(self, observation, goal):
        action = self.parent(observation, goal)
        obs, target = torch.tensor(observation, dtype=torch.float32), torch.tensor(goal, dtype=torch.float32)
        self.last_feature = self.history(obs)
        self.last_parent = action.copy()
        action[self.head.indices] = self.head(obs, target, self.last_feature).numpy()
        return action


def save_learned_balance(path, parent_payload, head, spec, window, dt, provenance):
    torch.save(dict(format="moonrobo.g1-learned-balance-actor.v1", parent=parent_payload,
        head=head.state_dict(), kinematics=spec, window=window, dt_s=dt,
        transport="gravity_gyro", residual_bound_rad=head.residual_bound,
        observation_schema="q29,qvel29,root_gravity3,root_angular_velocity3,previous_setpoint29",
        inference="float32; episode-local causal observer; replace four ankle setpoints after frozen parent",
        provenance=provenance, physical_execution_allowed=False), path)


def load_learned_balance(path):
    data = torch.load(path, weights_only=True)
    if data["format"] != "moonrobo.g1-learned-balance-actor.v1":
        raise ValueError("expected a learned balance actor checkpoint")
    parent, _ = temporal_from_payload(data["parent"])
    for parameter in parent.parameters():
        parameter.requires_grad_(False)
    head = LearnedAnkleHead(data["kinematics"]["joint_names"], parent.base.lower, parent.base.upper,
        data["residual_bound_rad"])
    head.load_state_dict(data["head"]); head.eval()
    return parent, head, BalanceKinematics(data["kinematics"]), data
