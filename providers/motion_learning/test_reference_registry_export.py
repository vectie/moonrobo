"""Recorded-state trace reconstruction preserves the full commanded remainder."""
from pathlib import Path
import unittest

import numpy as np

from cpu_physics import PhysicsRuntime
from full_body_reference import capture_frame
from reference_registry_export import trace_trial
from reference_learning_registry_export import comparison_baseline


class ReferenceRegistryExportTest(unittest.TestCase):
    def test_learning_comparison_uses_same_seed_trained_baseline_and_prior_for_its_own_entry(self):
        initial = dict(trials=["prior"])
        fifo0 = dict(method="replay-prefix-extended", seed=0, cycles=list(range(6)), trials=["seed-0"])
        fifo1 = dict(method="replay-prefix-extended", seed=1, cycles=list(range(6)), trials=["seed-1"])
        report = dict(config=dict(reused_baseline_method="replay-prefix-extended"), initial=initial, runs=[fifo0, fifo1])
        baseline, role = comparison_baseline(report, "replay-prefix-anchor", 1)
        self.assertIs(baseline, fifo1)
        self.assertIn("six-cycle recent-FIFO", role)
        self.assertIs(comparison_baseline(report, "replay-prefix-extended", 1)[0], initial)
        report["config"] = {}
        report["runs"] = [dict(method="prefix-only", seed=1)]
        self.assertIs(comparison_baseline(report, "replay-prefix", 1)[0], report["runs"][0])

    def test_short_physics_record_keeps_later_reference_and_uses_elapsed_clock(self):
        runtime = PhysicsRuntime(Path(__file__).resolve().parents[2]/"target/mujoco_menagerie/unitree_g1/scene_mjx.xml")
        case = dict(id="stand", family="procedural-stand", motion="stand", keyframe="home", split="train", friction=1.)
        frames = []
        episode, _ = runtime.rollout(case, 17, "position", .4,
            trace_callback=lambda rt, i, action, goal: frames.append(capture_frame(rt)))
        frames.append(capture_frame(runtime))
        reference = {key: np.stack([f[key] for f in frames]) for key in frames[0]}
        reference["source_reset_seed"] = 17
        origin, count = 4, 6
        steps = episode["steps"][origin:origin+count]
        arrays = {key: np.asarray([s[key] for s in steps]) for key in ["next_state", "applied_action"]}
        before = arrays["next_state"].copy()
        trial = dict(case_id="stand", reference_start_step=origin, failed=True,
            requested_seconds=.32, simulated_seconds=.12)
        result = trace_trial(runtime, reference, dict(context=[1., 1.], origin_step=origin), trial, arrays, True)
        self.assertEqual(len(result["replay"]), count)
        self.assertEqual(len(result["reference_replay"]), 16)
        self.assertAlmostEqual(result["replay"][0]["time_s"], .02)
        self.assertAlmostEqual(result["reference_replay"][-1]["time_s"], .32)
        self.assertAlmostEqual(result["reference_start_time_s"], .08)
        for frame in result["replay"]:
            self.assertLess(frame["root_position_error_m"], 1e-12)
            self.assertLess(frame["body_position_error_m"], 1e-12)
            self.assertEqual(frame["joint_rmse_rad"], 0)
        np.testing.assert_array_equal(arrays["next_state"], before)


if __name__ == "__main__":
    unittest.main()
