import unittest

import numpy as np

from cpu_physics import sample_pose_offset


class PoseGoalTests(unittest.TestCase):
    def test_seeded_offsets_repeat_and_cover_joint_group_bounds(self):
        names = ["left_hip_pitch_joint", "waist_yaw_joint", "left_shoulder_pitch_joint", "right_wrist_yaw_joint"]
        case = {"goal_offset_rad": {"lower": .04, "waist": .08, "upper": .12}}
        first = sample_pose_offset(names, case, 0)
        np.testing.assert_array_equal(first, sample_pose_offset(names, case, 0))
        samples = np.array([sample_pose_offset(names, case, seed) for seed in range(12)])
        self.assertTrue(np.all(np.abs(samples) <= [.04, .08, .12, .12]))
        self.assertTrue(np.all(np.ptp(samples, axis=0) > .01))

    def test_invalid_amplitudes_are_not_silently_used(self):
        case = {"goal_offset_rad": {"lower": .04, "waist": float("nan"), "upper": .12}}
        with self.assertRaises(ValueError):
            sample_pose_offset(["waist_yaw_joint"], case, 0)


if __name__ == "__main__":
    unittest.main()
