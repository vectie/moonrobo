import copy
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import numpy as np
import torch

from cpu_physics import sample_joint_sines
from policy import Actor, imagined_rollout, load_actor, observation
from temporal_actor import TemporalActor, causal_history, load_temporal, preview_goals, save_temporal, temporal_imagination


class TemporalInputTest(unittest.TestCase):
    def base(self):
        stats = dict(obs_mean=torch.zeros(9), obs_scale=torch.ones(9), goal_mean=torch.zeros(1),
            goal_scale=torch.ones(1), lower=torch.tensor([-1.]), upper=torch.tensor([1.]))
        config = dict(hidden_width=8, action_delta_rad=.3)
        body = dict(q_indices=[7], v_state_indices=[8], nq=8)
        return Actor(stats, config, body), config, body

    def test_history_is_causal_and_restarts_after_gaps(self):
        values = torch.tensor([[1.], [2.], [3.], [4.]])
        result = causal_history(values, [0, .02, .1, .12], 3, .02)
        self.assertEqual(result.squeeze(-1).tolist(), [[1, 1, 1], [1, 1, 2], [3, 3, 3], [3, 3, 4]])
        changed = values.clone(); changed[-1] = 999
        torch.testing.assert_close(result[:-1], causal_history(changed, [0, .02, .1, .12], 3, .02)[:-1])

    def test_zero_adapter_and_checkpoint_preserve_legacy_action(self):
        torch.manual_seed(4)
        base, config, body = self.base()
        torch.nn.init.uniform_(base.net[-1].weight, -.1, .1)
        actor = TemporalActor(copy.deepcopy(base), 10, 10, 8)
        history, goal, future = torch.randn(3, 10, 9), torch.randn(3, 1), torch.randn(3, 10, 1)
        self.assertTrue(torch.equal(actor(history, goal, future), base(history[:, -1], goal)))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "actor.pt"
            save_temporal(actor, dict(config=config, model_ref="toy", body=body), {}, path, 0, {})
            restored, _ = load_temporal(path)
            self.assertTrue(torch.equal(restored(history, goal, future), actor(history, goal, future)))
            with self.assertRaisesRegex(ValueError, "declared policy runner"):
                load_actor(path)

    def test_imagined_history_matches_legacy_constant_goal_and_has_gradients(self):
        base, _, body = self.base()
        actor = TemporalActor(base, 1, 0, 8)
        state = torch.zeros(2, 14); state[:, 2], state[:, 3], state[:, 7] = .8, 1, -.1
        previous = torch.zeros(2, 1); goal = torch.ones(2, 1) * .2; context = torch.ones(2, 2)
        dynamics = lambda state, action, context: state + torch.nn.functional.pad(action, (7, 6))
        critic = lambda state, goal, context: state[..., 7]
        config = dict(horizon=4, gamma=.9, target_height_m=.8, actor_critic_bootstrap=False)
        legacy = imagined_rollout(dynamics, base, critic, state, previous, goal, context, config)
        temporal = temporal_imagination(dynamics, actor, critic, state, observation(state, previous, body)[:, None],
            goal[:, None].expand(-1, 5, -1), context, config)
        for a, b in zip(legacy, temporal):
            torch.testing.assert_close(a, b, atol=0, rtol=0)
        temporal[0].backward()
        self.assertTrue(all(torch.isfinite(p.grad).all() for p in actor.parameters() if p.grad is not None))
        self.assertGreater(sum(float(p.grad.norm()) for p in actor.parameters() if p.grad is not None), 0)
        changing = torch.tensor([[[.2], [.1], [-.1], [-.2], [.2]]]).expand(2, -1, -1)
        self.assertNotEqual(float(temporal_imagination(dynamics, actor, critic, state,
            observation(state, previous, body)[:, None], changing, context, config)[0].detach()), float(temporal[0].detach()))

    def test_goal_preview_reads_only_declared_command_times(self):
        runtime = SimpleNamespace(dt=.02, model=SimpleNamespace(nu=2),
            reference=lambda nominal, motion, t, offset, schedule: nominal + np.array([t, t * t]))
        result = preview_goals(runtime, {"motion": "known"}, np.zeros(2), None, None, 1., 10)
        np.testing.assert_allclose(result[:, 0], 1 + np.arange(1, 11) * .02)
        np.testing.assert_allclose(result[:, 1], (1 + np.arange(1, 11) * .02) ** 2)
        names = ["left_hip_pitch_joint", "waist_pitch_joint", "left_shoulder_pitch_joint"]
        case = dict(goal_offset_rad=dict(lower=.02, waist=.06, upper=.12))
        a, b = sample_joint_sines(names, case, 1), sample_joint_sines(names, case, 1)
        self.assertEqual(a, b)
        self.assertNotEqual(a, sample_joint_sines(names, case, 2))
        self.assertTrue(np.all(np.array(a["amplitude"]) <= [.02, .06, .12]))


if __name__ == "__main__":
    unittest.main()
