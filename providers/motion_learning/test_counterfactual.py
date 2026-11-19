"""Restored physical branches keep episode time, previous actions and boundaries."""
import tempfile
from pathlib import Path
import unittest

import mujoco
import numpy as np

from counterfactual import branch_rollout
from cpu_physics import PhysicsRuntime


class BranchTest(unittest.TestCase):
    def test_restore_and_action_pulse_keep_real_transition_semantics(self):
        xml = '''<mujoco><option timestep=".002" gravity="0 0 0"/>
          <worldbody><body pos="0 0 1"><freejoint/><geom type="sphere" size=".1"/>
            <body><joint name="hinge"/><geom type="capsule" size=".03 .1"/></body>
          </body></worldbody><actuator><position joint="hinge" kp="10" ctrlrange="-1 1"/></actuator>
          <keyframe><key name="home" qpos="0 0 1 1 0 0 0 0"/></keyframe></mujoco>'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scene.xml"
            path.write_text(xml)
            rt = PhysicsRuntime(path)
            case = dict(id="toy", family="training-family", split="train", motion="stand", keyframe="home", friction=1)
            captured = {}
            def capture(runtime, i, action, goal):
                if i == 2:
                    state = np.empty(mujoco.mj_stateSize(rt.model, mujoco.mjtState.mjSTATE_INTEGRATION))
                    mujoco.mj_getState(rt.model, rt.data, state, mujoco.mjtState.mjSTATE_INTEGRATION)
                    captured.update(integration=state.tolist(), previous=[0.0], goal=goal.tolist(),
                                    start_step=2, parent_episode_id="parent")
            predict = lambda obs, goal: goal
            parent, _ = rt.rollout(case, 1, "policy", .1, policy=predict, trace_callback=capture)
            data = rt.data
            config = dict(branch_steps=3, pulse_steps=2, fall_height_m=.35, fall_upright_z=.5)
            baseline, _ = branch_rollout(rt, captured, case, predict, np.zeros(1), config, "zero")
            self.assertIs(rt.data, data)
            np.testing.assert_allclose([s["next_state"] for s in baseline["steps"]],
                                       [s["next_state"] for s in parent["steps"][2:]], atol=1e-12)
            pulse, _ = branch_rollout(rt, captured, case, predict, np.array([.05]), config, "pulse")
            self.assertEqual([s["time_s"] for s in pulse["steps"]], [.04, .06, .08])
            self.assertEqual([s["applied_action"] for s in pulse["steps"]], [[.05], [.05], [0]])
            self.assertEqual([s["observation"][-1] for s in pulse["steps"]], [0, .05, .05])
            self.assertTrue(pulse["steps"][-1]["truncated"])
            self.assertFalse(pulse["steps"][-1]["terminated"])
            self.assertEqual(pulse["source_family"], "training-family")


if __name__ == "__main__":
    unittest.main()
