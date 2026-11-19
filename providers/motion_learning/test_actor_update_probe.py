"""Parameter probes preserve buffers and follow the optimizer's ascent sign."""
import unittest

import torch

from actor_update_probe import adam_direction, scaled_actor
from policy import imagined_rollout
from paired_model_probe import predicted_changes


class DirectionTest(unittest.TestCase):
    def test_adam_ascent_zero_and_reversed_parameter_steps(self):
        class Actor(torch.nn.Module):
            body = {"q_indices": [7], "v_state_indices": [8], "nq": 8}
            def __init__(self):
                super().__init__()
                self.action = torch.nn.Parameter(torch.tensor(.01))
                self.register_buffer("normalization", torch.tensor(2.))
            def forward(self, obs, goal):
                return self.action.expand(len(obs), 1)
        actor = Actor()
        state = torch.zeros(1, 14)
        state[:, 2], state[:, 3] = .8, 1
        dynamics = lambda state, action, context: state + torch.nn.functional.pad(action, (7, 6))
        critic = lambda state, goal, context: 20 * state[..., 7]
        batch = (state, torch.zeros(1, 1), torch.zeros(1, 1), torch.ones(1, 2))
        config = {"horizon": 4, "gamma": .9, "target_height_m": .8, "actor_learning_rate": .001}
        delta, before, norm = adam_direction(dynamics, actor, critic, batch, config)
        self.assertGreater(norm, 0)
        self.assertGreater(float(delta["action"]), 0)
        for multiplier in [-1, 0, 1]:
            candidate = scaled_actor(actor, delta, multiplier)
            value = float(imagined_rollout(dynamics, candidate, critic, *batch, config)[0].detach())
            if multiplier:
                self.assertGreater((value - before) * multiplier, 0)
            else:
                self.assertEqual(value, before)
            self.assertEqual(float(candidate.normalization), 2)
        self.assertAlmostEqual(float(actor.action.detach()), .01)
        no_tail, _, _ = adam_direction(dynamics, actor, critic, batch,
                                      {**config, "actor_critic_bootstrap": False})
        self.assertLess(float(no_tail["action"]), 0)
        predicted = predicted_changes(dynamics, actor, scaled_actor(actor, delta, 1),
                                      critic, batch, config)
        self.assertGreater(predicted["bootstrapped"], 0)
        self.assertLess(predicted["reward"], 0)
        self.assertNotIn("actor_critic_bootstrap", config)


if __name__ == "__main__":
    unittest.main()
