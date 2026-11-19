"""CPU physics adapter for the method-aligned learner (not a throughput benchmark).

PD gains and normalized actions follow smc/BeyondMimic. Physics uses MuJoCo,
not Isaac: this backend must be identified separately in all result reports.
"""
from __future__ import annotations

import numpy as np
import mujoco
import torch

from .mdp import flatten_state
from .motion import CONTROL_DT
from .robot import G1_JOINT_NAMES, action_scale, default_joint_pos_list, motor_of, _kp, _kd
from .rotations import quat_to_mat, mat_to_quat, so3_exp
from .sampling import ReturnBinSampler


class MujocoTrackingEnv:
    def __init__(self, scene, num_envs, motion, mdp, *, seed=0, gamma=.99,
                 eval_mode=False, auto_reset=True, self_collisions=True,
                 randomization=True, reset_noise=True, max_episode_steps=500,
                 physics_dt=.005, context_resampling='episode'):
        if context_resampling not in ('episode', 'environment'):
            raise ValueError('context_resampling must be episode or environment')
        substeps = round(CONTROL_DT/physics_dt)
        if substeps < 1 or abs(substeps*physics_dt-CONTROL_DT) > 1e-10:
            raise ValueError('physics_dt must divide the control interval')
        self.substeps, self.context_resampling = substeps, context_resampling
        self.num_envs, self.device = num_envs, motion.device
        self.motion, self.mdp = motion, mdp
        self.eval_mode, self.auto_reset = eval_mode, auto_reset
        self.gamma, self.max_episode_steps = gamma, max_episode_steps
        self.randomization = randomization and not eval_mode
        self.reset_noise = reset_noise and not eval_mode
        self.evaluation_settings = dict(backend='mujoco-cpu', friction=1.0,
            randomization=self.randomization, observation_noise=False,
            self_collisions=self_collisions, reset_noise=self.reset_noise, scene=str(scene),
            physics_substep_seconds=physics_dt, physics_substeps=substeps,
            control_seconds=CONTROL_DT, context_resampling=context_resampling)
        self.generator = torch.Generator(device=self.device).manual_seed(seed)
        self.sampler = ReturnBinSampler(motion, gamma=gamma, seed=seed)
        self.models = [mujoco.MjModel.from_xml_path(str(scene)) for _ in range(num_envs)]
        self.datas = [mujoco.MjData(m) for m in self.models]
        m = self.models[0]
        self.jids = np.array([m.joint(n).id for n in G1_JOINT_NAMES])
        self.qadr, self.vadr = m.jnt_qposadr[self.jids], m.jnt_dofadr[self.jids]
        self.aids = np.array([int(np.flatnonzero(m.actuator_trnid[:, 0] == j)[0]) for j in self.jids])
        self.torso = m.body('torso_link').id
        self.base_com = [m.body_ipos[self.torso].copy() for m in self.models]
        for m in self.models:
            m.opt.timestep = physics_dt
            for j, aid, name in zip(self.jids, self.aids, G1_JOINT_NAMES):
                effort, _, arm = motor_of(name)
                kp, kd = _kp(arm), _kd(arm)
                m.actuator_gainprm[aid, 0] = kp
                m.actuator_biasprm[aid, :3] = (0, -kp, -kd)
                m.actuator_ctrlrange[aid] = (-1e6, 1e6)
                m.actuator_forcelimited[aid] = True
                m.actuator_forcerange[aid] = (-effort, effort)
                m.dof_armature[m.jnt_dofadr[j]] = arm
            collision = (m.geom_bodyid != 0) & ((m.geom_contype != 0) | (m.geom_conaffinity != 0)
                | (m.geom_group == 3) | (m.geom_group == 4))
            m.geom_contype[collision] = 2
            m.geom_conaffinity[collision] = 3 if self_collisions else 1
            ground = m.geom_bodyid == 0
            m.geom_contype[ground], m.geom_conaffinity[ground] = 1, 2
        self.default_q = torch.tensor(default_joint_pos_list(), device=self.device)
        self.alpha = torch.tensor([action_scale(n) for n in G1_JOINT_NAMES], device=self.device)
        self.f = torch.zeros(num_envs, dtype=torch.long, device=self.device)
        self.ep_step = torch.zeros_like(self.f)
        self.start_bin = torch.zeros_like(self.f)
        self.a_prev = torch.zeros(num_envs, 29, device=self.device)
        self.xi = torch.zeros(num_envs, 33, device=self.device)
        self.context_initialized = torch.zeros(num_envs, dtype=torch.bool, device=self.device)
        self.ep_ret = torch.zeros(num_envs, device=self.device)
        self.ep_disc_ret = torch.zeros_like(self.ep_ret)
        self.reset()

    @torch.no_grad()
    def reset(self, ids=None, frames=None):
        if ids is None:
            ids = torch.arange(self.num_envs, device=self.device)
        if frames is None:
            frames, bins = self.sampler.sample(len(ids))
        else:
            frames = torch.as_tensor(frames, device=self.device, dtype=torch.long)
            bins = self.motion.frame_bin[frames]
        self.f[ids], self.start_bin[ids] = frames, bins
        self.ep_step[ids] = 0
        self.a_prev[ids] = 0
        self.ep_ret[ids], self.ep_disc_ret[ids] = 0, 0
        xi = self.xi[ids].clone()
        if self.randomization:
            fresh = ~self.context_initialized[ids] if self.context_resampling == 'environment' else torch.ones(len(ids), dtype=torch.bool, device=self.device)
            count = int(fresh.sum())
            xi[fresh, 0] = .3 + .9*torch.rand(count, device=self.device, generator=self.generator)
            xi[:, 1:30] = .02*torch.rand(len(ids), 29, device=self.device, generator=self.generator)-.01
            com = .1*torch.rand(count, 3, device=self.device, generator=self.generator)-.05
            com[:, 0] *= .5
            xi[fresh, 30:33] = com
        else:
            xi.zero_()
            xi[:, 0] = 1.
        self.xi[ids] = xi
        self.context_initialized[ids] = True
        p, R, v, w, q, qd = (x.clone() for x in self.motion.ref_state(frames))
        if self.reset_noise:
            def noise(shape):
                return 2*torch.rand(shape, device=self.device, generator=self.generator)-1
            p += noise(p.shape)*p.new_tensor([.05, .05, .01])
            R = so3_exp(noise(p.shape)*p.new_tensor([.1, .1, .2])) @ R
            v += noise(v.shape)*v.new_tensor([.5, .5, .2])
            w += noise(w.shape)*w.new_tensor([.52, .52, .78])
            q += noise(q.shape)*.1
        q = q.clamp(self.mdp.kin.q_lo, self.mdp.kin.q_hi)
        quat = mat_to_quat(R)
        for k, idx in enumerate(ids.tolist()):
            m, d = self.models[idx], self.datas[idx]
            mujoco.mj_resetData(m, d)
            d.qpos[:3] = p[k].cpu().numpy()
            d.qpos[3:7] = quat[k].cpu().numpy()
            d.qpos[self.qadr] = q[k].cpu().numpy()
            d.qvel[:3] = v[k].cpu().numpy()
            d.qvel[3:6] = (R[k].T @ w[k]).cpu().numpy()
            d.qvel[self.vadr] = qd[k].cpu().numpy()
            m.geom_friction[:, 0] = float(xi[k, 0])
            m.geom_friction[m.geom_bodyid == 0, 0] = 1. if self.eval_mode else .3
            m.pair_friction[:, :2] = float(xi[k, 0])
            m.body_ipos[self.torso] = self.base_com[idx]+xi[k, 30:33].cpu().numpy()
            d.ctrl[self.aids] = q[k].cpu().numpy()
            mujoco.mj_forward(m, d)

    def state(self):
        qpos = torch.tensor(np.stack([d.qpos.copy() for d in self.datas]), dtype=torch.float32, device=self.device)
        qvel = torch.tensor(np.stack([d.qvel.copy() for d in self.datas]), dtype=torch.float32, device=self.device)
        R = quat_to_mat(qpos[:, 3:7])
        return qpos[:, :3], R, qvel[:, :3], (R @ qvel[:, 3:6, None]).squeeze(-1), qpos[:, self.qadr], qvel[:, self.vadr]

    @torch.no_grad()
    def step(self, a):
        S = self.state()
        f, xi, prev, ep = self.f.clone(), self.xi.clone(), self.a_prev.clone(), self.ep_step.clone()
        targets = (self.default_q+self.xi[:, 1:30]+self.alpha*a).cpu().numpy()
        for i, (m, d) in enumerate(zip(self.models, self.datas)):
            d.ctrl[self.aids] = targets[i]
            mujoco.mj_step(m, d, nstep=self.substeps)
        S1 = self.state()
        f1 = torch.minimum(f+1, self.motion.clip_end[self.motion.clip_id[f]])
        r = self.mdp.reward(S1, f1, a, prev)
        term = self.mdp.termination(S1, f1)
        timeout = f1 >= self.motion.clip_end[self.motion.clip_id[f]]
        if not self.eval_mode:
            timeout |= ep+1 >= self.max_episode_steps
        done = term | timeout
        out = dict(s=flatten_state(S), s1=flatten_state(S1), a=a.clone(), a_prev=prev,
                   f=f, xi=xi, ep_step=ep, r=r, term=term, timeout=timeout, done=done)
        self.ep_ret += r
        self.ep_disc_ret += self.gamma**ep*r
        self.f, self.ep_step, self.a_prev = f1, ep+1, a.clone()
        ids = done.nonzero(as_tuple=False).flatten()
        if self.auto_reset and len(ids):
            self.sampler.update(self.start_bin[ids], self.ep_disc_ret[ids],
                                episode_lengths=self.ep_step[ids], undiscounted_returns=self.ep_ret[ids], terminated=term[ids])
            self.reset(ids)
        return out

    def state_dict(self):
        spec = mujoco.mjtState.mjSTATE_INTEGRATION
        states = []
        for m, d in zip(self.models, self.datas):
            s = np.empty(mujoco.mj_stateSize(m, spec))
            mujoco.mj_getState(m, d, s, spec)
            states.append(s)
        return dict(physics=states, tensors={n: getattr(self, n).clone() for n in
                    ('f', 'ep_step', 'start_bin', 'a_prev', 'xi', 'ep_ret', 'ep_disc_ret', 'context_initialized')},
                    sampler=self.sampler.state_dict(), rng=self.generator.get_state(), exact_resume=True)

    def load_state_dict(self, state):
        for n, v in state['tensors'].items():
            getattr(self, n).copy_(v)
        self.sampler.load_state_dict(state['sampler'])
        self.generator.set_state(state['rng'].cpu())
        for i, (m, d, s) in enumerate(zip(self.models, self.datas, state['physics'])):
            m.geom_friction[:, 0] = float(self.xi[i, 0])
            m.geom_friction[m.geom_bodyid == 0, 0] = 1. if self.eval_mode else .3
            m.pair_friction[:, :2] = float(self.xi[i, 0])
            m.body_ipos[self.torso] = self.base_com[i]+self.xi[i, 30:33].cpu().numpy()
            mujoco.mj_setState(m, d, s, mujoco.mjtState.mjSTATE_INTEGRATION)
            mujoco.mj_forward(m, d)
            mujoco.mj_setState(m, d, s, mujoco.mjtState.mjSTATE_INTEGRATION)
        return {'exact_resume': True}
