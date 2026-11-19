"""Differentiable forward kinematics of the G1 in torch, built from the compiled MJCF.

The same FK computes tracked-body poses and velocities for the reference motion, for logged
simulator states, and for world-model predictions, so the analytic reward head matches the
reward the simulator transitions are labeled with.
"""

from __future__ import annotations

import mujoco
import numpy as np
import torch

from .robot import G1_JOINT_NAMES, MJCF_PATH, TRACKED_BODIES
from .rotations import axis_angle_to_mat, quat_to_mat


class G1Kinematics:
    def __init__(self, device: str = "cpu", tracked: list[str] = TRACKED_BODIES,
                 mjcf_path: str = MJCF_PATH, dtype: torch.dtype = torch.float32):
        m = mujoco.MjModel.from_xml_path(str(mjcf_path))
        self.mjcf_path = str(mjcf_path)
        self.device = device
        jname_to_idx = {n: i for i, n in enumerate(G1_JOINT_NAMES)}
        # moving bodies in tree order (mujoco orders parents before children)
        bodies, parent, joint_idx, axes, offs_p, offs_R, pivots, qrefs = [], [], [], [], [], [], [], []
        mj_to_local = {}
        root_id = m.body("pelvis").id
        for b in range(1, m.nbody):
            name = m.body(b).name
            if b != root_id and m.body_parentid[b] not in mj_to_local:
                continue  # unrelated scene bodies
            if m.body_jntnum[b] > 1:
                raise ValueError(f"G1 FK expects at most one joint on body {name}")
            jid = m.body_jntadr[b] if m.body_jntnum[b] else -1
            mj_to_local[b] = len(bodies)
            bodies.append(name)
            if b == root_id:
                if jid < 0 or m.jnt_type[jid] != mujoco.mjtJoint.mjJNT_FREE:
                    raise ValueError("G1 pelvis must have a free joint")
                parent.append(-1)
                joint_idx.append(-1)
            else:
                pb = m.body_parentid[b]
                parent.append(mj_to_local[pb])
                if jid >= 0 and m.jnt_type[jid] != mujoco.mjtJoint.mjJNT_HINGE:
                    raise ValueError(f"G1 non-root joint must be a hinge: {name}")
                joint_idx.append(-1 if jid < 0 else jname_to_idx[m.joint(jid).name])
            axes.append(m.jnt_axis[jid].copy() if jid >= 0 else np.array([0., 0., 1.]))
            offs_p.append(m.body_pos[b].copy())
            offs_R.append(m.body_quat[b].copy())
            pivots.append(m.jnt_pos[jid].copy() if jid >= 0 else np.zeros(3))
            qrefs.append(float(m.qpos0[m.jnt_qposadr[jid]]) if jid >= 0 and b != root_id else 0.)
        self.body_names = bodies
        self.parent = parent
        self.joint_idx = joint_idx
        self.axes = torch.tensor(np.array(axes), dtype=dtype, device=device)
        self.off_p = torch.tensor(np.array(offs_p), dtype=dtype, device=device)
        self.off_R = quat_to_mat(torch.tensor(np.array(offs_R), dtype=dtype, device=device))
        self.pivots = torch.tensor(np.array(pivots), dtype=dtype, device=device)
        self.qrefs = torch.tensor(qrefs, dtype=dtype, device=device)
        self.tracked_idx = [bodies.index(n) for n in tracked]
        self.num_bodies = len(bodies)
        # joint limits (in G1_JOINT_NAMES order)
        lo, hi = np.zeros(29), np.zeros(29)
        for j in range(m.njnt):
            n = m.joint(j).name
            if n in jname_to_idx:
                lo[jname_to_idx[n]], hi[jname_to_idx[n]] = m.jnt_range[j]
        self.q_lo = torch.tensor(lo, dtype=dtype, device=device)
        self.q_hi = torch.tensor(hi, dtype=dtype, device=device)

    def forward(self, p, R, v, w, q, qd, all_bodies: bool = False):
        """Tracked-body world positions, rotations, linear (link-origin) and angular velocities.

        Args:
            p, R, v, w: root (pelvis) position (B,3), rotation (B,3,3), world lin/ang velocity (B,3).
            q, qd: joint positions/velocities (B,29) in G1_JOINT_NAMES order.
        """
        P, Rs, V, W = [None] * self.num_bodies, [None] * self.num_bodies, [None] * self.num_bodies, [None] * self.num_bodies
        for i in range(self.num_bodies):
            par = self.parent[i]
            if par < 0:
                P[i], Rs[i], V[i], W[i] = p, R, v, w
                continue
            j = self.joint_idx[i]
            Rp = Rs[par]
            pi = P[par] + (Rp @ self.off_p[i].unsqueeze(-1)).squeeze(-1)
            R_off = Rp @ self.off_R[i]
            if j < 0:
                Ri, wi = R_off, W[par]
                vi = V[par] + torch.cross(W[par], pi - P[par], dim=-1)
            else:
                rotation = axis_angle_to_mat(self.axes[i], q[..., j] - self.qrefs[i])
                Ri = R_off @ rotation
                pivot_world = pi + (R_off @ self.pivots[i].unsqueeze(-1)).squeeze(-1)
                pi = pivot_world - (Ri @ self.pivots[i].unsqueeze(-1)).squeeze(-1)
                axis_w = (R_off @ self.axes[i].unsqueeze(-1)).squeeze(-1)
                joint_w = axis_w * qd[..., j : j + 1]
                wi = W[par] + joint_w
                vi = (V[par] + torch.cross(W[par], pi - P[par], dim=-1)
                      + torch.cross(joint_w, pi - pivot_world, dim=-1))
            P[i], Rs[i], V[i], W[i] = pi, Ri, vi, wi
        idx = range(self.num_bodies) if all_bodies else self.tracked_idx
        return (
            torch.stack([P[i] for i in idx], -2),
            torch.stack([Rs[i] for i in idx], -3),
            torch.stack([V[i] for i in idx], -2),
            torch.stack([W[i] for i in idx], -2),
        )
