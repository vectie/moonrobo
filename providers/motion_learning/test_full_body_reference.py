"""Reference timing/frame semantics and actual nonzero-origin MuJoCo replay."""
from pathlib import Path
import unittest

import numpy as np

from cpu_physics import PhysicsRuntime
from full_body_reference import FullBodyReference, assess_tracking_quality, capture_frame, encode_goal, layout_for, replay_reference


class FullBodyReferenceTest(unittest.TestCase):
    def setUp(self):
        scene = Path(__file__).resolve().parents[2] / "target/mujoco_menagerie/unitree_g1/scene_mjx.xml"
        self.runtime = PhysicsRuntime(scene)
        self.case = dict(id="stand", family="procedural-stand", motion="stand", keyframe="home", split="train", friction=1.)
        frames = []
        episode, _ = self.runtime.rollout(self.case, 17, "position", .4,
            trace_callback=lambda rt, i, action, goal: frames.append(capture_frame(rt)))
        frames.append(capture_frame(self.runtime))
        self.arrays = {key: np.stack([f[key] for f in frames]) for key in frames[0]}
        self.arrays.update(source_setpoint=np.asarray([s["applied_action"] for s in episode["steps"]]),
            observation=np.asarray([s["observation"] for s in episode["steps"]]))
        self.layout = layout_for(self.runtime)
        self.reference = FullBodyReference(self.arrays, self.layout)

    def test_reapply_controls_from_nonzero_origin_without_state_overwrites(self):
        episode, trial = replay_reference(self.runtime, self.reference, self.case, 7, "source-setpoint")
        self.assertEqual(len(episode["steps"]), self.reference.steps-7)
        self.assertFalse(trial["failed"])
        self.assertLess(trial["max_state_component_error"], 1e-10)
        np.testing.assert_allclose(episode["steps"][0]["goal"], self.reference.goals[8], atol=0, rtol=0)
        self.assertTrue(episode["steps"][-1]["truncated"])

    def test_preview_uses_next_frame_and_masks_padding_without_source_controls(self):
        goal, valid = self.reference.preview(self.reference.steps-2, 4)
        np.testing.assert_array_equal(valid, [True, True, False, False])
        np.testing.assert_array_equal(goal, self.reference.goals[[-2, -1, -1, -1]])
        altered = {**self.arrays, "source_setpoint": self.arrays["source_setpoint"]+100}
        np.testing.assert_array_equal(FullBodyReference(altered, self.layout).goals, self.reference.goals)

    def test_actor_goal_invariant_to_world_yaw_and_xy_origin(self):
        i = 5
        s = self.arrays["state"][i].copy()
        p, r = self.arrays["body_position"][i], self.arrays["body_rotation"][i]
        yaw = .83
        rotation = np.array([[np.cos(yaw), -np.sin(yaw), 0], [np.sin(yaw), np.cos(yaw), 0], [0, 0, 1]])
        s[self.runtime.model.nq:self.runtime.model.nq+3] = rotation @ s[self.runtime.model.nq:self.runtime.model.nq+3]
        changed = encode_goal(s, p @ rotation.T + [7., -12., 0.], rotation @ r,
            self.runtime.q_indices, self.runtime.v_indices, self.runtime.model.nq, self.runtime.root-1)
        np.testing.assert_allclose(changed, self.reference.goals[i], atol=3e-15, rtol=1e-12)

    def test_policy_interface_matches_position_baseline_and_cannot_pass_missing_cells(self):
        previews = []
        def position_policy(obs, current, future, valid):
            self.assertEqual(obs.shape, (93,))
            self.assertEqual(current.shape, (len(self.layout["goal_axes"]),))
            self.assertEqual(future.shape, (10, len(self.layout["goal_axes"])))
            previews.append(valid)
            return future[0, :29]
        episode, trial = replay_reference(self.runtime, self.reference, self.case, 7, "policy", policy=position_policy)
        expected, _ = replay_reference(self.runtime, self.reference, self.case, 7, "joint-position")
        self.assertEqual(episode["steps"], expected["steps"])
        self.assertTrue(previews[0].all())
        self.assertEqual(int(previews[-1].sum()), 1)
        quality = dict(scope="test", dt_s=.02, reference_ids=["stand"], origins_s=[.14], maximum_per_trial={"joint_rmse_rad": 1.})
        self.assertTrue(assess_tracking_quality([trial], quality)["quality_passed"])
        self.assertFalse(assess_tracking_quality([], quality)["quality_passed"])
        self.assertFalse(assess_tracking_quality([trial, trial], quality)["quality_passed"])


if __name__ == "__main__":
    unittest.main()
