"""Differentiable body rewards and exact causal observer carry across model steps."""
from pathlib import Path
import unittest

import numpy as np
import torch

from balance_features import BalanceKinematics, ObservationBalanceHistory, make_spec
from cpu_physics import PhysicsRuntime
from reference_task import observer_advance, observer_memory, reference_reward


class ReferenceTaskTest(unittest.TestCase):
    def test_physics_body_alignment_batched_geometry_and_memory_gradients(self):
        scene = Path(__file__).resolve().parents[2]/"target/mujoco_menagerie/unitree_g1/scene_mjx.xml"
        runtime = PhysicsRuntime(scene)
        geometry = BalanceKinematics(make_spec(runtime.model))
        observations, states, positions = [], [], []
        case = dict(id="sines", family="sines", split="train", keyframe="home", friction=1.,
            motion="random_joint_sines", goal_offset_rad=dict(lower=.02, waist=.06, upper=.12))
        def capture(rt, i, action, goal):
            observations.append(rt.observation(action))
            states.append(rt.state()); positions.append(rt.data.xpos[1:].copy())
        runtime.rollout(case, 58, "position", .6, trace_callback=capture)
        obs = torch.tensor(observations, dtype=torch.float32)
        state = torch.tensor(states, dtype=torch.float32)
        before = ObservationBalanceHistory(geometry, runtime.dt, None)
        actual = torch.stack([before(o) for o in obs])
        memory = observer_memory(obs[:1], actual[:1])
        predicted = [actual[0]]
        for i in range(1, len(obs)):
            features, memory = observer_advance(geometry, obs[i:i+1], memory, runtime.dt)
            predicted.append(features[0])
        torch.testing.assert_close(torch.stack(predicted), actual, atol=2e-6, rtol=2e-5)
        com, feet = geometry.geometry(obs[:6, :29].reshape(2, 3, 29))
        self.assertEqual(com.shape, (2, 3, 3)); self.assertEqual(feet.shape, (2, 3, 2, 3))
        single = geometry.geometry(obs[0, :29])
        torch.testing.assert_close(single[0], com[0, 0])
        q = state.clone().requires_grad_(True)
        action = torch.zeros(len(q), 29)
        reward, fallen, error = reference_reward(geometry, q, action, action,
            torch.tensor(np.asarray(positions), dtype=torch.float32), q.detach()[:, 3:7], q.detach()[:, 7:36])
        torch.testing.assert_close(reward, torch.full_like(reward, .06), atol=2e-7, rtol=0)
        self.assertFalse(bool(fallen.any()))
        torch.testing.assert_close(error, actual[:, :3], atol=2e-7, rtol=2e-5)
        advanced_obs = obs[-1:].clone().requires_grad_(True)
        feature, _ = observer_advance(geometry, advanced_obs, memory.detach(), runtime.dt)
        (feature.square().sum()+reward.sum()).backward()
        self.assertTrue(torch.isfinite(q.grad).all())
        self.assertGreater(float(advanced_obs.grad.abs().sum()), 0)


if __name__ == "__main__":
    unittest.main()
