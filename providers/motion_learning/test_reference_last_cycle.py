"""Check diagnostic window boundaries, weighting and terminal return accounting."""
import unittest

import torch

from reference_last_cycle import discounted_returns, prediction_metrics, window_starts


class ReferenceLastCycleTest(unittest.TestCase):
    def test_windows_include_last_prefall_window_without_short_or_duplicate_windows(self):
        self.assertEqual(window_starts(7, 8), [])
        self.assertEqual(window_starts(8, 8), [0])
        self.assertEqual(window_starts(11, 8), [0, 3])
        self.assertEqual(window_starts(16, 8), [0, 4, 8])

    def test_return_prefix_stops_at_terminal_and_full_return_keeps_its_last_reward(self):
        actual = discounted_returns([1., 2., 4.], .5, 2)
        self.assertEqual(actual["prefix_return"], 2.)
        self.assertEqual(actual["full_return"], 3.)
        short = discounted_returns([1., -2.], .5, 32)
        self.assertEqual(short["prefix_return"], 0.)
        self.assertEqual(short["prefix_observed_steps"], 2)

    def test_open_loop_errors_weight_last_batch_and_have_declared_joint_units(self):
        class JointDrift:
            state_scale = torch.ones(71)

            def __call__(self, state, action, context):
                result = state.clone()
                result[:, 7] += 1
                return result

        state = torch.zeros(260, 71)
        state[:, 3] = 1
        batch = dict(state=state, next_state=state.clone(), action=torch.zeros(260, 29), context=torch.ones(260, 2))
        result = prediction_metrics(JointDrift(), batch, [2])[0]
        self.assertEqual(result["windows"], 259)
        self.assertEqual(result["last_window_offset"], 258)
        self.assertAlmostEqual(result["normalized_state_mse"], 2.5/71, places=7)
        self.assertAlmostEqual(result["joint_rmse_rad"], (2.5/29)**.5, places=7)
        self.assertEqual(result["persistence_mse"], 0.)
        self.assertEqual(result["root_orientation_rmse_rad"], 0.)
        self.assertEqual(prediction_metrics(JointDrift(), {k: v[:1] for k, v in batch.items()}, [2])[0]["normalized_state_mse"], None)


if __name__ == "__main__":
    unittest.main()
