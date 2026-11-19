"""Fitted ankle/waist feedback with optional observed pose and rate inputs."""
import torch
from torch import nn

from balance_features import BalanceKinematics
from learned_balance import LearnedAnkleHead
from temporal_actor import temporal_from_payload


class PoseAnkleHead(LearnedAnkleHead):
    def __init__(self, names, lower, upper, bound, pose_rate):
        super().__init__(names, lower, upper, bound)
        self.pose_rate = pose_rate
        if pose_rate:
            self.mean = torch.zeros(4, 5); self.scale = torch.ones(4, 5)
            self.weight = nn.Parameter(torch.zeros(4, 6))
            self.input_names += ["root_tilt_rad", "root_angular_rate_rad_per_s"]

    def inputs(self, observations, features):
        original = super().inputs(observations, features)
        if not self.pose_rate:
            return original
        gravity = observations[..., 2*self.nu:2*self.nu+3]
        omega = observations[..., 2*self.nu+3:2*self.nu+6]
        pitch = torch.atan2(gravity[..., 0], gravity[..., 1:].norm(dim=-1))
        roll = torch.atan2(-gravity[..., 1], -gravity[..., 2])
        tilt = torch.stack((pitch, roll, pitch, roll), -1)
        rate = omega[..., [1, 0, 1, 0]]
        return torch.cat((original, tilt[..., None], rate[..., None]), -1)


class SustainedBalanceHead(nn.Module):
    def __init__(self, names, lower, upper, pose_rate=True, control_waist=True,
                 output_bound=.45, fit_bound=.45):
        super().__init__()
        self.ankle = PoseAnkleHead(names, lower, upper, fit_bound, pose_rate)
        self.pose_rate, self.control_waist = pose_rate, control_waist
        self.output_bound, self.fit_bound = output_bound, fit_bound
        self.nu, self.waist_index = len(names), names.index("waist_pitch_joint")
        self.indices = self.ankle.indices + ([self.waist_index] if control_waist else [])
        self.register_buffer("waist_lower", torch.as_tensor(lower, dtype=torch.float32)[self.waist_index].clone())
        self.register_buffer("waist_upper", torch.as_tensor(upper, dtype=torch.float32)[self.waist_index].clone())
        self.register_buffer("waist_mean", torch.zeros(2))
        self.register_buffer("waist_scale", torch.ones(2))
        self.waist_weight = nn.Parameter(torch.zeros(3))

    def waist_inputs(self, observations, ankle_inputs, ankle_residual):
        # Remove the fitted own-joint damping before coupling the common pitch
        # signal into the waist. No teacher gain or privileged measurement enters.
        damping = self.ankle.weight[:, 2] / self.ankle.scale[:, 2]
        speed = ankle_inputs[..., 2]
        common = ankle_residual - damping * speed
        pitch = common[..., [0, 2]].mean(-1).clamp(-self.fit_bound, self.fit_bound)
        return torch.stack((pitch, observations[..., self.nu+self.waist_index]), -1)

    def forward(self, observations, goals, features):
        inputs = self.ankle.inputs(observations, features)
        residual = self.ankle.residual(inputs)
        requested = goals[..., self.ankle.indices] + residual.clamp(-self.output_bound, self.output_bound)
        action = requested.maximum(self.ankle.lower).minimum(self.ankle.upper)
        if self.control_waist:
            waist = (self.waist_inputs(observations, inputs, residual) - self.waist_mean) / self.waist_scale
            correction = (waist * self.waist_weight[:2]).sum(-1) + self.waist_weight[2]
            target = goals[..., self.waist_index] + correction.clamp(-self.output_bound, self.output_bound)
            action = torch.cat((action, target.maximum(self.waist_lower).minimum(self.waist_upper)[..., None]), -1)
        return action

    @torch.no_grad()
    def fit(self, observations, goals, targets, features, margin=2e-6):
        inputs = self.ankle.inputs(observations, features)
        report = self.ankle.fit(inputs, goals, targets, margin)
        x = self.waist_inputs(observations, inputs, self.ankle.residual(inputs)).double()
        self.waist_mean.copy_(x.mean(0)); self.waist_scale.copy_(x.std(0, unbiased=False).clamp_min(1e-6))
        design = torch.cat(((x-self.waist_mean.double())/self.waist_scale.double(), torch.ones_like(x[:, :1])), -1)
        y = targets[:, self.waist_index].double(); goal = goals[:, self.waist_index].double()
        residual = y-goal
        mask = ((residual.abs() < self.fit_bound-margin) & (y > self.waist_lower.double()+margin) &
                (y < self.waist_upper.double()-margin))
        solution = torch.linalg.lstsq(design[mask], residual[mask], driver="gelsd")
        if int(solution.rank) != 3:
            raise ValueError("waist training design is not full rank")
        self.waist_weight.copy_(solution.solution)
        raw = self.waist_weight[:2] / self.waist_scale
        bias = self.waist_weight[2] - (raw*self.waist_mean).sum()
        report["waist"] = dict(uncensored_points=int(mask.sum()), raw_coefficients=torch.cat((raw, bias[None])).tolist(),
            coefficient_order=["clipped_fitted_pitch_without_ankle_damping_rad", "waist_speed_rad_per_s", "bias_rad"],
            condition_number=float(solution.singular_values.max()/solution.singular_values.min()),
            residual_fit_rmse_rad=float((design[mask]@solution.solution-residual[mask]).square().mean().sqrt()))
        return report


def save_sustained_balance(path, parent_payload, head, spec, dt, provenance):
    torch.save(dict(format="moonrobo.g1-learned-balance-actor.v2", parent=parent_payload,
        head=head.state_dict(), kinematics=spec, dt_s=dt, window=None, transport="gravity_gyro",
        head_spec=dict(pose_rate=head.pose_rate, control_waist=head.control_waist,
            output_bound=head.output_bound, fit_bound=head.fit_bound),
        controlled_joint_names=[spec["joint_names"][i] for i in head.indices],
        observation_schema="q29,qvel29,root_gravity3,root_angular_velocity3,previous_setpoint29",
        waist_coupling="mean fitted pitch before own-ankle damping, clipped at fit bound; two-input fitted affine waist residual",
        provenance=provenance, critic_status="not-trained", physical_execution_allowed=False), path)


def load_sustained_balance(path):
    data = torch.load(path, weights_only=True)
    if data["format"] != "moonrobo.g1-learned-balance-actor.v2":
        raise ValueError("expected a sustained balance v2 checkpoint")
    parent, _ = temporal_from_payload(data["parent"])
    for parameter in parent.parameters():
        parameter.requires_grad_(False)
    head = SustainedBalanceHead(data["kinematics"]["joint_names"], parent.base.lower, parent.base.upper, **data["head_spec"])
    head.load_state_dict(data["head"]); head.eval()
    return parent, head, BalanceKinematics(data["kinematics"]), data
