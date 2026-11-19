"""Teacher memory windows and action-channel interventions preserve their contracts."""
from types import SimpleNamespace
import unittest

import numpy as np

from balance_intervention import WindowTeacher, blend_actions, joint_groups
from balance_teacher import BalanceTeacher


class BalanceInterventionTest(unittest.TestCase):
    def test_error_frames_mean_n_minus_one_finite_differences_and_reset_filter_state(self):
        names = ["left_ankle_pitch_joint", "left_ankle_roll_joint", "right_ankle_pitch_joint", "right_ankle_roll_joint", "waist_pitch_joint"]
        rt = SimpleNamespace(model=SimpleNamespace(nu=5, site=lambda name: SimpleNamespace(id=0 if name == "left_foot" else 1)),
            data=SimpleNamespace(xmat=np.eye(3)[None].reshape(1, 9), site_xpos=np.array([[0, -.1, 0], [0, .1, 0]]),
                subtree_com=np.array([[0., 0., .8]]), qvel=np.zeros(11)),
            names=names, root=0, dt=.02, v_indices=np.arange(6, 11), clip_control=lambda action: action)
        config = dict(angle_gain=0, rate_gain=0, com_gain=0, velocity_gain=1,
            pitch_bias_rad=0, residual_bound_rad=100, joint_damping=0)
        full = BalanceTeacher(rt, config)
        short = WindowTeacher(BalanceTeacher(rt, config), 10)
        long = WindowTeacher(BalanceTeacher(rt, config), 50)
        zero = WindowTeacher(BalanceTeacher(rt, config), 1)
        errors = []
        for index in range(35):
            rt.data.subtree_com[0, 0] = .0001 * index ** 2
            errors.append(rt.data.subtree_com[0, 0])
            full_action = full(None, np.zeros(5))
            np.testing.assert_allclose(long(None, np.zeros(5)), full_action, atol=1e-15)
            short(None, np.zeros(5))
            expected = 0.
            window = errors[-10:]
            for a, b in zip(window, window[1:]):
                expected = .8 * expected + .2 * (b - a) / rt.dt
            self.assertAlmostEqual(short.teacher.velocity[0], expected)
            np.testing.assert_array_equal(zero(None, np.zeros(5)), np.zeros(5))
        self.assertGreater(abs(short.teacher.velocity[0] - full.velocity[0]), 1e-4)
        fresh = WindowTeacher(BalanceTeacher(rt, config), 10)
        np.testing.assert_array_equal(fresh(None, np.zeros(5)), np.zeros(5))

    def test_substitution_changes_only_declared_channels_without_mutating_sources(self):
        names = ["left_hip_pitch_joint", "left_ankle_pitch_joint", "right_ankle_pitch_joint",
            "left_ankle_roll_joint", "right_ankle_roll_joint", "waist_pitch_joint", "left_shoulder_pitch_joint"]
        groups = joint_groups(names)
        self.assertEqual(groups["ankle"], [1, 2, 3, 4])
        self.assertEqual(groups["ankle_waist"], [1, 2, 3, 4, 5])
        self.assertEqual(groups["lower"], [0, 1, 2, 3, 4])
        student, teacher = np.arange(7.), np.arange(7.) + 10
        action = blend_actions(student, teacher, groups["ankle_waist"])
        np.testing.assert_array_equal(action[groups["ankle_waist"]], teacher[groups["ankle_waist"]])
        np.testing.assert_array_equal(action[[0, 6]], student[[0, 6]])
        np.testing.assert_array_equal(student, np.arange(7.))
        np.testing.assert_array_equal(teacher, np.arange(7.) + 10)


if __name__ == "__main__":
    unittest.main()
