"""Analytic MDP contract against Appendix A and independent MuJoCo kinematics."""

import math
from types import SimpleNamespace
import unittest

import mujoco
import numpy as np
import torch

from aligned.kinematics import G1Kinematics
from aligned.mdp import MDP, MAX_STEP_REWARD, flatten_state, unflatten_state
from aligned.robot import G1_JOINT_NAMES, MJCF_PATH, TRACKED_BODIES, action_scale, action_to_setpoint, default_joint_pos_list
from aligned.rotations import mat_to_quat, rot_angle_sq, so3_exp, yaw_mat


class AlignedMDPTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.kin = G1Kinematics("cpu", dtype=torch.float64)
        cls.default = torch.tensor(default_joint_pos_list(), dtype=torch.float64)

    def state(self):
        return (torch.tensor([[0., 0., .78]], dtype=torch.float64),
                torch.eye(3, dtype=torch.float64)[None], torch.zeros(1, 3, dtype=torch.float64),
                torch.zeros(1, 3, dtype=torch.float64), self.default[None].clone(),
                torch.zeros(1, 29, dtype=torch.float64))

    def mdp(self, state, mode="observable"):
        bp, bR, bv, bw = self.kin.forward(*state)
        motion = SimpleNamespace(root_p=state[0], root_R=state[1], body_p=bp,
                                 body_R=bR, body_v=bv, body_w=bw, q=state[4])
        return MDP(self.kin, motion, self.default, observation_mode=mode)

    def test_observable_input_resolves_translation_and_heading_ambiguity(self):
        s = self.state()
        a, xi, f = torch.zeros(1, 29), torch.zeros(1, 33), torch.zeros(1, dtype=torch.long)
        translated = (s[0] + s[0].new_tensor([[.2, 0, 0]]),) + s[1:]
        rotated = (s[0], so3_exp(s[0].new_tensor([[0, 0, math.pi / 6]]))) + s[2:]
        for mode, dim in [("paper", 93), ("smc", 99), ("observable", 102)]:
            mdp = self.mdp(s, mode)
            obs = mdp.obs(s, a, xi, f)
            self.assertEqual(obs.shape[-1], dim)
            delta = mdp.obs(translated, a, xi, f) - obs
            if mode == "observable":
                torch.testing.assert_close(delta[:, -3:], delta.new_tensor([[-.2, 0, 0]]))
                self.assertGreater(float((mdp.obs(rotated, a, xi, f) - obs).abs().sum()), .1)
            else:
                torch.testing.assert_close(delta, torch.zeros_like(delta))

    def test_default_pose_scaled_action_has_no_reference_or_ankle_override(self):
        a = torch.ones(2, 29, dtype=torch.float64, requires_grad=True)
        actual = action_to_setpoint(a)
        scales = a.new_tensor([action_scale(n) for n in G1_JOINT_NAMES])
        torch.testing.assert_close(actual, (self.default + scales).expand(2, -1))
        actual.sum().backward()
        torch.testing.assert_close(a.grad, scales.expand_as(a))
        self.assertTrue(bool((a.grad > 0).all()))

    def test_relative_termination_allows_matching_low_and_sideways_reference(self):
        s = self.state()
        low = (s[0] * 0 + s[0].new_tensor([[0., 0., .12]]),
               so3_exp(s[0].new_tensor([[math.pi / 2, 0, 0]]))) + s[2:]
        mdp = self.mdp(low)
        f = torch.zeros(1, dtype=torch.long)
        self.assertFalse(bool(mdp.termination(low, f).any()))
        bad = (low[0] + low[0].new_tensor([[0, 0, .26]]),) + low[1:]
        self.assertTrue(bool(mdp.termination(bad, f).all()))
        p = (low[0] + low[0].new_tensor([[0, 0, .24]])).requires_grad_(True)
        survival = 1 - mdp.soft_termination((p,) + low[1:], f)
        survival.sum().backward()
        self.assertGreater(float(p.grad.abs().sum()), 1.)
        self.assertTrue(bool(torch.isfinite(p.grad).all()))

    def test_all_reward_terms_and_paper_scales(self):
        s = self.state()
        mdp = self.mdp(s)
        a, f = torch.zeros(1, 29, dtype=torch.float64), torch.zeros(1, dtype=torch.long)
        perfect, terms = mdp.reward(s, f, a, a, terms=True)
        torch.testing.assert_close(perfect, perfect.new_full((1,), MAX_STEP_REWARD), atol=1e-12, rtol=0)
        self.assertEqual(float(terms["e_body_ori"]), 0.)
        self.assertEqual(float(terms["e_root_ori"]), 0.)
        shifted = (s[0] + s[0].new_tensor([[.2, 0, 0]]),) + s[1:]
        reward = mdp.reward(shifted, f, a, a)
        expected = .02 * (4.5 + .5 * math.exp(-(.2 / .3) ** 2))
        self.assertAlmostEqual(float(reward), expected, places=12)
        fast = s[:2] + (s[2] + .2, s[3] + .1) + s[4:]
        changed, errors = mdp.reward(fast, f, a, a, terms=True)
        self.assertGreater(float(errors["e_body_linvel"]), 0.)
        self.assertGreater(float(errors["e_body_angvel"]), 0.)
        self.assertLess(float(changed), float(perfect))
        smoothness = mdp.reward(s, f, a + 1, a)
        self.assertAlmostEqual(float(perfect - smoothness), .02 * .1 * 29, places=12)
        limited_q = s[4].clone()
        limited_q[:, 0] = mdp.soft_hi[0] + .1
        _, penalty = mdp.reward(s[:4] + (limited_q, s[5]), f, a, a, terms=True)
        self.assertAlmostEqual(float(penalty["joint_limit"]), .1, places=12)

    def test_fk_pose_velocity_and_gradient_against_mujoco(self):
        model = mujoco.MjModel.from_xml_path(MJCF_PATH)
        data = mujoco.MjData(model)
        s = self.state()
        s = (s[0] + .1, so3_exp(s[0].new_tensor([[.3, -.2, .4]])),
             s[2] + s[2].new_tensor([[.2, -.3, .4]]), s[3] + .2,
             s[4] + torch.linspace(-.1, .1, 29),
             s[5] + torch.linspace(-.2, .2, 29))
        data.qpos[:3] = s[0][0].numpy()
        data.qpos[3:7] = mat_to_quat(s[1])[0].numpy()
        data.qvel[:3] = s[2][0].numpy()
        data.qvel[3:6] = (s[1][0].T @ s[3][0]).numpy()
        for i, name in enumerate(G1_JOINT_NAMES):
            joint = model.joint(name)
            data.qpos[joint.qposadr[0]] = s[4][0, i]
            data.qvel[joint.dofadr[0]] = s[5][0, i]
        mujoco.mj_forward(model, data)
        q = s[4].clone().requires_grad_(True)
        bp, bR, bv, bw = self.kin.forward(*(s[:4] + (q, s[5])))
        for i, name in enumerate(TRACKED_BODIES):
            body = model.body(name).id
            jacp, jacr = np.zeros((3, model.nv)), np.zeros((3, model.nv))
            mujoco.mj_jacBody(model, data, jacp, jacr, body)
            np.testing.assert_allclose(bp[0, i].detach().numpy(), data.xpos[body], atol=1e-10)
            np.testing.assert_allclose(bR[0, i].detach().numpy(), data.xmat[body].reshape(3, 3), atol=1e-10)
            np.testing.assert_allclose(bv[0, i].detach().numpy(), jacp @ data.qvel, atol=1e-10)
            np.testing.assert_allclose(bw[0, i].detach().numpy(), jacr @ data.qvel, atol=1e-10)
        bp.square().sum().backward()
        self.assertGreater(float(q.grad.abs().sum()), 0.)
        self.assertTrue(bool(torch.isfinite(q.grad).all()))
        reconstructed = unflatten_state(flatten_state(s))
        for original, decoded in zip(s, reconstructed):
            torch.testing.assert_close(original, decoded)

    def test_rotation_distance_gradient_and_vertical_heading(self):
        vec = torch.zeros(2, 3, dtype=torch.float64, requires_grad=True)
        loss = rot_angle_sq(so3_exp(vec), torch.eye(3, dtype=vec.dtype))
        torch.testing.assert_close(loss, torch.zeros_like(loss), atol=0, rtol=0)
        loss.sum().backward()
        self.assertTrue(bool(torch.isfinite(vec.grad).all()))
        vertical = so3_exp(torch.tensor([[0, math.pi / 2, 0]], dtype=torch.float64))
        heading = yaw_mat(vertical)
        torch.testing.assert_close(heading @ heading.transpose(-1, -2), torch.eye(3, dtype=heading.dtype)[None])


if __name__ == "__main__":
    unittest.main()
