"""Tests of motion ingestion and adaptive resets (no GPU required)."""
import json
import hashlib
import ast
import importlib.util
import sys
import types
from pathlib import Path
import tempfile
import unittest

import numpy as np
import torch

from aligned.motion import MotionLib
from aligned.sampling import ReturnBinSampler


class SimpleKinematics:
    def forward(self, p, R, v, w, q, qd):
        return p[:, None], R[:, None], v[:, None], w[:, None]


class AlignedDataTest(unittest.TestCase):
    def make_motion(self, folder, frames=(31, 61)):
        files = []
        for i, n in enumerate(frames):
            raw = np.zeros((n, 36))
            raw[:, 0] = np.arange(n) / 30
            raw[:, 6] = 1
            path = Path(folder) / f"fixture-{i}.csv"
            np.savetxt(path, raw, delimiter=",")
            files.append(str(path))
        return MotionLib(files, SimpleKinematics(), "cpu")

    def test_resampling_velocity_goals_and_end_bins(self):
        with tempfile.TemporaryDirectory() as folder:
            motion = self.make_motion(folder)
            self.assertEqual(motion.clip_len.tolist(), [51, 101])
            self.assertEqual(motion.num_bins, 3)
            self.assertEqual(motion.frame_bin[motion.clip_end].tolist(), [0, 2])
            torch.testing.assert_close(motion.root_v[:, 0], torch.ones(152), atol=1e-5, rtol=0)
            frames = torch.tensor([0, 50, 151])
            self.assertEqual(tuple(motion.goal(frames, 10).shape), (3, 730))
            self.assertEqual(motion.future_frames(frames, 2).tolist(), [[1, 2], [50, 50], [151, 151]])
            sampler = ReturnBinSampler(motion)
            sampled, _ = sampler.sample(4000)
            self.assertTrue((sampled < motion.clip_end[motion.clip_id[sampled]]).all())
            sampled, _ = sampler.sample(400, min_remaining_steps=32)
            self.assertTrue((sampled + 32 <= motion.clip_end[motion.clip_id[sampled]]).all())

    def test_duplicate_bin_update_is_order_independent_and_checkpoint_exact(self):
        with tempfile.TemporaryDirectory() as folder:
            motion = self.make_motion(folder)
            first, second = ReturnBinSampler(motion, seed=12), ReturnBinSampler(motion, seed=999)
            first.update([0, 0, 2], [2., 6., 10.])
            second.update([2, 0, 0], [10., 6., 2.])
            torch.testing.assert_close(first.bin_G, torch.tensor([0.8, 0., 2.]))
            self.assertTrue(torch.equal(first.bin_G, second.bin_G))
            self.assertEqual(first.completed_count.tolist(), [2, 0, 1])
            self.assertGreater(first.probabilities()[1], first.probabilities()[2])
            first.sample(15)
            second.load_state_dict(first.state_dict())
            for x, y in zip(first.sample(100), second.sample(100)):
                self.assertTrue(torch.equal(x, y))

    def test_timeout_bootstrap_and_real_terminal(self):
        with tempfile.TemporaryDirectory() as folder:
            sampler = ReturnBinSampler(self.make_motion(folder), gamma=0.5)
            sampler.update([0, 1], [0.15, 0.15], [2, 2], [0.2, 0.2], [False, True])
            torch.testing.assert_close(sampler.bin_G, torch.tensor([0.04, 0.03, 0.]))

    def test_manifest_hash_verification_and_split_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            self.make_motion(folder)
            path = Path(folder) / "fixture-0.csv"
            manifest = {"format": "moonrobo.aligned-motion-catalog.v1", "source_fps": 30,
                        "quaternion_order": "xyzw", "clips": [{"id": "dance",
                        "path": path.name, "layout": "root_xyz+quaternion_xyzw+g1_29_joint_angles",
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}],
                        "splits": {"train": ["dance"], "evaluation": ["dance"]}}
            catalog = Path(folder) / "manifest.json"
            catalog.write_text(json.dumps(manifest))
            motion = MotionLib.from_manifest(catalog, SimpleKinematics(), "cpu", "evaluation")
            self.assertEqual(motion.names, ["dance"])
            self.assertEqual(motion.split, "evaluation")
            path.write_text(path.read_text() + "\n")
            with self.assertRaisesRegex(ValueError, "SHA256"):
                MotionLib.from_manifest(catalog, SimpleKinematics(), "cpu")

    def test_reference_only_export_skips_fk_without_changing_goal_features(self):
        with tempfile.TemporaryDirectory() as folder:
            full = self.make_motion(folder)
            class NoFK:
                def forward(self, *args):
                    raise AssertionError("reference-only export must not allocate body FK")
            light = MotionLib.from_dir(folder, NoFK(), "cpu", compute_body_features=False)
            self.assertIsNone(light.body_p)
            frames = torch.tensor([0, 50, 151])
            torch.testing.assert_close(light.goal(frames, 10), full.goal(frames, 10), rtol=0, atol=0)


class SmcDataDifferentialTest(unittest.TestCase):
    """Execute frozen sibling source only as a test oracle, never at runtime.

    These integration tests skip explicitly when the optional source/data are
    absent. On the development checkout they cover real acquired clips and
    smc's actual reset method without importing its Isaac environment.
    """
    @classmethod
    def setUpClass(cls):
        cls.repo = Path(__file__).resolve().parents[2]
        cls.smc = cls.repo.parent / "smc" / "supermimic"
        if not (cls.smc / "motion.py").exists():
            raise unittest.SkipTest("optional ../smc differential oracle unavailable")
        cls.prefix = "_moonrobo_smc_data_oracle"
        package = types.ModuleType(cls.prefix)
        package.__path__ = [str(cls.smc)]
        sys.modules[cls.prefix] = package
        stub = types.ModuleType(cls.prefix + ".kinematics")
        stub.G1Kinematics = SimpleKinematics
        sys.modules[stub.__name__] = stub
        for name in ("rotations", "motion"):
            spec = importlib.util.spec_from_file_location(cls.prefix + "." + name, cls.smc / (name + ".py"))
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
        cls.oracle_motion = sys.modules[cls.prefix + ".motion"].MotionLib
        tree = ast.parse((cls.smc / "env.py").read_text())
        sim = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "TrackingSim")
        method = next(node for node in sim.body if isinstance(node, ast.FunctionDef) and node.name == "sample_frames")
        namespace = {"torch": torch}
        exec(compile(ast.Module(body=[method], type_ignores=[]), str(cls.smc / "env.py"), "exec"), namespace)
        cls.oracle_sample = staticmethod(namespace["sample_frames"])

    @classmethod
    def tearDownClass(cls):
        for name in tuple(sys.modules):
            if name == cls.prefix or name.startswith(cls.prefix + "."):
                del sys.modules[name]

    def test_all_40_acquired_sources_match_frozen_catalog(self):
        folder = self.repo / "target/learning/g1-aligned-data"
        path = folder / "motion-manifest.json"
        if not path.exists():
            self.skipTest("acquired LAFAN1 catalog unavailable")
        catalog = json.loads(path.read_text())
        self.assertEqual(catalog["source_revision"], "ce1572906efe6157840e8474d5a0d7aa87481e74")
        self.assertEqual(catalog["splits"]["train"], catalog["splits"]["evaluation"])
        self.assertEqual(len(catalog["clips"]), 40)
        total = 0
        # Stream clips individually. No full-corpus FK or model cache allocation.
        for clip in catalog["clips"]:
            filename = folder / clip["path"]
            with self.subTest(clip=clip["id"]):
                self.assertEqual(hashlib.sha256(filename.read_bytes()).hexdigest(), clip["sha256"])
                raw = np.loadtxt(filename, delimiter=",")
                self.assertEqual(raw.shape, (clip["source_frames"], 36))
                self.assertTrue(np.isfinite(raw).all())
                self.assertTrue((np.linalg.norm(raw[:, 3:7], axis=1) > 0.99).all())
                total += len(raw)
        self.assertEqual(total, 264705)
        resampled = sum(int(np.floor(((row["source_frames"] - 1) / catalog["source_fps"]) / 0.02)) + 1
                        for row in catalog["clips"])
        print(json.dumps({"verified_real_clips": 40, "verified_source_frames": total,
                          "smc_formula_resampled_frames": resampled,
                          "catalog_sha256": hashlib.sha256(path.read_bytes()).hexdigest()}))

    def test_real_clip_reference_states_and_goals_against_smc(self):
        folder = self.repo / "target/learning/g1-aligned-data/lafan1_g1"
        if not folder.is_dir():
            self.skipTest("acquired LAFAN1 clips unavailable")
        maximum_goal_difference = 0.
        for name in ("dance1_subject1", "fallAndGetUp3_subject1", "walk4_subject1"):
            with self.subTest(clip=name):
                files = [str(folder / (name + ".csv"))]
                actual = MotionLib(files, SimpleKinematics(), "cpu", compute_body_features=False)
                expected = self.oracle_motion(files, SimpleKinematics(), "cpu")
                for field in ("clip_len", "clip_start", "clip_end", "clip_id", "root_p", "root_R",
                              "root_v", "root_w", "q", "qd", "root_v_local", "root_w_local", "root_gz"):
                    torch.testing.assert_close(getattr(actual, field), getattr(expected, field), rtol=0, atol=0,
                                               msg=lambda msg: f"{name} {field}: {msg}")
                frames = torch.arange(actual.num_frames)
                torch.testing.assert_close(actual.future_frames(frames, 10), expected.future_frames(frames, 10), rtol=0, atol=0)
                goals, oracle_goals = actual.goal(frames, 10), expected.goal(frames, 10)
                delta = float((goals - oracle_goals).abs().max())
                maximum_goal_difference = max(maximum_goal_difference, delta)
                # Documented SO(3) correction in yaw_mat removes smc's tiny
                # epsilon shrink; interpolation/state semantics remain exact.
                torch.testing.assert_close(goals, oracle_goals, rtol=2e-6, atol=2e-6)
                del actual, expected, goals, oracle_goals
        print(json.dumps({"real_clip_differential_count": 3, "state_tensors_bitwise_equal": True,
                          "maximum_goal_abs_difference": maximum_goal_difference}))

    def test_reset_mixture_and_unique_return_updates_match_actual_smc_method(self):
        with tempfile.TemporaryDirectory() as folder:
            motion = AlignedDataTest().make_motion(folder, frames=(32, 62))
            sampler = ReturnBinSampler(motion, seed=192)
            sampler.bin_G.copy_(torch.linspace(0, sampler.G_max, motion.num_bins))
            oracle = types.SimpleNamespace(motion=motion, device="cpu", G_max=sampler.G_max,
                                           bin_G=sampler.bin_G.clone(), bin_w_avg=sampler.bin_w_avg.clone())
            with torch.random.fork_rng():
                torch.manual_seed(192)
                expected = self.oracle_sample(oracle, 256)
            actual = sampler.sample(256)
            for a, b in zip(actual, expected):
                torch.testing.assert_close(a, b, rtol=0, atol=0)
            torch.testing.assert_close(sampler.bin_w_avg, oracle.bin_w_avg, rtol=0, atol=0)
            bins = torch.tensor([0, 2])
            returns = torch.tensor([3., 5.])
            oracle.bin_G.index_put_((bins,), 0.8 * oracle.bin_G[bins] + 0.2 * returns)
            sampler.update(bins, returns)
            torch.testing.assert_close(sampler.bin_G, oracle.bin_G, rtol=0, atol=0)

    def test_terminal_only_bins_are_explicit_upstream_bug_fix(self):
        with tempfile.TemporaryDirectory() as folder:
            actual = AlignedDataTest().make_motion(folder, frames=(31,))
            expected = self.oracle_motion(actual.files, SimpleKinematics(), "cpu")
            self.assertEqual(actual.clip_len.tolist(), expected.clip_len.tolist())
            self.assertEqual(expected.bin_start.tolist(), [0, 50])
            self.assertEqual(actual.bin_start.tolist(), [0])
            oracle = types.SimpleNamespace(motion=expected, device="cpu", G_max=10.,
                                           bin_G=torch.zeros(2), bin_w_avg=torch.ones(2) / 2)
            with torch.random.fork_rng():
                torch.manual_seed(16)
                bad_frames, _ = self.oracle_sample(oracle, 200)
            self.assertTrue((bad_frames == expected.clip_end[0]).any())
            good_frames, _ = ReturnBinSampler(actual, seed=16).sample(200)
            self.assertTrue((good_frames < actual.clip_end[0]).all())


if __name__ == "__main__":
    unittest.main()
