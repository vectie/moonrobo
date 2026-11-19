"""Finite task time, causal value inputs, tail gradients and paired reload."""
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import torch

from policy import Actor, observation
from temporal_actor import TemporalActor, save_temporal, temporal_imagination
from temporal_value import episode_value_points, finite_imagination, load_value, make_value


class TemporalValueTest(unittest.TestCase):
    def setup_value(self):
        stats = dict(obs_mean=torch.zeros(9), obs_scale=torch.ones(9), goal_mean=torch.zeros(1),
            goal_scale=torch.ones(1), lower=torch.tensor([-1.]), upper=torch.tensor([1.]))
        base = Actor(stats, dict(hidden_width=8, action_delta_rad=.3), dict(q_indices=[7], v_state_indices=[8], nq=8))
        actor = TemporalActor(base, 3, 2, 8)
        model = SimpleNamespace(state_mean=torch.zeros(14), state_scale=torch.ones(14),
            context_mean=torch.zeros(2), context_scale=torch.ones(2))
        value = make_value(model, actor, dict(critic_width=8, gamma=.9, duration_s=10))
        return actor, value

    def test_zero_task_tail_translation_and_paired_checkpoint(self):
        torch.manual_seed(3)
        actor, value = self.setup_value()
        with torch.no_grad():
            value.net[-1].weight.uniform_(-.1, .1)
        state, history, goals = torch.randn(2, 14), torch.randn(2, 10, 9), torch.randn(2, 11, 1)
        state[:, 2] = .8; state[:, 3:7] = torch.tensor([1., 0., 0., 0.])
        inputs = state, history, goals, torch.ones(2, 2), torch.tensor([1., 2.])
        result = value(*inputs)
        moved = state.clone(); moved[:, :2] += 10000
        self.assertTrue(torch.equal(value(moved, *inputs[1:]), result))
        self.assertTrue(torch.equal(value(*inputs[:-1], torch.zeros(2)), torch.zeros(2)))
        fallen = state.clone(); fallen[:, 2] = .3
        self.assertTrue(torch.equal(value(fallen, *inputs[1:]), torch.zeros(2)))
        self.assertFalse(torch.equal(value(state, history + 1, *inputs[2:]), result))
        self.assertFalse(torch.equal(value(state, history, goals + 1, *inputs[3:]), result))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "actor.pt"
            save_temporal(actor, dict(config=actor.base.config, model_ref="toy"), {}, path, 0, {}, critic=value)
            restored = load_value(path)
            self.assertTrue(torch.equal(restored(*inputs), result))

    def test_tail_uses_predicted_history_future_and_original_remaining_time(self):
        actor, value = self.setup_value()
        state = torch.zeros(2, 14); state[:, 2], state[:, 3], state[:, 7] = .8, 1, -.1
        history = observation(state, torch.zeros(2, 1), actor.body)[:, None].expand(-1, 10, -1)
        goals = torch.arange(14, dtype=torch.float32)[None, :, None].expand(2, -1, -1) * .01
        context, remaining = torch.ones(2, 2), torch.ones(2)
        config = dict(horizon=3, gamma=.9, target_height_m=.8, actor_critic_bootstrap=False)
        dynamics = lambda state, action, context: state + torch.nn.functional.pad(action * .1, (7, 6))
        old = temporal_imagination(dynamics, actor, None, state, history[:, -3:], goals, context, config)[0]
        finite = finite_imagination(dynamics, actor, value, state, history, goals, context, remaining, config)
        torch.testing.assert_close(finite, old, atol=0, rtol=0)
        captured = []
        def tail(s, h, g, c, time):
            captured.append((s, h, g, time))
            return 100 * s[:, 7] + h[:, -1, -1]
        on = {**config, "actor_critic_bootstrap": True}
        result = finite_imagination(dynamics, actor, tail, state, history, goals, context, remaining, on)
        s, h, g, time = captured[0]
        torch.testing.assert_close(time, remaining - .06)
        torch.testing.assert_close(g, goals[:, 3:14])
        self.assertEqual(h.shape, (2, 10, 9))
        self.assertFalse(torch.equal(s, state))
        result.backward()
        self.assertGreater(sum(float(p.grad.norm()) for p in actor.parameters() if p.grad is not None), 0)
        self.assertTrue(all(p.grad is None for p in value.parameters()))

    def test_physical_time_limit_target_ends_at_original_task_cap(self):
        actor, _ = self.setup_value()
        state = torch.zeros(1, 14); state[:, 2], state[:, 3] = .8, 1
        obs = observation(state, torch.zeros(1, 1), actor.body)[0].tolist()
        episode = dict(split="train", reference_nominal_rad=[0.], context=[1, 1], steps=[
            dict(time_s=i * .02, state=state[0].tolist(), next_state=state[0].tolist(), observation=obs,
                goal=[0.], applied_action=[0.], terminated=False, truncated=i == 1) for i in range(2)])
        runtime = SimpleNamespace(dt=.02, model=SimpleNamespace(nu=1),
            reference=lambda nominal, motion, t, offset, schedule: nominal)
        config = dict(duration_s=.04, gamma=.9, target_height_m=.8)
        points, targets = episode_value_points(runtime, episode, dict(motion="stand"), actor, config)
        torch.testing.assert_close(points[-1], torch.tensor([.04, .02]))
        self.assertEqual(float(targets[-1]), 3.)
        continuation = float(torch.sigmoid(torch.tensor((.8 - .35) / .02)) * torch.sigmoid(torch.tensor(10.)))
        self.assertAlmostEqual(float(targets[0]), 3 + .9 * continuation * 3, places=5)


if __name__ == "__main__":
    unittest.main()
