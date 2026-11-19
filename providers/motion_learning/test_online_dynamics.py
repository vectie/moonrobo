"""Online fitting keeps physical episode boundaries and frozen input units."""
import copy
from types import SimpleNamespace
import unittest

import torch

from dynamics import ResidualDynamics, imagine
from online_dynamics import OnlineDynamics


def episode(start=0, times=(0, .02, .04, .06), split="train"):
    steps = []
    for i, time in enumerate(times):
        state = [0.0] * 14
        state[2], state[3], state[7] = .8, 1, start + i
        target = state.copy()
        target[7] += .1
        steps.append(dict(time_s=time, state=state, applied_action=[.1], next_state=target,
                          terminated=i == len(times) - 1, truncated=False))
    return dict(split=split, context=[1, 1], steps=steps)


class OnlineDynamicsTest(unittest.TestCase):
    def setup_updater(self, cap=20):
        stats = {name + suffix: value for name, n in [("state", 14), ("action", 1), ("context", 2)]
                 for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        model = ResidualDynamics(stats, 8, True)
        state = torch.zeros(4, 2, 14)
        state[:, :, 2], state[:, :, 3] = .8, 1
        original = SimpleNamespace(horizon=2, layout={"dt_s": .02}, state=state,
                                   target=state + torch.nn.functional.one_hot(torch.tensor(7), 14) * .1,
                                   action=torch.ones(4, 2, 1) * .1, context=torch.ones(4, 2))
        config = dict(online_sampling_seed=1900, online_model_learning_rate=.003,
                      batch_size=4, online_model_updates=3, online_replay_windows=cap)
        return OnlineDynamics(model, original, config, 0)

    def test_no_cross_episode_gap_or_terminal_windows(self):
        updater = self.setup_updater()
        early_done = episode(200)
        early_done["steps"][1]["truncated"] = True
        updater.append([episode(0), episode(100, times=(0, .02, .10, .12)), early_done])
        # Terminal-at-end is valid; gaps and a terminal before window end are not.
        self.assertEqual(updater.recent["state"][:, 0, 7].tolist(), [0, 1, 2, 100, 102, 200, 202])
        self.assertTrue(torch.all(updater.recent["state"][:, 1, 7] - updater.recent["state"][:, 0, 7] == 1))
        heldout = self.setup_updater()
        with self.assertRaises(ValueError):
            heldout.append([episode(split="validation")])
        self.assertIsNone(heldout.recent)

    def test_fits_weights_without_changing_normalization_or_actor_rng(self):
        updater = self.setup_updater(cap=4)
        before = copy.deepcopy(updater.model.state_dict())
        rng = torch.get_rng_state().clone()
        result = updater.update([episode()])
        updater.update([episode(10)])
        self.assertTrue(torch.equal(rng, torch.get_rng_state()))
        self.assertEqual(len(updater.recent["state"]), 4)
        self.assertEqual(result["optimizer_steps"], 3)
        self.assertEqual(updater.optimizer_steps, 6)
        self.assertTrue(any(not torch.equal(before[k], v) for k, v in updater.model.state_dict().items()))
        for name, value in updater.model.named_buffers():
            self.assertTrue(torch.equal(before[name], value))
        self.assertTrue(all(not p.requires_grad and p.grad is None for p in updater.model.parameters()))
        actions = updater.original.action[:1].clone().requires_grad_(True)
        prediction = imagine(updater.model, updater.original.state[:1, 0], actions, updater.original.context[:1])
        grad, = torch.autograd.grad(prediction[:, -1, 7].sum(), actions)
        self.assertTrue(torch.isfinite(grad).all())
        self.assertGreater(float(grad.norm()), 0)


if __name__ == "__main__":
    unittest.main()
