"""Physical score gradients and stochastic temporal rollout inputs."""
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import torch
from torch.distributions import Bernoulli, Normal

from cpu_physics import PhysicsRuntime
from policy import Actor, physical_return_targets
from temporal_actor import TemporalActor
from temporal_ppo import collect, discounted_visitation, mean_latent, policy_loss
from temporal_value import make_value


class TemporalPPOTest(unittest.TestCase):
    def test_soft_discount_weighted_score_matches_exact_expected_return_gradient(self):
        theta = torch.tensor([.2, -.3], requires_grad=True)
        probabilities = theta.sigmoid()
        exact = torch.zeros(())
        surrogate = torch.zeros(())
        for a0 in [0., 1.]:
            for a1 in [0., 1.]:
                actions = torch.tensor([a0, a1])
                dist = Bernoulli(probs=probabilities)
                log_prob = dist.log_prob(actions)
                probability = log_prob.sum().exp()
                rewards = torch.tensor([1 + a0, 2 - a1])
                continuation = torch.tensor([.2 + .6 * a0, .8])
                returns = physical_return_targets(rewards, continuation, torch.tensor([False, False]), 0, .9)
                exact = exact + probability * returns[0]
                weights = discounted_visitation(continuation, .9)
                baseline = torch.tensor([.8, 1.1])
                # Clipping is inactive at the behavior distribution (ratio one).
                loss = policy_loss(log_prob, log_prob.detach(), returns - baseline, weights, .2)
                surrogate = surrogate - probability.detach() * loss * 2
        actual, = torch.autograd.grad(exact, theta, retain_graph=True)
        estimate, = torch.autograd.grad(surrogate, theta)
        torch.testing.assert_close(estimate, actual, atol=1e-7, rtol=1e-6)

    def test_stochastic_history_reconstructs_behavior_means_and_actual_setpoints(self):
        xml = '''<mujoco><option timestep=".002" gravity="0 0 0"/>
          <worldbody><body pos="0 0 1"><freejoint/><geom type="sphere" size=".1"/>
            <body><joint name="hinge"/><geom type="capsule" size=".03 .1"/></body>
          </body></worldbody><actuator><position joint="hinge" kp="10" ctrlrange="-1 1"/></actuator>
          <keyframe><key name="home" qpos="0 0 1 1 0 0 0 0"/></keyframe></mujoco>'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "scene.xml"; path.write_text(xml)
            rt = PhysicsRuntime(path)
            stats = dict(obs_mean=torch.zeros(9), obs_scale=torch.ones(9), goal_mean=torch.zeros(1),
                goal_scale=torch.ones(1), lower=torch.tensor([-1.]), upper=torch.tensor([1.]))
            base = Actor(stats, dict(hidden_width=8, action_delta_rad=.3),
                dict(q_indices=rt.q_indices.tolist(), v_state_indices=(rt.v_indices + rt.model.nq).tolist(), nq=rt.model.nq))
            actor = TemporalActor(base, 10, 10, 8)
            with torch.no_grad():
                actor.adapter[-1].weight.uniform_(-.1, .1)
            model = SimpleNamespace(state_mean=torch.zeros(rt.model.nq + rt.model.nv),
                state_scale=torch.ones(rt.model.nq + rt.model.nv), context_mean=torch.zeros(2), context_scale=torch.ones(2))
            config = dict(raw_action_std=.05, duration_s=.2, gamma=.9, target_height_m=1.,
                fall_height_m=.35, fall_upright_z=.5, collect_seed_base=5600, critic_width=8)
            value = make_value(model, actor, config)
            collection = dict(cases=[dict(id="toy", family="train-fixture", split="train", motion="stand", keyframe="home", friction=1)])
            batch = collect(rt, actor, value, collection, config, 0, 0, torch.Generator().manual_seed(3))
            torch.testing.assert_close(mean_latent(actor, batch["points"]), batch["old_mean"], atol=1e-6, rtol=1e-6)
            expected = actor.base.action_from_latent(batch["latent"], batch["points"][2][:, 0])
            actual = torch.tensor([s["applied_action"] for s in batch["episodes"][0]["steps"]])
            torch.testing.assert_close(actual, expected)
            torch.testing.assert_close(batch["points"][1][1:, -1, -1], actual[:-1, 0])
            self.assertGreater(float((batch["latent"] - batch["old_mean"]).abs().max()), 0)
            torch.testing.assert_close(batch["old_log_prob"], Normal(batch["old_mean"], .05).log_prob(batch["latent"]).sum(-1))
            self.assertEqual(len(batch["target"]), 10)
            self.assertTrue(batch["episodes"][0]["steps"][-1]["truncated"])


if __name__ == "__main__":
    unittest.main()
