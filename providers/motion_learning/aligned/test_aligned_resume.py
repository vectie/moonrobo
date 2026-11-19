"""Real MuJoCo split training must reproduce uninterrupted optimizer/physics updates."""
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest

import torch

from .train import run

ROOT = Path(__file__).resolve().parents[3]
DATA = ROOT/'target/learning/g1-aligned-data'
SCENE = DATA/'g1_description/scene.xml'


class ResumeTest(unittest.TestCase):
    @unittest.skipUnless(SCENE.exists(), 'requires prepared matching G1 assets and LAFAN1 data')
    def test_split_training_matches_uninterrupted(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            motions = base/'motions'
            motions.mkdir()
            source = DATA/'lafan1_g1/dance1_subject1.csv'
            (motions/source.name).symlink_to(source)
            cfg = json.loads((ROOT/'examples/learning/g1-aligned-cpu-smoke.json').read_text())
            cfg.update(threads=1, wm_hidden=[16, 16, 16], pi_hidden=[16, 16], critic_hidden=[16, 8], wm_only_iters=1)
            (base/'config.json').write_text(json.dumps(cfg))
            args = dict(config=str(base/'config.json'), motion_dir=str(motions), scene=str(SCENE),
                        backend='mujoco', device='cpu', usd_path=None, evaluate=False)
            run(SimpleNamespace(**args, output=str(base/'continuous'), resume=None, iterations=3))
            run(SimpleNamespace(**args, output=str(base/'split'), resume=None, iterations=2))
            run(SimpleNamespace(**args, output=str(base/'split'),
                                resume=str(base/'split/checkpoint.pt'), iterations=3))
            full = torch.load(base/'continuous/checkpoint.pt', weights_only=False)
            split = torch.load(base/'split/checkpoint.pt', weights_only=False)
            def equal(a, b):
                if isinstance(a, torch.Tensor):
                    torch.testing.assert_close(a, b, rtol=0, atol=0)
                elif isinstance(a, dict):
                    self.assertEqual(a.keys(), b.keys())
                    for key in a:
                        equal(a[key], b[key])
                elif isinstance(a, (list, tuple)):
                    self.assertEqual(len(a), len(b))
                    for x, y in zip(a, b):
                        equal(x, y)
                else:
                    self.assertEqual(a, b)
            for key in ('learner', 'replay', 'counters', 'history', 'torch_rng'):
                equal(full[key], split[key])
            self.assertEqual(full['counters']['actor_updates'], 2)
            first_report = json.loads((base/'continuous/report.json').read_text())
            self.assertNotIn('policy', first_report['updates'][0])
            self.assertIn('policy', first_report['updates'][1])
            self.assertEqual(json.loads((base/'split/report.json').read_text())['resume_kind'], 'exact')


if __name__ == '__main__':
    unittest.main()
