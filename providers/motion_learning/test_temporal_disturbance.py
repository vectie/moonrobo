"""Teacher labels stay separate from noisy applied controls and causal history."""
from pathlib import Path
import tempfile
import unittest

import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from policy import Actor
from temporal_actor import TemporalActor, episode_points
from temporal_disturbance import collect_labeled


class TemporalDisturbanceTest(unittest.TestCase):
    def test_labeled_noisy_rollouts_preserve_actual_actions_and_reset_teacher_memory(self):
        xml = '''<mujoco><option timestep=".002" gravity="0 0 0"/>
          <worldbody><body pos="0 0 1"><freejoint/><geom type="sphere" size=".1"/>
            <body><joint name="hinge"/><geom type="capsule" size=".03 .1"/></body>
          </body></worldbody><actuator><position joint="hinge" kp="10" ctrlrange="-1 1"/></actuator>
          <keyframe><key name="home" qpos="0 0 1 1 0 0 0 0"/></keyframe></mujoco>'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "scene.xml"; path.write_text(xml)
            runtime = PhysicsRuntime(path)
            stats = dict(obs_mean=torch.zeros(9), obs_scale=torch.ones(9), goal_mean=torch.zeros(1),
                goal_scale=torch.ones(1), lower=torch.tensor([-1.]), upper=torch.tensor([1.]))
            base = Actor(stats, dict(hidden_width=8, action_delta_rad=.3),
                dict(q_indices=runtime.q_indices.tolist(), v_state_indices=(runtime.v_indices + runtime.model.nq).tolist(), nq=runtime.model.nq))
            actor = TemporalActor(base, 10, 10, 8)
            case = dict(id="toy", family="train-fixture", split="train", motion="stand", keyframe="home", friction=1)
            collection = dict(cases=[case])
            config = dict(collection_latent_std=.03, duration_s=.2, fall_height_m=.35, fall_upright_z=.5)
            teachers = []
            def factory():
                count = [0]; teachers.append(count)
                def predict(obs, goal):
                    count[0] += 1
                    return np.asarray(goal) + .2
                return predict
            batch = collect_labeled(runtime, actor, collection, config, [3, 4], 5, factory)
            self.assertEqual(teachers, [[10], [10]])
            self.assertEqual(batch["summary"]["trials"], 2)
            self.assertEqual(batch["maximum_input_alignment_error"], 0)
            for episode, labels in zip(batch["episodes"], batch["teacher_targets"]):
                self.assertEqual(labels, [[.2]] * 10)
                actual = torch.tensor([s["applied_action"] for s in episode["steps"]])
                self.assertGreater(float(actual.abs().max()), 0)
                self.assertFalse(torch.equal(actual, torch.tensor(labels)))
                history = episode_points(runtime, episode, case, 10, 10)[0]
                torch.testing.assert_close(history[1:, -1, -1], actual[:-1, 0], rtol=0, atol=0)
                self.assertEqual(float(history[0, -1, -1]), 0)
            case["split"] = "validation"
            with self.assertRaisesRegex(ValueError, "training families only"):
                collect_labeled(runtime, actor, collection, config, [3], 5, factory)


if __name__ == "__main__":
    unittest.main()
