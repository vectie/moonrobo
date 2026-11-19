"""Time-stratified model selection must not hide absent tail evidence."""
import unittest
import io
from types import SimpleNamespace

import torch

from dynamics import ResidualDynamics, imagine, load_model, sampling_pools, validation_score
from compare_dynamics import common_metrics


class LateWindowsTest(unittest.TestCase):
    def test_common_prediction_scale_and_late_subset_are_explicit(self):
        batch = SimpleNamespace(state=torch.zeros(2, 2, 1), action=torch.zeros(2, 2, 1),
            context=torch.ones(2, 1), target=torch.tensor([[[1.], [1.]], [[2.], [2.]]]),
            start_time_s=torch.tensor([0., 2.]))
        model = lambda state, action, context: state
        result = common_metrics(model, batch, torch.tensor([2.]))
        self.assertEqual(result["normalized_state_mse"], .625)
        self.assertEqual(result["persistence_mse"], .625)
        self.assertEqual(result["after_two_seconds"], dict(windows=1, normalized_state_mse=1.))
        self.assertEqual(common_metrics(model, batch, torch.tensor([4.]))["normalized_state_mse"], .15625)

    def test_time_boundary_and_missing_pool(self):
        batch = SimpleNamespace(start_time_s=torch.tensor([0.0, 1.98, 2.0, 4.0]))
        early, late, count = sampling_pools(batch, {"batch_size": 64, "late_window_fraction": 0.5})
        self.assertEqual(early.tolist(), [0, 1])
        self.assertEqual(late.tolist(), [2, 3])
        self.assertEqual(count, 32)
        with self.assertRaises(ValueError):
            sampling_pools(SimpleNamespace(start_time_s=torch.tensor([0.0])),
                           {"batch_size": 64, "late_window_fraction": 0.5})

    def test_validation_selection_distinct_from_global_error(self):
        metrics = {"normalized_state_mse": 2.0,
                   "after_two_seconds": {"normalized_state_mse": 6.0}}
        self.assertEqual(validation_score(metrics, {}), 2.0)
        self.assertEqual(validation_score(metrics, {"late_validation_weight": 0.5}), 4.0)
        metrics["after_two_seconds"]["normalized_state_mse"] = None
        self.assertEqual(validation_score(metrics, {}), 2.0)
        with self.assertRaises(ValueError):
            validation_score(metrics, {"late_validation_weight": 0.5})


class TranslationEncodingTest(unittest.TestCase):
    def test_rolled_dynamics_preserve_horizontal_translation_and_gradients(self):
        torch.manual_seed(23)
        stats = {name + suffix: value for name, n in [("state", 14), ("action", 1), ("context", 2)]
                 for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        model = ResidualDynamics(stats, 8, True).double()
        torch.nn.init.uniform_(model.net[-1].weight, -.1, .1)
        state = torch.zeros(2, 14, dtype=torch.float64)
        state[:, 2], state[:, 3] = .8, 1
        actions = torch.zeros(2, 8, 1, dtype=torch.float64, requires_grad=True)
        context = torch.ones(2, 2, dtype=torch.float64)
        shift = torch.zeros_like(state)
        shift[:, :2] = torch.tensor([1.0, -2.0])
        prediction = imagine(model, state, actions, context)
        translated = imagine(model, state + shift, actions, context)
        torch.testing.assert_close(translated - shift[:, None], prediction, atol=1e-12, rtol=1e-12)
        gradient, = torch.autograd.grad(prediction[:, -1, 2].sum(), actions)
        self.assertTrue(torch.isfinite(gradient).all())
        self.assertGreater(float(gradient.norm()), 0)
        checkpoint = io.BytesIO()
        torch.save({"format": "moonrobo.residual-dynamics.v2", "model": model.state_dict(),
                    "config": {"hidden_width": 8, "horizontal_translation_invariant": True}}, checkpoint)
        checkpoint.seek(0)
        restored, _ = load_model(checkpoint)
        torch.testing.assert_close(imagine(restored.double(), state, actions, context), prediction)


if __name__ == "__main__":
    unittest.main()
