"""Restored temporal control must retain both physical memory and command phase."""
import copy
from pathlib import Path
import tempfile
import unittest

import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from policy import Actor, observation
from temporal_actor import TemporalActor, temporal_imagination
from temporal_probe import adam_direction, collect_origins, imagined_returns, physical_return


class TemporalProbeTest(unittest.TestCase):
    def actor(self):
        stats = dict(obs_mean=torch.zeros(9), obs_scale=torch.ones(9), goal_mean=torch.zeros(1),
            goal_scale=torch.ones(1), lower=torch.tensor([-1.]), upper=torch.tensor([1.]))
        base = Actor(stats, dict(hidden_width=8, action_delta_rad=.3),
            dict(q_indices=[7], v_state_indices=[8], nq=8))
        actor = TemporalActor(base, 3, 2, 8)
        with torch.no_grad():
            actor.adapter[-1].weight.uniform_(-.3, .3)
        return actor

    def test_dynamic_restore_replays_history_phase_and_full_episode_end(self):
        xml = '''<mujoco><option timestep=".002" gravity="0 0 0"/>
          <worldbody><body pos="0 0 1"><freejoint/><geom type="sphere" size=".1"/>
            <body><joint name="hinge"/><geom type="capsule" size=".03 .1"/></body>
          </body></worldbody><actuator><position joint="hinge" kp="10" ctrlrange="-1 1"/></actuator>
          <keyframe><key name="home" qpos="0 0 1 1 0 0 0 0"/></keyframe></mujoco>'''
        torch.manual_seed(2)
        actor = self.actor()
        case = dict(id="sines", family="training-family", split="train", motion="random_joint_sines",
            keyframe="home", friction=1, goal_offset_rad=dict(lower=.1, waist=.1, upper=.1))
        config = dict(case_ids=["sines"], reset_seeds=[3], snapshot_steps=[0, 2, 4], horizon=3,
            gamma=.99, target_height_m=1, fall_height_m=.35, fall_upright_z=.5)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scene.xml"; path.write_text(xml)
            runtime = PhysicsRuntime(path)
            origins, omitted = collect_origins(runtime, actor, dict(cases=[case], duration_s=.2), config)
            self.assertEqual(omitted, [])
            self.assertEqual(len(origins), 3)
            data = runtime.data
            for origin in origins:
                actual, states, actions = physical_return(runtime, origin, actor, config)
                self.assertIs(runtime.data, data)
                self.assertEqual(actual["steps"], 10 - origin["start_step"])
                self.assertFalse(actual["failed"])
                np.testing.assert_allclose(states, [s["next_state"] for s in origin["reference"]], atol=1e-12)
                np.testing.assert_allclose(actions, [s["applied_action"] for s in origin["reference"]], atol=1e-12)
            changed = copy.deepcopy(origins[-1])
            changed["history"][:-1] = [[10.] * 9] * 2
            self.assertFalse(np.allclose(physical_return(runtime, changed, actor, config)[2],
                [s["applied_action"] for s in origins[-1]["reference"]]))
            case["split"] = "test"
            with self.assertRaisesRegex(ValueError, "training motions only"):
                collect_origins(runtime, actor, dict(cases=[case], duration_s=.2), config)

    def test_per_origin_returns_and_temporal_adam_keep_model_frozen(self):
        torch.manual_seed(3)
        actor = self.actor()
        state = torch.zeros(2, 14); state[:, 2], state[:, 3], state[:, 7] = 1, 1, -.1
        goals = torch.tensor([[[.1], [.2], [.05], [-.1], [-.2], [.1]]]).expand(2, -1, -1)
        context = torch.ones(2, 2)
        dynamics = lambda state, action, context: state + torch.nn.functional.pad(action * .1, (7, 6))
        config = dict(horizon=3, gamma=.99, target_height_m=1, actor_critic_bootstrap=False, actor_learning_rate=1e-5)
        history = observation(state, torch.zeros(2, 1), actor.body)[:, None].expand(-1, 3, -1)
        batch = state, history, goals, context
        values = imagined_returns(dynamics, actor, batch, config)
        torch.testing.assert_close(values.mean(), temporal_imagination(dynamics, actor, None, *batch, config)[0])
        delta, norm = adam_direction(dynamics, actor, batch, config)
        self.assertGreater(norm, 0)
        from actor_update_probe import scaled_actor
        candidate = scaled_actor(actor, delta, 1)
        self.assertGreater(float(imagined_returns(dynamics, candidate, batch, config).mean().detach()), float(values.mean().detach()))


if __name__ == "__main__":
    unittest.main()
