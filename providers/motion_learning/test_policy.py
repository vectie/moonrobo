"""Numerical return checks independent of the learned controller's quality."""

import unittest
import torch

from policy import Critic, gae_targets, imagined_rollout, physical_return_targets


class ReturnTests(unittest.TestCase):
    def test_physics_targets_keep_truncation_tail_and_stop_at_true_terminal(self):
        rewards, continuation = torch.tensor([1., 2.]), torch.tensor([.5, .25])
        truncated = physical_return_targets(rewards, continuation, torch.tensor([False, False]), 8., .9)
        terminal = physical_return_targets(rewards, continuation, torch.tensor([False, True]), 8., .9)
        torch.testing.assert_close(truncated, torch.tensor([1 + .9 * .5 * (2 + .9 * .25 * 8), 2 + .9 * .25 * 8]))
        torch.testing.assert_close(terminal, torch.tensor([1 + .9 * .5 * 2, 2.]))

    def test_critic_translation_encoding_survives_saved_network_inputs(self):
        config = {"gamma": .99, "critic_horizontal_translation_invariant": True}
        critic = Critic(torch.zeros(14), torch.ones(14), 2, config, 1).double()
        state = torch.randn(3, 14, dtype=torch.float64, requires_grad=True)
        goals, context = torch.zeros(3, 1, dtype=torch.float64), torch.ones(3, 2, dtype=torch.float64)
        offset = torch.zeros_like(state)
        offset[:, :2] = torch.tensor([1.0, -2.0])
        torch.testing.assert_close(critic(state + offset, goals, context), critic(state, goals, context), atol=0, rtol=0)
        grad, = torch.autograd.grad(critic(state, goals, context).sum(), state)
        torch.testing.assert_close(grad[:, :2], torch.zeros_like(grad[:, :2]), atol=0, rtol=0)
        # A v1 reader using all normalized inputs still reads the saved zero-XY network correctly.
        legacy = Critic(torch.zeros(14), torch.ones(14), 2, {"gamma": .99}, 1).double()
        legacy.load_state_dict(critic.state_dict())
        torch.testing.assert_close(legacy(state + offset, goals, context), critic(state, goals, context), atol=0, rtol=0)

    def test_terminal_does_not_bootstrap(self):
        critic = lambda state, goal, context: torch.full(state.shape[:-1], 5.0)
        result = gae_targets(critic, torch.zeros(1, 3, 1), torch.tensor([[1.0, 2.0]]),
                             torch.tensor([[1.0, 0.0]]), torch.zeros(1, 1), torch.zeros(1, 1),
                             {"gamma": 0.9, "gae_lambda": 1.0})
        torch.testing.assert_close(result, torch.tensor([[2.8, 2.0]]))

    def test_time_limit_retains_terminal_value(self):
        critic = lambda state, goal, context: torch.full(state.shape[:-1], 5.0)
        result = gae_targets(critic, torch.zeros(1, 3, 1), torch.tensor([[1.0, 2.0]]),
                             torch.tensor([[1.0, 1.0]]), torch.zeros(1, 1), torch.zeros(1, 1),
                             {"gamma": 0.9, "gae_lambda": 1.0})
        # 1 + .9 * 2 + .9**2 * 5 and 2 + .9 * 5.
        torch.testing.assert_close(result, torch.tensor([[6.85, 6.5]]))

    def test_actor_bootstrap_ablation_preserves_reward_and_state_gradient(self):
        class Actor(torch.nn.Module):
            body = {"q_indices": [7], "v_state_indices": [8], "nq": 8}
            def __init__(self):
                super().__init__()
                self.action = torch.nn.Parameter(torch.tensor(.1, dtype=torch.float64))
            def forward(self, obs, goal):
                return self.action.expand(len(obs), 1)
        actor = Actor()
        initial = torch.zeros(1, 14, dtype=torch.float64)
        initial[:, 2], initial[:, 3] = .8, 1
        dynamics = lambda state, action, context: state + torch.nn.functional.pad(action, (7, 6))
        critic = lambda state, goal, context: 2 * state[..., 7]
        config = {"horizon": 3, "gamma": .9, "target_height_m": .8}
        inputs = (dynamics, actor, critic, initial, torch.zeros(1, 1, dtype=torch.float64),
                  torch.zeros(1, 1, dtype=torch.float64), torch.zeros(1, 2, dtype=torch.float64))
        on = imagined_rollout(*inputs, config)
        off = imagined_rollout(*inputs, {**config, "actor_critic_bootstrap": False})
        torch.testing.assert_close(on[1], off[1])
        torch.testing.assert_close(on[2], off[2])
        boundary = .9**3 * on[3].prod(1) * 2 * on[1][:, -1, 7]
        torch.testing.assert_close(on[0] - off[0], boundary.mean())
        on_grad, = torch.autograd.grad(on[0], actor.action, retain_graph=True)
        off_grad, = torch.autograd.grad(off[0], actor.action)
        expected = .9**3 * on[3].detach().prod(1).mean() * 2 * 3
        torch.testing.assert_close(on_grad - off_grad, expected)


if __name__ == "__main__":
    unittest.main()
