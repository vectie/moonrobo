"""Decode aligned replay tensors into the native MotionDataset numeric contract.

This is a numerical decoder, not experiment orchestration. MoonBit validates,
stores and registers its stdout. The original checkpoint remains authoritative.
"""
from __future__ import annotations

import argparse
import json

import mujoco
import torch

from .kinematics import G1Kinematics
from .mdp import MDP, unflatten_state
from .motion import MotionLib
from .robot import G1_JOINT_NAMES, action_scale, default_joint_pos_list
from .rotations import quat_to_mat


def mujoco_state(state, model):
    """Convert p,quat,v_world,w_world,q_smc,qd_smc to actual MJCF qpos/qvel.

Both layouts have 71 values but are NOT interchangeable. MuJoCo free-root
angular qvel is body-local, and joint slots follow the compiled MJCF order.
    """
    ids = [model.joint(name).id for name in G1_JOINT_NAMES]
    qaddr = torch.as_tensor(model.jnt_qposadr[ids], dtype=torch.long, device=state.device)
    vaddr = torch.as_tensor(model.jnt_dofadr[ids], dtype=torch.long, device=state.device)
    qpos = state.new_zeros(*state.shape[:-1], model.nq)
    qvel = state.new_zeros(*state.shape[:-1], model.nv)
    qpos[..., :7] = state[..., :7]
    qpos[..., qaddr] = state[..., 13:42]
    qvel[..., :3] = state[..., 7:10]
    rotation = quat_to_mat(state[..., 3:7])
    qvel[..., 3:6] = (rotation.transpose(-1, -2) @ state[..., 10:13, None]).squeeze(-1)
    qvel[..., vaddr] = state[..., 42:71]
    if model.na:
        raise ValueError("aligned replay does not store actuator activation state")
    return torch.cat((qpos, qvel), -1)


def axes(prefix, n, unit):
    return [dict(name=f"{prefix}.{i}", unit=unit) for i in range(n)]


@torch.no_grad()
def decode(checkpoint, motion_dir, scene):
    ck = torch.load(checkpoint, map_location="cpu", weights_only=False)
    if ck["format"] != "moonrobo.aligned-checkpoint.v1":
        raise ValueError("expected an aligned checkpoint with replay")
    replay = ck["replay"]
    if replay["format"] != "moonrobo.aligned-replay.v1" or not replay["size"]:
        raise ValueError("checkpoint replay is empty")
    model = mujoco.MjModel.from_xml_path(str(scene))
    kin = G1Kinematics("cpu", mjcf_path=str(scene))
    # Observations and preview goals need root/joint reference features only.
    # Avoid constructing the full corpus' body FK arrays for this decoder.
    motion = MotionLib.from_dir(str(motion_dir), kin, "cpu", compute_body_features=False)
    config = ck["config"]
    mdp = MDP(kin, motion, torch.tensor(default_joint_pos_list()),
              observation_mode=config.get("observation_mode", "observable"))
    rows = replay["data"]
    frames = rows["f"].flatten()
    state, next_state = mujoco_state(rows["s"], model), mujoco_state(rows["s1"], model)
    observations = mdp.obs(unflatten_state(rows["s"]), rows["a_prev"], rows["xi"], rows["f"])
    goals = motion.goal(frames, config.get("goal_frames", 10)).reshape(*rows["f"].shape, -1)
    alpha = torch.tensor([action_scale(name) for name in G1_JOINT_NAMES])
    setpoints = torch.tensor(default_joint_pos_list()) + rows["xi"][..., 1:30] + alpha * rows["a"]
    episodes = []
    for env in range(replay["num_envs"]):
        episode = None
        for age in range(replay["size"]):
            frame = int(rows["f"][age, env])
            boundary = age == 0 or bool(rows["done"][age - 1, env])
            if age:
                boundary |= (int(rows["ep_step"][age, env]) != int(rows["ep_step"][age - 1, env]) + 1
                             or frame != int(rows["f"][age - 1, env]) + 1)
            if boundary:
                episode = dict(id=f"aligned-env-{env}-replay-{age}",
                               source_family=motion.names[int(motion.clip_id[frame])],
                               split="train", context=rows["xi"][age, env].tolist(), steps=[])
                episodes.append(episode)
            if episode["context"] != rows["xi"][age, env].tolist():
                raise ValueError("sim context changed inside a replay episode")
            episode["steps"].append(dict(time_s=int(rows["ep_step"][age, env]) * .02,
                state=state[age, env].tolist(), next_state=next_state[age, env].tolist(),
                observation=observations[age, env].tolist(), applied_action=setpoints[age, env].tolist(),
                goal=goals[age, env].tolist(), reward=float(rows["r"][age, env]),
                terminated=bool(rows["terminated"][age, env]), truncated=bool(rows["truncated"][age, env])))
    qaxes, vaxes = axes("qpos", model.nq, "rad"), axes("qvel", model.nv, "rad/s")
    for i in range(3):
        qaxes[i]["unit"], vaxes[i]["unit"] = "m", "m/s"
    for i in range(3, 7):
        qaxes[i]["unit"] = "1"
    obsaxes = ([dict(name=name + ".relative_position", unit="rad") for name in G1_JOINT_NAMES]
        + [dict(name=name + ".velocity", unit="rad/s") for name in G1_JOINT_NAMES]
        + axes("angular_velocity_local", 3, "rad/s") + axes("projected_gravity", 3, "1")
        + [dict(name=name + ".previous_normalized_action", unit="1") for name in G1_JOINT_NAMES])
    if mdp.obs_dim >= 99:
        obsaxes += axes("reference_relative_orientation_6d", 6, "1")
    if mdp.obs_dim == 102:
        obsaxes += axes("reference_relative_position_local", 3, "m")
    return dict(format="moonrobo.motion-dataset.v1", dataset_id="g1-aligned-replay",
        model_ref="mujoco:" + str(scene) + ":sha256:" + ck["identity"]["scene_sha256"],
        provenance="Retained training replay only; clean observations and preview goals reconstructed from saved physical states. No held-out split; no evaluation transitions included.",
        frame_convention="Explicit aligned71 to compiled MuJoCo qpos/qvel conversion; root quaternion wxyz, linear velocity world, angular velocity body-local; actions are default+calibration+joint-scale*normalized_action setpoints in smc joint order; preview features include qd*0.1.",
        dt_s=.02, state_axes=qaxes + vaxes, observation_axes=obsaxes,
        action_axes=[dict(name=name + ".setpoint", unit="rad") for name in G1_JOINT_NAMES],
        goal_axes=axes("reference_preview", goals.shape[-1], "mixed-scaled"),
        context_axes=[dict(name="friction", unit="1")]
            + [dict(name=name + ".calibration", unit="rad") for name in G1_JOINT_NAMES]
            + axes("torso_com_offset", 3, "m"), episodes=episodes)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--motion-dir", required=True)
    parser.add_argument("--scene", required=True)
    args = parser.parse_args()
    torch.set_num_threads(2)
    print(json.dumps(decode(args.checkpoint, args.motion_dir, args.scene), allow_nan=False))
