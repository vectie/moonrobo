"""Stream fitting uses actual actions and the canonical strided window endpoints."""
import gzip
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import torch

from dynamic_refit import ActualActionBatch, refit
from dynamics import ResidualDynamics, load_model


class ActualActionTest(unittest.TestCase):
    def write_manifest(self, folder, split="train", times=(0, .02, .04, .06, .08)):
        layout = dict(model_ref="toy", dt_s=.02, frame_convention="toy",
            state_axes=[None] * 14, action_axes=[None], context_axes=[None] * 2)
        steps = [dict(time_s=t, state=[float(i)] * 14, next_state=[float(i + 1)] * 14,
            applied_action=[.1 + i], terminated=i == len(times) - 1, truncated=False)
            for i, t in enumerate(times)]
        dataset = dict(**layout, episodes=[dict(id="one", split=split, steps=steps, context=[1, 1])])
        source = folder / "student.jsonl.gz"
        source.write_bytes(gzip.compress(json.dumps(dict(dataset=dataset, teacher_action_targets=[[[999]]] * 3)).encode()))
        manifest = dict(format="moonrobo.g1-actual-action-streams.v1", split="train", layout=layout,
            window_length=2, stride=2, episodes=1, sources=[dict(kind="student-jsonl-gzip", path=str(source),
            sha256=hashlib.sha256(source.read_bytes()).hexdigest(), chunks=[dict(episodes=1, transitions=len(steps))])])
        path = folder / "manifest.json"; path.write_text(json.dumps(manifest))
        return path, source

    def test_actual_controls_endpoint_retention_and_gap_filter(self):
        with tempfile.TemporaryDirectory() as directory:
            path, _ = self.write_manifest(Path(directory))
            batch = ActualActionBatch(path)
            self.assertEqual(batch.state[:, 0, 0].tolist(), [0, 2, 3])
            self.assertEqual(batch.action[:, 0, 0].tolist(), batch.action.new_tensor([.1, 2.1, 3.1]).tolist())
            self.assertEqual(batch.target[:, -1, 0].tolist(), [2, 4, 5])
            self.assertEqual((batch.episodes, batch.transitions), (1, 5))
            path, _ = self.write_manifest(Path(directory), times=(0, .02, .1, .12, .3))
            batch = ActualActionBatch(path)
            self.assertEqual(batch.state[:, 0, 0].tolist(), [0, 2])

    def test_heldout_and_modified_source_cannot_enter_fit(self):
        with tempfile.TemporaryDirectory() as directory:
            path, source = self.write_manifest(Path(directory), split="test")
            with self.assertRaisesRegex(ValueError, "held-out"):
                ActualActionBatch(path)
            source.write_bytes(source.read_bytes() + b"changed")
            with self.assertRaisesRegex(ValueError, "native-validated bytes"):
                ActualActionBatch(path)

    def test_refit_exports_selected_and_latest_with_identical_incoming_units(self):
        stats = {name + suffix: value for name, n in [("state", 14), ("action", 1), ("context", 2)]
            for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        model = ResidualDynamics(stats, 8, True)
        state = torch.zeros(4, 2, 14); state[:, :, 2], state[:, :, 3] = .8, 1
        target = state.clone(); target[:, :, 7] = .1
        batch = SimpleNamespace(state=state, target=target, action=torch.ones(4, 2, 1) * .1,
            context=torch.ones(4, 2), start_time_s=torch.tensor([0., 0., 2., 2.]), horizon=2, digest="base")
        added = SimpleNamespace(**vars(batch)); added.digest = "added"
        metadata = dict(format="moonrobo.residual-dynamics.v2", training_batch_sha256="base",
            config=dict(hidden_width=8, horizontal_translation_invariant=True), layout={})
        config = dict(updates=2, batch_size=4, learning_rate=.001, sampling_seed=3, evaluate_every=1,
            late_validation_weight=.5, initial_dynamics_sha256="initial")
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            result = refit(model, metadata, batch, added, batch, batch, config, 0, "mixed", folder, "manifest.json")
            restored, selected = load_model(folder / result["checkpoint"])
            latest, metadata_latest = load_model(folder / result["latest_checkpoint"])
            self.assertTrue(result["reload_matches"])
            self.assertEqual(metadata_latest["selected_update"], 2)
            self.assertEqual(selected["training_batch_sha256"], hashlib.sha256((folder / "training-input.json").read_bytes()).hexdigest())
            for name, buffer in model.named_buffers():
                self.assertTrue(torch.equal(buffer, dict(restored.named_buffers())[name]))
                self.assertTrue(torch.equal(buffer, dict(latest.named_buffers())[name]))


if __name__ == "__main__":
    unittest.main()
