"""Numerical contract against the actual sibling smc source, not a rewritten oracle.

Only simulator-dependent import scaffolding is replaced. Every MDP, FK and
rotation function under comparison is executed from ../smc/supermimic itself.
The tests skip when that optional reference checkout is not available.
"""
import importlib.util
import json
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest

import torch

from aligned import mdp as actual_mdp
from aligned import rotations as actual_rot
from aligned.kinematics import G1Kinematics
from aligned.robot import G1_JOINT_NAMES, MJCF_PATH, TRACKED_BODIES, default_joint_pos_list


SOURCE = Path(__file__).resolve().parents[2].parent / "smc" / "supermimic"


def upstream_modules():
    """Load upstream math without importing Isaac Lab or modifying its checkout."""
    package_name = "_smc_mdp_differential_reference"
    package = ModuleType(package_name)
    package.__path__ = [str(SOURCE)]
    sys.modules[package_name] = package
    robot = ModuleType(package_name + ".robot")
    robot.G1_JOINT_NAMES, robot.TRACKED_BODIES = G1_JOINT_NAMES, TRACKED_BODIES
    robot.MJCF_PATH = MJCF_PATH
    sys.modules[robot.__name__] = robot
    motion = ModuleType(package_name + ".motion")
    motion.CONTROL_DT, motion.MotionLib = .02, object
    sys.modules[motion.__name__] = motion
    out = {}
    for name in ("rotations", "kinematics", "mdp"):
        spec = importlib.util.spec_from_file_location(package_name + "." + name, SOURCE / (name + ".py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        out[name] = module
    return out


@unittest.skipUnless((SOURCE / "mdp.py").exists(), "optional sibling smc source is unavailable")
class AlignedMDPDifferentialTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = upstream_modules()
        cls.kin = G1Kinematics("cpu", dtype=torch.float64)
        cls.default = torch.tensor(default_joint_pos_list(), dtype=torch.float64)

    def fixture(self):
        rng = torch.Generator().manual_seed(261028480)
        def noise(*shape):
            return torch.randn(shape, generator=rng, dtype=torch.float64)
        count = 12
        rp = noise(count, 3) * .2 + torch.tensor([0., 0., .8])
        rR = actual_rot.so3_exp(noise(count, 3) * .25)
        rv, rw = noise(count, 3) * .3, noise(count, 3) * .2
        rq, rqd = self.default + noise(count, 29) * .08, noise(count, 29) * .1
        bp, bR, bv, bw = self.kin.forward(rp, rR, rv, rw, rq, rqd)
        motion = SimpleNamespace(root_p=rp, root_R=rR, body_p=bp, body_R=bR, body_v=bv, body_w=bw, q=rq)
        p = (rp + noise(count, 3) * .15).requires_grad_()
        rotation = (noise(count, 3) * .22 + .15).requires_grad_()
        R = actual_rot.so3_exp(rotation) @ rR
        v, w = rv + noise(count, 3) * .3, rw + noise(count, 3) * .2
        q = (rq + noise(count, 29) * .15).requires_grad_()
        qd = rqd + noise(count, 29) * .2
        state = p, R, v, w, q, qd
        actions, previous = noise(count, 29) * .2, noise(count, 29) * .2
        xi = noise(count, 33) * .01
        xi[:, 0] = .75
        return motion, state, actions, previous, xi, torch.arange(count), (p, rotation, q)

    def test_head_values_and_gradients_match_smc_away_from_rotation_singularities(self):
        motion, state, action, previous, xi, frames, leaves = self.fixture()
        ref = self.upstream["mdp"].MDP(self.kin, motion, self.default)
        ours = actual_mdp.MDP(self.kin, motion, self.default, observation_mode="smc")
        observation = ours.obs(state, previous, xi, frames)
        torch.testing.assert_close(observation, ref.obs(state, previous, xi, frames), rtol=0, atol=0)
        torch.manual_seed(710)
        noisy = ours.add_noise(observation)
        torch.manual_seed(710)
        torch.testing.assert_close(noisy, ref.add_noise(observation), rtol=0, atol=0)
        torch.testing.assert_close(ours.termination(state, frames), ref.termination(state, frames), rtol=0, atol=0)
        torch.testing.assert_close(ours.soft_termination(state, frames), ref.soft_termination(state, frames), rtol=0, atol=0)
        ours_reward, ours_terms = ours.reward(state, frames, action, previous, terms=True)
        ref_reward, ref_terms = ref.reward(state, frames, action, previous, terms=True)
        # smc's yaw epsilon makes its reference rotation slightly non-orthogonal.
        # We retain proper SO(3) normalization and the exact quaternion-log loss.
        torch.testing.assert_close(ours_reward, ref_reward, rtol=0, atol=2e-9)
        for name in ref_terms:
            torch.testing.assert_close(ours_terms[name], ref_terms[name], rtol=0, atol=1e-8)
        ours_critic = ours.critic_features(state, frames, xi)
        ref_critic = ref.critic_features(state, frames, xi)
        torch.testing.assert_close(ours_critic, ref_critic, rtol=0, atol=2e-8)
        ours_grad = torch.autograd.grad(ours_reward.sum(), leaves, retain_graph=True)
        ref_grad = torch.autograd.grad(ref_reward.sum(), leaves)
        for a, b in zip(ours_grad, ref_grad):
            torch.testing.assert_close(a, b, rtol=0, atol=2e-8)
        print(json.dumps({"smc_mdp_differential": {
            "reward_max_abs": float((ours_reward-ref_reward).abs().max().detach()),
            "critic_max_abs": float((ours_critic-ref_critic).abs().max().detach()),
            "reward_gradient_max_abs": max(float((a-b).abs().max()) for a, b in zip(ours_grad, ref_grad))}}))

    def test_observation_modes_have_exact_upstream_prefix(self):
        motion, state, action, previous, xi, frames, _ = self.fixture()
        ref = self.upstream["mdp"].MDP(self.kin, motion, self.default).obs(state, previous, xi, frames)
        default = actual_mdp.MDP(self.kin, motion, self.default)
        self.assertEqual(actual_mdp.OBS_DIM, 93)
        self.assertEqual(default.obs_dim, 93)
        for mode, count in actual_mdp.OBSERVATION_DIMS.items():
            ours = actual_mdp.MDP(self.kin, motion, self.default, observation_mode=mode)
            obs = ours.obs(state, previous, xi, frames)
            self.assertEqual(obs.shape[-1], count)
            torch.testing.assert_close(obs[..., :min(count, 99)], ref[..., :min(count, 99)], rtol=0, atol=0)

    def test_fk_matches_actual_upstream_for_all_tracked_bodies(self):
        _, state, _, _, _, _, _ = self.fixture()
        state = tuple(x.detach().float() for x in state)
        ours = G1Kinematics("cpu")
        reference = self.upstream["kinematics"].G1Kinematics("cpu")
        for actual, expected in zip(ours.forward(*state), reference.forward(*state)):
            torch.testing.assert_close(actual, expected, rtol=0, atol=0)

    def test_matrix_quaternion_values_and_pullback_match_upstream(self):
        ref = self.upstream["rotations"]
        vectors = torch.tensor([[0., 0., 0.], [.4, -.3, .8], [3.13, 0., 0.],
                                [0., -3.13, 0.], [0., 0., 3.13]], dtype=torch.float64, requires_grad=True)
        R = actual_rot.so3_exp(vectors)
        ours, expected = actual_rot.mat_to_quat(R), ref.mat_to_quat(R)
        torch.testing.assert_close(ours, expected, rtol=0, atol=0)
        weights = ours.new_tensor([.13, -.27, .8, -.51])
        ga = torch.autograd.grad((ours*weights).sum(), vectors, retain_graph=True)[0]
        gb = torch.autograd.grad((expected*weights).sum(), vectors)[0]
        torch.testing.assert_close(ga, gb, rtol=0, atol=0)
        self.assertTrue(bool(torch.isfinite(ga).all()))

    def test_documented_rotation_fixes_remove_upstream_floor_and_vertical_collapse(self):
        ref = self.upstream["rotations"]
        theta = torch.tensor(1e-5, dtype=torch.float64, requires_grad=True)
        vector = torch.stack((theta, theta*0, theta*0))
        R = actual_rot.so3_exp(vector)
        identity = torch.eye(3, dtype=R.dtype)
        ours, upstream = actual_rot.rot_angle_sq(R, identity), ref.rot_angle_sq(R, identity)
        grad = torch.autograd.grad(ours, theta, retain_graph=True)[0]
        reference_grad = torch.autograd.grad(upstream, theta)[0]
        torch.testing.assert_close(ours.detach(), ours.new_tensor(1e-10), rtol=1e-6, atol=0)
        torch.testing.assert_close(grad, grad.new_tensor(2e-5), rtol=1e-6, atol=0)
        self.assertEqual(float(reference_grad), 0.)
        self.assertGreater(float(upstream.detach()), 1e-6)
        vertical = torch.tensor([[0., 0., 1.], [0., 1., 0.], [-1., 0., 0.]], dtype=torch.float64)
        torch.testing.assert_close(actual_rot.yaw_mat(vertical), identity, rtol=0, atol=0)
        self.assertEqual(float(torch.linalg.det(ref.yaw_mat(vertical))), 0.)


if __name__ == "__main__":
    unittest.main()
