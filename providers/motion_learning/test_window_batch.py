"""Compression changes storage bytes without changing logical training inputs."""
import gzip
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import torch

from dynamics import WindowBatch


class WindowBatchTest(unittest.TestCase):
    def test_gzip_and_plain_inputs_have_identical_tensors_and_logical_digest(self):
        layout = {key: [None] * width for key, width in [
            ("state_axes", 14), ("action_axes", 1), ("observation_axes", 3),
            ("goal_axes", 1), ("context_axes", 2)]}
        layout.update(dataset_id="original", model_ref="same-model", dt_s=.02, frame_convention="same-frame")
        data = dict(format="moonrobo.training-batch.v1", split="train", layout=layout,
                    windows=[dict(episode_id="one", start_step=0)], window_length=2,
                    state=list(range(28)), next_state=list(range(1, 29)),
                    applied_action=[.1, .2], observation=list(range(6)),
                    goal=[.3, .4], context=[1, 1], time_s=[0, .02])
        raw = json.dumps(data).encode()
        with tempfile.TemporaryDirectory() as folder:
            plain, compressed = Path(folder) / "batch.json", Path(folder) / "batch.json.gz"
            plain.write_bytes(raw)
            compressed.write_bytes(gzip.compress(raw))
            a, b = WindowBatch(plain, "train"), WindowBatch(compressed, "train")
            manifest = dict(format="moonrobo.training-batch-shards.v1", split="train", layout=layout,
                window_length=2, shards=[dict(file=plain.name, sha256=a.digest, windows=1),
                                         dict(file=compressed.name, sha256=b.digest, windows=1)])
            manifest_path = Path(folder) / "manifest.json"
            manifest_path.write_text(json.dumps(manifest))
            combined = WindowBatch(manifest_path, "train")
            for field in ["state", "action", "target", "observation", "goal", "start_time_s", "context"]:
                self.assertTrue(torch.equal(getattr(combined, field), torch.cat([getattr(a, field)] * 2)))
            data["applied_action"][0] = .9
            compressed.write_bytes(gzip.compress(json.dumps(data).encode()))
            with self.assertRaisesRegex(ValueError, "shard differs"):
                WindowBatch(manifest_path, "train")
        self.assertEqual(a.digest, hashlib.sha256(raw).hexdigest())
        self.assertEqual(a.digest, b.digest)
        self.assertNotEqual(a.storage_digest, b.storage_digest)
        self.assertEqual(a.layout, b.layout)
        for key in ["state", "target", "observation", "action", "goal", "context", "start_time_s"]:
            self.assertTrue(torch.equal(getattr(a, key), getattr(b, key)))
        b.layout = {**b.layout, "dataset_id": "derived"}
        with self.assertRaises(ValueError):
            a.compatible(b)
        a.compatible(b, require_dataset_id=False)
        b.layout["dt_s"] = .01
        with self.assertRaises(ValueError):
            a.compatible(b, require_dataset_id=False)


if __name__ == "__main__":
    unittest.main()
