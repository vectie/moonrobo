"""Feedback signs and bounds for the simulator's declared joint axes."""
from types import SimpleNamespace
import unittest

import numpy as np
import mujoco

from balance_teacher import BalanceTeacher, support_torque


class BalanceTeacherTest(unittest.TestCase):
    def test_support_compensation_balances_free_base_without_external_actuation(self):
        model = mujoco.MjModel.from_xml_string('''<mujoco><worldbody>
          <body pos="0 0 1"><freejoint/><geom type="sphere" pos=".05 0 0" size=".1" mass="2"/>
            <body pos="0 .1 0"><joint name="l" axis="0 1 0"/><geom type="capsule" fromto="0 0 0 0 0 -.8" size=".02" mass="1"/><site name="left_foot" pos="0 0 -.8"/></body>
            <body pos="0 -.1 0"><joint name="r" axis="0 1 0"/><geom type="capsule" fromto="0 0 0 0 0 -.8" size=".02" mass="1"/><site name="right_foot" pos="0 0 -.8"/></body>
          </body></worldbody><actuator><position joint="l" kp="20"/><position joint="r" kp="20"/></actuator></mujoco>''')
        data = mujoco.MjData(model)
        data.qpos[7:] = .02
        mujoco.mj_forward(model, data)
        before = data.qfrc_applied.copy()
        torque = support_torque(SimpleNamespace(model=model, data=data, root=1),
                                [model.site("left_foot").id, model.site("right_foot").id])
        np.testing.assert_allclose(torque[:6], 0, atol=1e-10)
        self.assertGreater(np.linalg.norm(torque[6:]), .01)
        np.testing.assert_array_equal(data.qfrc_applied, before)

    def runtime(self):
        sites = {"left_foot": 0, "right_foot": 1}
        return SimpleNamespace(
            model=SimpleNamespace(nu=5, site=lambda name: SimpleNamespace(id=sites[name])),
            data=SimpleNamespace(xmat=np.eye(3)[None].reshape(1, 9),
                site_xpos=np.array([[0, -.1, 0], [0, .1, 0]]),
                subtree_com=np.array([[0., 0., .8]]), qvel=np.zeros(11)),
            names=["left_ankle_pitch_joint", "left_ankle_roll_joint", "right_ankle_pitch_joint", "right_ankle_roll_joint", "waist_pitch_joint"],
            root=0, dt=.02, v_indices=np.arange(6, 11), clip_control=lambda value: np.clip(value, -1, 1))

    def config(self):
        return dict(angle_gain=1, rate_gain=.1, com_gain=2, velocity_gain=.2,
                    pitch_bias_rad=0, residual_bound_rad=.3, joint_damping=.02)

    def test_tilt_and_com_feedback_use_axis_signs_and_preserve_goals(self):
        rt = self.runtime()
        theta = .1
        c, s = np.cos(theta), np.sin(theta)
        rt.data.xmat[0] = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]]).flatten()
        action = BalanceTeacher(rt, self.config())(None, np.zeros(5))
        np.testing.assert_allclose(action[[0, 2]], theta)
        np.testing.assert_allclose(action[[1, 3, 4]], 0)
        rt.data.xmat[0] = np.array([[1, 0, 0], [0, c, -s], [0, s, c]]).flatten()
        action = BalanceTeacher(rt, self.config())(None, np.zeros(5))
        np.testing.assert_allclose(action[[1, 3]], theta)
        rt.data.xmat[0] = np.eye(3).flatten()
        rt.data.subtree_com[0, :2] = [.05, .03]
        goal = np.array([.1, .1, .1, .1, .2])
        action = BalanceTeacher(rt, self.config())(None, goal)
        np.testing.assert_allclose(action - goal, [.1, -.06, .1, -.06, 0])
        np.testing.assert_array_equal(goal, [.1, .1, .1, .1, .2])
        assisted = BalanceTeacher(rt, {**self.config(), "waist_share": .5})(None, goal)
        self.assertAlmostEqual(assisted[4] - goal[4], -.05)

    def test_residual_and_actuator_bounds_and_episode_reset(self):
        rt = self.runtime()
        rt.data.subtree_com[0, 0] = 10
        teacher = BalanceTeacher(rt, self.config())
        first = teacher(None, np.array([.9, 0, .9, 0, 0]))
        np.testing.assert_array_equal(first, [1, 0, 1, 0, 0])
        rt.data.subtree_com[0, 0] = 0
        teacher(None, np.zeros(5))
        fresh = BalanceTeacher(rt, self.config())
        np.testing.assert_array_equal(fresh(None, np.zeros(5)), np.zeros(5))
        self.assertTrue(np.all(np.abs(teacher(None, np.zeros(5))) <= .3))


if __name__ == "__main__":
    unittest.main()
