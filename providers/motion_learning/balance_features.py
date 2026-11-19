"""Differentiable root-relative balance geometry from joint/IMU observations.

Only make_spec reads a compiled model's static parameters. Inference uses
Torch and the stored specification, never mjData, global pose or contacts.
"""
from collections import deque

import numpy as np
import torch
from torch import nn


def make_spec(model, foot_sites=("left_foot", "right_foot")):
    import mujoco
    joints = model.actuator_trnid[:, 0].tolist()
    observed = {joint: index for index, joint in enumerate(joints)}
    root = int(model.jnt_bodyid[0])
    if model.jnt_type[0] != mujoco.mjtJoint.mjJNT_FREE or model.body_parentid[root] != 0:
        raise ValueError("balance geometry requires a floating-root hinge tree")
    selected = [root]
    for body in range(root + 1, model.nbody):
        if int(model.body_parentid[body]) in selected:
            selected.append(body)
    body_map = {body: index for index, body in enumerate(selected)}
    bodies = []
    for body in selected:
        if model.body_mocapid[body] >= 0:
            raise ValueError("mocap bodies are not observation-derived geometry")
        scalar = []
        if body != root:
            for joint in range(model.body_jntadr[body], model.body_jntadr[body] + model.body_jntnum[body]):
                if model.jnt_type[joint] != mujoco.mjtJoint.mjJNT_HINGE or joint not in observed:
                    raise ValueError("every moving child joint must have an observed hinge coordinate")
                scalar.append(dict(observation_index=observed[joint], axis=model.jnt_axis[joint].tolist(),
                    anchor=model.jnt_pos[joint].tolist(), reference=float(model.qpos0[model.jnt_qposadr[joint]])))
        bodies.append(dict(name=model.body(body).name, parent=-1 if body == root else body_map[int(model.body_parentid[body])],
            position=model.body_pos[body].tolist(), quaternion_wxyz=model.body_quat[body].tolist(),
            com_position=model.body_ipos[body].tolist(), mass=float(model.body_mass[body]), joints=scalar))
    feet = []
    for name in foot_sites:
        site = model.site(name).id
        feet.append(dict(name=name, body=body_map[int(model.site_bodyid[site])], position=model.site_pos[site].tolist()))
    return dict(format="moonrobo.balance-kinematics.v1", joint_names=[model.joint(j).name for j in joints],
        root_body=model.body(root).name, bodies=bodies, feet=feet,
        input_layout="joint positions, joint velocities, projected gravity, root-local angular velocity, previous actions; 3*nu+6 channels",
        output="root-relative COM minus mean foot-site support, projected onto the supplied gravity-horizontal plane")


def quaternion_matrix(quaternion):
    q = quaternion / quaternion.norm(dim=-1, keepdim=True)
    w, x, y, z = q.unbind(-1)
    return torch.stack((1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w),
        2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w),
        2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)), -1).reshape(q.shape[:-1] + (3, 3))


def skew(vector):
    x, y, z = vector.unbind(-1)
    zero = torch.zeros_like(x)
    return torch.stack((zero, -z, y, z, zero, -x, -y, x, zero), -1).reshape(vector.shape[:-1] + (3, 3))


def rotation_vector(vector):
    # sinc forms are differentiable at zero, including the gyro startup frame.
    angle = vector.norm(dim=-1)
    cross = skew(vector)
    identity = torch.eye(3, dtype=vector.dtype, device=vector.device)
    return identity + torch.sinc(angle / torch.pi)[..., None, None] * cross + \
        (.5 * torch.sinc(angle / (2 * torch.pi)).square())[..., None, None] * (cross @ cross)


class BalanceKinematics(nn.Module):
    def __init__(self, spec, dtype=torch.float32):
        super().__init__()
        self.spec, self.nu = spec, len(spec["joint_names"])
        bodies = spec["bodies"]
        scalar = [joint for body in bodies for joint in body["joints"]]
        tensor = lambda values: torch.tensor(values, dtype=dtype)
        self.register_buffer("positions", tensor([b["position"] for b in bodies]))
        self.register_buffer("rotations", quaternion_matrix(tensor([b["quaternion_wxyz"] for b in bodies])))
        self.register_buffer("com_positions", tensor([b["com_position"] for b in bodies]))
        mass = tensor([b["mass"] for b in bodies])
        self.register_buffer("mass_fraction", mass / mass.sum())
        self.register_buffer("axes", tensor([j["axis"] for j in scalar]).reshape(-1, 3))
        self.register_buffer("anchors", tensor([j["anchor"] for j in scalar]).reshape(-1, 3))
        self.register_buffer("references", tensor([j["reference"] for j in scalar]))
        self.register_buffer("site_positions", tensor([f["position"] for f in spec["feet"]]))
        self.site_bodies = [f["body"] for f in spec["feet"]]
        self.topology = []
        index = 0
        for body in bodies:
            joints = []
            for joint in body["joints"]:
                joints.append((joint["observation_index"], index)); index += 1
            self.topology.append((body["parent"], joints))

    def body_poses(self, joint_positions):
        shape = joint_positions.shape[:-1]
        q = joint_positions.reshape(-1, self.nu)
        position = [q.new_zeros((len(q), 3))]
        rotation = [torch.eye(3, dtype=q.dtype, device=q.device).expand(len(q), -1, -1)]
        for body, (parent, joints) in enumerate(self.topology[1:], 1):
            r = rotation[parent] @ self.rotations[body]
            p = position[parent] + rotation[parent] @ self.positions[body]
            for observed, index in joints:
                anchor = p + r @ self.anchors[index]
                r = r @ rotation_vector((q[:, observed] - self.references[index])[:, None] * self.axes[index])
                p = anchor - r @ self.anchors[index]
            position.append(p); rotation.append(r)
        p, r = torch.stack(position, 1), torch.stack(rotation, 1)
        return p.reshape(shape + (len(self.topology), 3)), r.reshape(shape + (len(self.topology), 3, 3))

    def geometry(self, joint_positions):
        p, r = self.body_poses(joint_positions)
        centers = p + (r @ self.com_positions[..., None]).squeeze(-1)
        com = (centers * self.mass_fraction[..., None]).sum(-2)
        feet = p[..., self.site_bodies, :] + (r[..., self.site_bodies, :, :] @ self.site_positions[..., None]).squeeze(-1)
        return com, feet

    def forward(self, joint_positions, projected_gravity):
        com, feet = self.geometry(joint_positions)
        difference = com - feet.mean(-2)
        gravity = projected_gravity / projected_gravity.norm(dim=-1, keepdim=True).clamp_min(1e-12)
        return difference - gravity * (difference * gravity).sum(-1, keepdim=True)

    def from_observations(self, observations):
        return self(observations[..., :self.nu], observations[..., 2*self.nu:2*self.nu+3])


def observation_transports(gravity, omega, dt, method="gravity_gyro"):
    """Map a vector in the previous root frame into the current root frame."""
    identity = torch.eye(3, dtype=gravity.dtype, device=gravity.device)
    if len(gravity) == 1:
        return identity[None]
    if method == "body_difference":
        return identity[None].expand(len(gravity), -1, -1)
    transport = rotation_vector(-.5 * dt * (omega[1:] + omega[:-1]))
    if method == "gravity_gyro":
        unit = gravity / gravity.norm(dim=-1, keepdim=True).clamp_min(1e-12)
        predicted = (transport @ unit[:-1, :, None]).squeeze(-1)
        cross = skew(torch.linalg.cross(predicted, unit[1:]))
        cosine = (predicted * unit[1:]).sum(-1)
        # Adjacent 20 ms frames in this study are far from antipodal.
        correction = identity + cross + (cross @ cross) / (1 + cosine).clamp_min(1e-8)[:, None, None]
        transport = correction @ transport
    elif method != "gyro":
        raise ValueError("unknown causal frame transport")
    return torch.cat((identity[None], transport), 0)


def causal_velocity(error, transport, dt, window=10):
    previous = torch.cat((error[:1], error[:-1]), 0)
    difference = (error - (transport @ previous[..., None]).squeeze(-1)) / dt
    difference = torch.cat((torch.zeros_like(difference[:1]), difference[1:]), 0)
    if window is None:
        values = [torch.zeros_like(error[0])]
        for index in range(1, len(error)):
            values.append(.8 * (transport[index] @ values[-1]) + .2 * difference[index])
        return torch.stack(values)
    total = torch.zeros_like(error)
    product = torch.eye(3, dtype=error.dtype, device=error.device)[None].expand(len(error), -1, -1)
    times = torch.arange(len(error), device=error.device)
    for lag in range(window - 1):
        index = (times - lag).clamp_min(0)
        contribution = (product @ difference[index, :, None]).squeeze(-1)
        total = total + (.2 * .8 ** lag) * contribution * (times > lag)[:, None]
        product = product @ transport[index]
    return total


def sequence_features(kinematics, observations, dt, window=10, method="gravity_gyro"):
    error = kinematics.from_observations(observations)
    nu = kinematics.nu
    transport = observation_transports(observations[:, 2*nu:2*nu+3], observations[:, 2*nu+3:2*nu+6], dt, method)
    return torch.cat((error, causal_velocity(error, transport, dt, window)), -1)


class ObservationBalanceHistory:
    """Episode-local online feature memory; consumes current observations only."""
    def __init__(self, kinematics, dt, window=10, method="gravity_gyro"):
        self.kinematics, self.dt, self.window, self.method = kinematics, dt, window, method
        # Full causal memory is a filter state, not an ever-growing sequence.
        self.frames = deque(maxlen=2 if window is None else window)
        self.velocity = None

    def __call__(self, observation):
        # Store already computed geometry, avoiding N forward-kinematics passes.
        nu = self.kinematics.nu
        error = self.kinematics.from_observations(observation[None])[0]
        self.frames.append((error, observation[2*nu:2*nu+3], observation[2*nu+3:2*nu+6]))
        error, gravity, omega = [torch.stack([frame[i] for frame in self.frames]) for i in range(3)]
        transport = observation_transports(gravity, omega, self.dt, self.method)
        if self.window is None:
            self.velocity = (torch.zeros_like(error[-1]) if self.velocity is None else
                .8 * (transport[-1] @ self.velocity) + .2 * (error[-1] - transport[-1] @ error[-2]) / self.dt)
            velocity = self.velocity
        else:
            velocity = causal_velocity(error, transport, self.dt, self.window)[-1]
        return torch.cat((error[-1], velocity), -1)


class ObservationAnkleFeedback(nn.Module):
    """Fixed-gain diagnostic controller, not a newly learned policy."""
    def __init__(self, spec, parameters, lower, upper, dtype=torch.float32):
        super().__init__()
        if parameters.get("support_gain", 0):
            raise ValueError("support-force compensation is not in these observation features")
        self.nu, self.parameters_spec = len(spec["joint_names"]), parameters
        self.indices = [spec["joint_names"].index(side + "_ankle_" + axis + "_joint")
            for side in ["left", "right"] for axis in ["pitch", "roll"]]
        self.register_buffer("lower", torch.tensor(lower, dtype=dtype)[self.indices])
        self.register_buffer("upper", torch.tensor(upper, dtype=dtype)[self.indices])

    def forward(self, observations, goals, features):
        c = self.parameters_spec
        error, velocity = features[..., :3], features[..., 3:]
        gravity = observations[..., 2*self.nu:2*self.nu+3]
        omega = observations[..., 2*self.nu+3:2*self.nu+6]
        pitch = torch.atan2(gravity[..., 0], gravity[..., 1:].norm(dim=-1))
        roll = torch.atan2(-gravity[..., 1], -gravity[..., 2])
        p = c["com_gain"] * error[..., 0] + c["velocity_gain"] * velocity[..., 0] + c["pitch_bias_rad"]
        r = -c["com_gain"] * error[..., 1] - c["velocity_gain"] * velocity[..., 1]
        p = p + c["angle_gain"] * pitch + c["rate_gain"] * omega[..., 1]
        r = r + c["angle_gain"] * roll + c["rate_gain"] * omega[..., 0]
        correction = torch.stack((p, r, p, r), -1) - c["joint_damping"] * observations[..., [self.nu+i for i in self.indices]]
        requested = goals[..., self.indices] + correction.clamp(-c["residual_bound_rad"], c["residual_bound_rad"])
        return torch.maximum(torch.minimum(requested, self.upper), self.lower)
