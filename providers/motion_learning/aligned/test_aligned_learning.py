"""Numerical contracts for the method-aligned learner (small explicit networks)."""

from __future__ import annotations

import copy
from types import SimpleNamespace
import unittest

import numpy as np
import torch

from .buffer import ReplayBuffer
from .learning import AlignedLearner, frozen_parameters, lambda_returns
from .mdp import CRITIC_EXTRA, INV_DIM, flatten_state, invariant_features, unflatten_state
from .networks import Critic, WorldModel
from .export import mujoco_state
from .robot import G1_JOINT_NAMES


def transition(frame, step=None, *, done=False, terminated=False):
    s = torch.zeros(1, 71)
    s[:, 2], s[:, 3] = 0.8, 1
    s[:, 13:42] = frame * 0.001
    s1 = s.clone()
    s1[:, 13:42] += 0.001
    xi = torch.zeros(1, 33)
    xi[:, 0] = 0.75
    return dict(s=s, s1=s1, a=torch.full((1, 29), 0.02), a_prev=torch.zeros(1, 29),
                xi=xi, r=torch.tensor([0.1]), f=torch.tensor([frame]),
                ep_step=torch.tensor([frame if step is None else step]),
                done=torch.tensor([done]), terminated=torch.tensor([terminated]),
                truncated=torch.tensor([done and not terminated]))


class FixtureMotion:
    clip_end = torch.tensor([99])
    clip_id = torch.zeros(100, dtype=torch.long)

    def goal(self, f, K):
        return torch.full((len(f), 73 * K), 0.01)


class FixtureMDP:
    """Cheap differentiable MDP for isolating learner contracts; no physics claim."""
    motion = FixtureMotion()
    obs_dim = 93

    def obs(self, S, prev, xi, f):
        p, R, v, w, q, qd = S
        return torch.cat((q, qd, w, -R[..., 2, :], prev), -1)

    def add_noise(self, o):
        return o

    def reward(self, S, f, a, prev):
        return 0.1 * torch.exp(-S[4].square().mean(-1)) - 0.002 * (a - prev).square().sum(-1)

    def soft_termination(self, S, f):
        return torch.sigmoid((0.5 - S[0][..., 2]) / 0.02)

    def critic_features(self, S, f, xi):
        inv = invariant_features(S)
        return torch.cat((inv, torch.zeros(*inv.shape[:-1], CRITIC_EXTRA, device=inv.device)), -1)


class AlignedLearningTests(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(7)
        torch.set_num_threads(1)

    def test_gae_failure_and_timeout_do_not_mix(self):
        r = torch.tensor([[1.], [2.], [100.]])
        v = torch.tensor([[4.], [5.], [6.], [7.]])
        failed = torch.tensor([[0.], [1.], [0.]])
        y = lambda_returns(r, v, failed, gamma=0.9, lam=1.)
        self.assertAlmostEqual(float(y[1]), 2.)
        self.assertAlmostEqual(float(y[0]), 2.8, places=6)
        timeout = torch.tensor([[False], [True], [False]])
        y = lambda_returns(r, v, torch.zeros_like(r), timeout, gamma=0.9, lam=1.)
        self.assertAlmostEqual(float(y[1]), 7.4, places=5)
        self.assertAlmostEqual(float(y[0]), 7.66, places=5)
        soft = lambda_returns(r[:1], v[:2], torch.tensor([[0.25]]), gamma=0.9, lam=0.95)
        self.assertAlmostEqual(float(soft[0]), 1 + 0.9 * 0.75 * 5, places=6)

    def test_replay_short_windows_and_episode_boundary(self):
        b = ReplayBuffer(8, 1)
        self.assertFalse(b.can_sample_windows(8))
        with self.assertRaisesRegex(ValueError, "warm-up"):
            b.sample_windows(2, 8)
        for i in range(8):
            b.add(transition(i if i < 3 else i + 40, i if i < 3 else i - 3, done=i == 2))
        w = b.sample_windows(1, 8)
        torch.testing.assert_close(w["mask"], torch.tensor([[1., 1., 1., 0., 0., 0., 0., 0.]]))
        self.assertTrue(w["truncated"][0, 2])
        self.assertFalse(w["terminated"][0, 2])
        start, history = b.sample_starts(100, 10)
        for frame, frames in zip(start["f"], history["f"]):
            self.assertEqual(int(frames[-1]), int(frame))
            self.assertTrue(bool((frames < 3).all()) if frame < 3 else bool((frames >= 43).all()))
        motion = FixtureMotion()
        motion.clip_end = torch.tensor([30])
        with self.assertRaisesRegex(ValueError, "complete imagination"):
            b.sample_starts(1, 10, motion=motion, horizon=32)

    def test_replay_ring_resume_restores_windows(self):
        b = ReplayBuffer(8, 1)
        for i in range(12):
            b.add(transition(i))
        restored = ReplayBuffer(8, 1)
        restored.load_state_dict(b.state_dict())
        self.assertTrue(restored.can_sample_windows(8))
        torch.testing.assert_close(restored.sample_windows(1, 8)["f"],
                                   torch.arange(4, 12).reshape(1, 8))
        empty = ReplayBuffer(8, 1)
        restored.load_state_dict(empty.state_dict())
        self.assertFalse(restored.can_sample_windows(8))

    def test_frozen_critic_retains_state_gradient(self):
        critic = Critic(4, hidden=(8,))
        x = torch.ones(2, 4, requires_grad=True)
        before = copy.deepcopy(critic.state_dict())
        with frozen_parameters(critic):
            critic(x).sum().backward()
        self.assertGreater(float(x.grad.abs().sum()), 0.)
        self.assertTrue(all(p.grad is None for p in critic.parameters()))
        for k, v in critic.state_dict().items():
            torch.testing.assert_close(v, before[k], rtol=0, atol=0)

    def test_full_8_step_fit_32_step_actor_and_imagined_critic(self):
        learner = AlignedLearner(FixtureMDP(), dict(wm_hidden=(16, 16, 16),
            pi_hidden=(16, 12), critic_hidden=(16, 8), wm_batch=2, wm_batches=1,
            pi_batch=2, critic_epochs=1, critic_minibatches=3, observation_noise=False))
        buffer = ReplayBuffer(16, 1)
        for i in range(16):
            tr = transition(i)
            buffer.add(tr)
            learner.observe(tr)
        wm_result = learner.fit_world_model(buffer)
        self.assertTrue(torch.isfinite(torch.tensor(wm_result["wm_loss"])))
        self.assertEqual(wm_result["wm_updates"], 1)
        wm_before, v_before = copy.deepcopy(learner.wm.state_dict()), copy.deepcopy(learner.critic.state_dict())
        pi_before = copy.deepcopy(learner.pi.state_dict())
        actor_result = learner.update_policy(buffer, train_critic=False)
        self.assertEqual(actor_result["imagined_steps"], 64)
        self.assertTrue(actor_result["critic_tail"])
        for key, tensor in learner.wm.state_dict().items():
            torch.testing.assert_close(tensor, wm_before[key], rtol=0, atol=0)
        for key, tensor in learner.critic.state_dict().items():
            torch.testing.assert_close(tensor, v_before[key], rtol=0, atol=0)
        self.assertTrue(all(p.grad is None for p in learner.wm.parameters()))
        self.assertTrue(all(p.grad is None for p in learner.critic.parameters()))
        self.assertTrue(any(not torch.equal(tensor, pi_before[key]) for key, tensor in learner.pi.state_dict().items()))
        full_result = learner.update_policy(buffer)
        self.assertEqual(full_result["critic_updates"], 3)
        self.assertTrue(all(torch.isfinite(torch.tensor(v)) for v in full_result.values()))
        saved = copy.deepcopy(learner.state_dict())
        replica = AlignedLearner(FixtureMDP(), saved["config"])
        replica.load_state_dict(saved)
        for key, tensor in learner.pi.state_dict().items():
            torch.testing.assert_close(tensor, replica.pi.state_dict()[key], rtol=0, atol=0)
        self.assertEqual(len(replica.opt_pi.state), len(learner.opt_pi.state))

    def test_world_model_identity_has_finite_gradients(self):
        wm = WorldModel(hidden=(8, 8, 8))
        state = transition(0)["s"].requires_grad_()
        S = unflatten_state(state)
        action = torch.zeros(1, 29, requires_grad=True)
        prediction = wm.step(S, action, torch.zeros(1, 33))
        loss = wm.state_error(prediction, S).square().sum() + sum(x.square().sum() for x in prediction)
        loss.backward()
        self.assertTrue(torch.isfinite(state.grad).all())
        self.assertTrue(torch.isfinite(action.grad).all())
        self.assertTrue(all(p.grad is None or torch.isfinite(p.grad).all() for p in wm.parameters()))

    def test_native_export_reorders_joints_and_rotates_world_angular_velocity(self):
        model = SimpleNamespace(nq=36, nv=35, na=0,
            jnt_qposadr=np.arange(35, 6, -1), jnt_dofadr=np.arange(34, 5, -1),
            joint=lambda name: SimpleNamespace(id=G1_JOINT_NAMES.index(name)))
        state = torch.zeros(1, 71)
        state[:, :3] = torch.tensor([1., 2., 3.])
        state[:, 3], state[:, 6] = 2 ** -0.5, 2 ** -0.5
        state[:, 7:10] = torch.tensor([4., 5., 6.])
        state[:, 10:13] = torch.tensor([0., 1., 0.])
        state[:, 13:42], state[:, 42:71] = torch.arange(29), torch.arange(29) + 100
        converted = mujoco_state(state, model)
        torch.testing.assert_close(converted[:, :7], state[:, :7])
        torch.testing.assert_close(converted[:, 7:36], torch.arange(28, -1, -1).float()[None])
        torch.testing.assert_close(converted[:, 36:39], state[:, 7:10])
        torch.testing.assert_close(converted[:, 39:42], torch.tensor([[1., 0., 0.]]), atol=2e-7, rtol=0)
        torch.testing.assert_close(converted[:, 42:], (torch.arange(28, -1, -1).float() + 100)[None])


if __name__ == "__main__":
    unittest.main()
