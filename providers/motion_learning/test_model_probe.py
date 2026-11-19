"""A sparse failure-tail probe must expose missing and correlated evidence."""
import unittest

from model_probe import summarize


class ProbeSummaryTest(unittest.TestCase):
    def test_absent_late_windows_do_not_report_zero_error_or_success(self):
        for result in summarize([], 32, "after-two-seconds", {"epsilons_rad": [.001, .01]}):
            self.assertEqual(result["snapshots"], 0)
            self.assertIsNone(result["mean_normalized_mse"])
            self.assertIsNone(result["sign_agreement"])
            self.assertEqual(result["ascent_improves_fraction_by_epsilon"], [None, None])

    def test_zero_gradient_excluded_from_ascent_denominator(self):
        records = []
        for t, ascent in [(1.0, []), (2.0, [{"plus_return_change": -.02}, {"plus_return_change": .01}])]:
            records.append(dict(horizon=32, start_time_s=t, physical_return=1,
              models=[dict(model=label, normalized_mse=.5, predicted_return=2, ascent_physics=ascent)
                      for label in ["initial", "corrected"]],
              directions=[dict(initial_derivative=1, corrected_derivative=-1, physics_derivatives=[1, -1])]))
        result = summarize(records, 32, "all", {"epsilons_rad": [.001, .01]})[0]
        self.assertEqual(result["snapshots"], 2)
        self.assertEqual(result["ascent_snapshots"], 1)
        self.assertEqual(result["ascent_improves_fraction_by_epsilon"], [0, 1])
        self.assertEqual(result["fd_sign_agreement_between_scales"], 0)
        self.assertEqual(summarize(records, 32, "after-two-seconds", {"epsilons_rad": [.001, .01]})[0]["snapshots"], 1)


if __name__ == "__main__":
    unittest.main()
