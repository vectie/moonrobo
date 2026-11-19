"""Physical G1 adapter. All policy actions and learning updates come from MoonBit."""
import json
import os
from pathlib import Path

import mujoco
import numpy as np
import torch
import mjlab.tasks
from mjlab.envs import ManagerBasedRlEnv
from mjlab.rl import RslRlVecEnvWrapper
from mjlab.utils.torch import configure_torch_backends
from supermimic.tasks.env_cfgs import gencoord_env_cfg
from supermimic.sim_context import SimContext
from supermimic.utils.helpers import extract_action_scale_offset
from motion_source import motion_argument


def geometry(env, command):
    model, robot = env.sim.mj_model, env.scene["robot"]
    q_columns = {int(adr): i for i, adr in enumerate(robot.indexing.joint_q_adr)}
    rows, ids = [], {}
    for global_id in robot.indexing.body_ids.tolist():
        parent = int(model.body_parentid[global_id])
        index = len(rows)
        ids[global_id] = index
        joints = int(model.body_jntnum[global_id])
        j = int(model.body_jntadr[global_id])
        if joints > 1 or (index and joints and model.jnt_type[j] != mujoco.mjtJoint.mjJNT_HINGE):
            raise ValueError("G1 geometry needs a free root and at most one hinge per body")
        rot = np.empty(9)
        mujoco.mju_quat2Mat(rot, model.body_quat[global_id])
        hinge = bool(index and joints)
        adr = int(model.jnt_qposadr[j]) if hinge else -1
        rows.append(dict(name=model.body(global_id).name.split("/")[-1],
                         parent=ids[parent] if index else -1,
                         joint=q_columns[adr] if hinge else -1,
                         axis=model.jnt_axis[j].tolist() if hinge else [0, 0, 0],
                         offset_p=model.body_pos[global_id].tolist(), offset_rotation=rot.tolist(),
                         pivot=model.jnt_pos[j].tolist() if hinge else [0, 0, 0],
                         qref=float(model.qpos0[adr]) if hinge else 0.0))
    # The limits here already include the asset's soft-limit factor.
    limits = robot.data.soft_joint_pos_limits[0].cpu().numpy()
    return dict(bodies=rows, tracked=command.body_indexes.tolist(),
                q_lo=limits[:, 0].tolist(), q_hi=limits[:, 1].tolist())


class Physics:
    def __init__(self, path):
        args = json.loads(Path(path).read_text())
        configure_torch_backends()
        self.panel_play = args.get("panel_play", False)
        self.paper = None
        paper_mode = args.get("paper_catalog", False)
        cfg = gencoord_env_cfg(play=self.panel_play or paper_mode)
        cfg.scene.num_envs = args["environments"]
        cfg.seed = args["seed"]
        cfg.commands["motion"].motion_file = motion_argument(args["motion_file"])
        if paper_mode:
            from paper_catalog import configure
            configure(cfg)
        elif not self.panel_play:
            cfg.commands["motion"].sampling_mode = "external"
        self.env = RslRlVecEnvWrapper(ManagerBasedRlEnv(cfg=cfg, device=args["device"]))
        self.env.reset()
        live = self.env.unwrapped
        self.context = SimContext.from_env(live)
        self.command = live.command_manager.get_term("motion")
        self.motion = self.command.motion
        if paper_mode:
            from paper_catalog import CatalogScorer
            self.paper = CatalogScorer(self, args)
        # MotionLoader has finished its blocking host-to-device copies. On
        # unified-memory machines these clean pages compete with CUDA storage.
        directory = Path(args["motion_file"])
        if directory.is_dir() and hasattr(os, "posix_fadvise"):
            for name in ("root_pos_w", "root_quat_w", "root_lin_vel_w",
                         "root_ang_vel_w", "joint_pos", "joint_vel", "motion_ends"):
                with (directory / (name + ".npy")).open("rb") as stream:
                    os.posix_fadvise(stream.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
        if self.env.num_actions != 29 or self.env.unwrapped.step_dt != 0.02:
            raise ValueError("expected 29 actions and a 50 Hz control clock")
        scale, offset = extract_action_scale_offset(self.env)
        self.actions = [scale.reshape(29), offset.reshape(29)]
        layout = dict(geometry=geometry(live, self.command), context_dim=self.context.output_dim,
                      decimation=cfg.decimation, dt=live.step_dt, frames=self.motion.time_step_total,
                      bins=self.command.bin_count, joint_names=self.motion.fk.joint_names,
                      height=cfg.terminations["anchor_pos"].params["threshold"],
                      tilt=cfg.terminations["anchor_ori"].params["threshold"])
        Path(args["layout"]).write_text(json.dumps(layout))

    @torch.no_grad()
    def exchange(self, op, arg):
        if self.paper is not None and op >= 19:
            return self.paper.exchange(op, arg)
        if op in (0, 1):
            return self.actions[op]
        if op == 2:
            full = self.env.get_observations()["full_state"]
            # mjlab gives xyz, wxyz, joint_pos, v, w, joint_vel.
            return torch.cat((full[:, :7], full[:, 36:42], full[:, 7:36], full[:, 42:]), dim=-1)
        if op == 3:
            return self.context.read(self.env.unwrapped)
        if op == 4:
            return self.command.time_steps.clone()
        if op == 5:
            return self.env.unwrapped.action_manager.action.clone()
        if op == 6:
            _, rew, dones, extras = self.env.step(arg)
            manager = self.env.unwrapped.termination_manager
            timeout = manager.time_outs.bool()
            end = manager.get_term("motion_end").bool()
            return torch.stack((rew, dones.bool(), manager.terminated.bool() & ~timeout,
                                end, timeout & ~end), dim=-1)
        if op == 7:
            self.command.set_sampling_distribution(arg)
            return self.command.time_steps
        if op == 8:
            return self.motion.motion_ends
        if 9 <= op < 15:
            name = ("root_pos_w", "root_quat_w", "root_lin_vel_w", "root_ang_vel_w",
                    "joint_pos", "joint_vel")[op - 9]
            return getattr(self.motion, name)
        if op == 15:
            self.env.reset()
            return self.command.time_steps
        if self.panel_play and op == 16:
            # The published viewer's deterministic seek resets one selected
            # world to an exact frame and forwards the simulator kinematics.
            ends = self.motion.motion_ends
            if ends.numel() != self.env.num_envs:
                raise ValueError("play panel requires one independent world per clip")
            starts = [0, *ends[:-1].tolist()]
            for i, frame in enumerate(starts):
                self.command.reset_to_frame(ends.new_tensor([i]), frame)
            live = self.env.unwrapped
            live.scene.write_data_to_sim()
            live.sim.forward()
            live.sim.sense()
            self.command.update_relative_body_poses()
            live.observation_manager.compute(update_history=True)
            return self.command.time_steps.clone()
        if self.panel_play and op == 17:
            return self.env.unwrapped.scene["robot"].data.encoder_bias
        if self.panel_play and op == 18:
            live = self.env.unwrapped
            ceiling = live.step_dt * sum(t.weight for t in live.cfg.rewards.values() if t.weight > 0.0)
            return self.actions[0].new_tensor([ceiling])
        raise ValueError(f"unexpected physics operation {op}")

    def close(self):
        self.env.close()
