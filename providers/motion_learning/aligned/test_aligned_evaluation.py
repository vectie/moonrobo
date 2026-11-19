"""Regression tests for full-reference normalization and failure accounting."""

import unittest
from types import SimpleNamespace

import torch

try:
    from .evaluation import ClipEvaluation, evaluate_policy, summarize_evaluations
except ImportError:
    from evaluation import ClipEvaluation, evaluate_policy, summarize_evaluations


class FullClipMetricsTest(unittest.TestCase):
    def test_early_failure_keeps_unplayed_reference_in_denominator(self):
        report = summarize_evaluations([
            ClipEvaluation("long", 10, [0.1, 0.1], True),
            ClipEvaluation("short", 2, [0.1, 0.1], False),
        ])
        self.assertAlmostEqual(report["norm_return"], 0.6)
        self.assertAlmostEqual(report["norm_return_framew"], 1 / 3)
        self.assertEqual(report["failed"], ["long"])
        self.assertTrue(report["benchmark_complete"])
        self.assertEqual(report["evaluation_physical_steps"], 4)

    def test_negative_return_and_final_frame_termination_are_preserved(self):
        report = summarize_evaluations([ClipEvaluation("negative", 1, [-0.2], True)])
        self.assertEqual(report["norm_return"], -2)
        self.assertEqual(report["n_failed"], 1)
        self.assertEqual(report["n_completed"], 1)

    def test_timeout_and_missing_clip_cannot_be_claimed_complete(self):
        report = summarize_evaluations(
            [ClipEvaluation("timeout", 100, [0.1] * 10, False)],
            expected_clip_ids=["timeout", "missing"],
        )
        self.assertFalse(report["benchmark_complete"])
        self.assertEqual(report["n_failed"], 0)
        self.assertEqual(report["incomplete_protocol_clips"], ["timeout"])
        self.assertEqual(report["missing_clips"], ["missing"])

    def test_strict_tracking_is_distinct_from_paper_failure(self):
        report = summarize_evaluations([ClipEvaluation(
            "completed", 1, [0.08], False,
            {"joint_rmse_rad": 0.04, "body_position_rmse_m": 0.01,
             "root_position_rmse_m": 0.01, "root_orientation_rmse_rad": 0.01},
        )])
        self.assertEqual(report["n_failed"], 0)
        self.assertFalse(report["strict_tracking"]["all_passed"])

    def test_duplicate_and_nonfinite_results_rejected(self):
        trial = ClipEvaluation("same", 1, [0.1], False)
        with self.assertRaises(ValueError):
            summarize_evaluations([trial, trial])
        with self.assertRaises(ValueError):
            summarize_evaluations([ClipEvaluation("bad", 1, [float("nan")], False)])


class RecordingPolicy(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.histories = []

    def forward(self, history, goal):
        self.histories.append(history.clone())
        return torch.zeros(1, 1)


class TinyEvaluationEnv:
    """A terminal-first clip then full clip verifies reset and history isolation."""
    eval_mode, auto_reset = True, False

    def __init__(self):
        self.f = torch.zeros(1, dtype=torch.long)
        self.a_prev, self.xi = torch.zeros(1, 1), torch.zeros(1, 1)
        motion = SimpleNamespace(
            names=["fails", "finishes"], clip_start=torch.tensor([0, 5]),
            clip_len=torch.tensor([5, 3]), goal=lambda frame, count: frame[:, None],
        )
        self.mdp = SimpleNamespace(motion=motion, obs=lambda state, action, xi, frame: frame[:, None].float())
        self.resets = []

    def state(self):
        return self.f

    def reset(self, frames):
        self.f = frames.clone()
        self.resets.append(int(frames[0]))

    def step(self, action):
        previous = self.f.clone()
        self.f += 1
        terminal = self.f == 1
        return {"f": previous, "s1": self.f, "r": torch.tensor([0.1]),
                "term": terminal, "done": terminal | (self.f == 7)}


class EvaluationDriverTest(unittest.TestCase):
    def test_full_clip_driver_resets_histories_and_restores_policy_mode(self):
        env, policy = TinyEvaluationEnv(), RecordingPolicy()
        report = evaluate_policy(env, policy, hist=3, strict_tracking=False)
        self.assertEqual(env.resets, [0, 5])
        self.assertEqual(report["n_failed"], 1)
        self.assertEqual(report["evaluation_physical_steps"], 3)
        self.assertTrue(report["benchmark_complete"])
        self.assertTrue(report["full_catalog_evaluated"])
        self.assertTrue(torch.equal(policy.histories[1], torch.full((1, 3, 1), 5.0)))
        self.assertTrue(torch.equal(policy.histories[2], torch.tensor([[[5.0], [5.0], [6.0]]])))
        self.assertTrue(policy.training)

    def test_subset_evaluation_does_not_claim_full_catalog(self):
        report = evaluate_policy(TinyEvaluationEnv(), RecordingPolicy(), clip_indices=[1], strict_tracking=False)
        self.assertTrue(report["benchmark_complete"])
        self.assertFalse(report["full_catalog_evaluated"])
        self.assertEqual(report["catalog_clip_count"], 2)

    def test_unused_gpu_replicas_count_as_compute_not_extra_trials(self):
        env = TinyEvaluationEnv()
        env.evaluation_settings = {"simulated_replica_count": 4, "measured_replica_count": 1}
        report = evaluate_policy(env, RecordingPolicy(), strict_tracking=False)
        self.assertEqual(report["n_clips"], 2)
        self.assertEqual(report["evaluation_physical_steps"], 3)
        self.assertEqual(report["evaluation_simulated_physical_steps"], 12)

    def test_training_environment_rejected(self):
        env = TinyEvaluationEnv()
        env.auto_reset = True
        with self.assertRaises(ValueError):
            evaluate_policy(env, RecordingPolicy(), strict_tracking=False)


if __name__ == "__main__":
    unittest.main()
