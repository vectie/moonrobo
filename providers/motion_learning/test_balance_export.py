"""Reconstructed historical viewer traces agree with directly captured physics."""
from pathlib import Path
import tempfile
import unittest

import numpy as np

from cpu_physics import PhysicsRuntime
from learned_balance_export import replay_from_recorded_states


class BalanceExportTest(unittest.TestCase):
    def test_recorded_next_state_reconstruction_matches_captured_replay(self):
        xml = '''<mujoco><option timestep=".004"/>
          <worldbody><geom type="plane" size="2 2 .1"/>
            <body name="root" pos="0 0 .85"><freejoint/>
              <geom type="sphere" size=".1" mass="2"/>
              <body pos="0 0 -.75"><joint name="ankle" axis="0 1 0"/>
                <geom type="sphere" size=".12" mass="1"/>
              </body>
            </body>
          </worldbody><actuator><position joint="ankle" kp="10" ctrlrange="-1 1"/></actuator>
          <keyframe><key name="home"/></keyframe></mujoco>'''
        with tempfile.TemporaryDirectory() as folder:
            scene = Path(folder) / "scene.xml"; scene.write_text(xml)
            runtime = PhysicsRuntime(scene)
            case = dict(id="stand", family="stand", motion="stand", keyframe="home", split="train", friction=.7)
            episode, trial = runtime.rollout(case, 7, "position", .12)
            actual = replay_from_recorded_states(runtime, episode)
        self.assertTrue(any(row["contacts"] > 0 for row in trial["replay"]))
        for reconstructed, captured in zip(actual, trial["replay"]):
            self.assertEqual(reconstructed["contacts"], captured["contacts"])
            for field in ["time_s", "qpos", "target", "root_height_m", "upright_z"]:
                np.testing.assert_allclose(reconstructed[field], captured[field], atol=1e-14, rtol=0)


if __name__ == "__main__":
    unittest.main()
