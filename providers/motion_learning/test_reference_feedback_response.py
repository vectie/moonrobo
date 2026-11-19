"""Check complete-tape derivatives and the restored feedback controller path."""
from pathlib import Path
import unittest

import numpy as np
import torch

from balance_features import BalanceKinematics, make_spec, sequence_features
from cpu_physics import PhysicsRuntime
from dynamics import ResidualDynamics
from full_body_reference import FullBodyReference, capture_frame, layout_for
from reference_action_response import reward_targets
from reference_actor import ReferenceActor
from reference_feedback_response import control_direction, double_schedule, feedback_physics, model_rollout
from reference_learning import imagined_objective


class ReferenceFeedbackResponseTest(unittest.TestCase):
    def setUp(self):
        self.runtime = PhysicsRuntime(Path(__file__).resolve().parents[2]/"target/mujoco_menagerie/unitree_g1/scene_mjx.xml")
        self.geometry = BalanceKinematics(make_spec(self.runtime.model)).double()
        case = dict(id="stand", family="stand", split="train", keyframe="home", motion="stand", friction=1.)
        frames = []
        episode, _ = self.runtime.rollout(case, 77, "position", .4,
            trace_callback=lambda runtime, i, action, goal: frames.append(capture_frame(runtime)))
        frames.append(capture_frame(self.runtime))
        arrays = {k: np.stack([f[k] for f in frames]) for k in frames[0]}
        arrays.update(source_setpoint=np.asarray([s["applied_action"] for s in episode["steps"]]),
            observation=np.asarray([s["observation"] for s in episode["steps"]]))
        reference = FullBodyReference(arrays, layout_for(self.runtime))
        references = [(dict(id="stand"), reference)]
        self.schedule = double_schedule(references, self.geometry)
        self.actor = ReferenceActor(338, 29, *self.runtime.model.actuator_ctrlrange.T,
            torch.zeros(4, 5), [4, 5, 10, 11], history_length=3, future_length=2, width=16, latent_dim=8).double()
        obs = torch.from_numpy(arrays["observation"][:1])
        features = sequence_features(self.geometry, obs, .02, window=None)
        self.inputs = dict(integration=arrays["integration"][0], state=arrays["state"][0], observation=arrays["observation"][0],
            actions=arrays["source_setpoint"][:4], context=np.asarray([1., 1.]), history=np.repeat(obs.numpy()[None], 3, axis=1),
            actual_features=features.numpy(), reference_features=self.schedule.features(torch.tensor([0]), torch.tensor([0]), torch.tensor([0])).numpy(),
            clip=np.asarray(0), phase=np.asarray(0))
        stats = {name+suffix: value for name, n in [("state", 71), ("action", 29), ("context", 2)]
            for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        torch.manual_seed(179)
        self.model = ResidualDynamics(stats, 16, True).double()
        with torch.no_grad(): self.model.net[-1].weight.normal_(0, .0001)
        for module in [self.actor, self.model]:
            for p in module.parameters(): p.requires_grad_(False)
        self.targets = reward_targets(reference, 0, 4)
        self.limits = self.runtime.model.actuator_ctrlrange.copy()

    def test_zero_feedback_perturbation_matches_existing_training_imagination(self):
        zero = torch.zeros(4, 29, dtype=torch.float64)
        actual = model_rollout(self.model, self.actor, self.geometry, self.schedule, self.inputs,
            self.targets, zero, "feedback", self.limits, .99)[0]
        clips, phases = torch.tensor([0]), torch.tensor([0])
        current, future, valid = self.schedule.command(clips, phases, self.actor.future_length)
        batch = dict(state=torch.from_numpy(self.inputs["state"])[None], history=torch.from_numpy(self.inputs["history"]),
            actual_features=torch.from_numpy(self.inputs["actual_features"]), reference_features=torch.from_numpy(self.inputs["reference_features"]),
            context=torch.ones(1, 2, dtype=torch.float64), clip=clips, step=phases, origin=phases, remaining=torch.tensor([20]),
            current=current, future=future, valid=valid)
        expected = imagined_objective(self.model, self.actor, None, batch, self.geometry, self.schedule,
            dict(imagination_horizon=4, gamma=.99, actor_critic_tail=False))[0]
        # The existing trainer multiplies discounts by a float32 alive tensor;
        # this explicitly float64 diagnostic avoids that scalar rounding.
        torch.testing.assert_close(actual, expected, atol=0., rtol=torch.finfo(torch.float32).eps)

    def test_complete_tape_gradients_match_finite_differences_in_both_modes(self):
        for mode in ["open-tape", "feedback"]:
            perturbation = torch.zeros(4, 29, dtype=torch.float64, requires_grad=True)
            result, _, _ = model_rollout(self.model, self.actor, self.geometry, self.schedule, self.inputs,
                self.targets, perturbation, mode, self.limits, .99)
            gradient, = torch.autograd.grad(result, perturbation)
            direction = torch.linspace(-1., 1., 116, dtype=torch.float64).reshape(4, 29)
            epsilon = 1e-6
            with torch.no_grad():
                plus = model_rollout(self.model, self.actor, self.geometry, self.schedule, self.inputs,
                    self.targets, epsilon*direction, mode, self.limits, .99)[0]
                minus = model_rollout(self.model, self.actor, self.geometry, self.schedule, self.inputs,
                    self.targets, -epsilon*direction, mode, self.limits, .99)[0]
            self.assertTrue(torch.isfinite(gradient).all())
            self.assertGreater(float(gradient[1:].abs().sum()), 0.)
            self.assertAlmostEqual(float((gradient*direction).sum()), float((plus-minus)/(2*epsilon)), places=6)

    def test_common_mask_checks_all_baselines_and_normalizes_the_whole_tape(self):
        limits = np.tile([-1., 1.], (29, 1))
        original = np.zeros((2, 29)); other = original.copy()
        original[0, 0] = 1.; other[1, 1] = -.999
        direction, count = control_direction(torch.ones(2, 29, dtype=torch.float64), [original, other], limits, .001)
        self.assertEqual(count, 56)
        self.assertEqual(direction[0, 0], 0.)
        self.assertEqual(direction[1, 1], 0.)
        self.assertAlmostEqual(float(np.mean(direction**2)), 1.)
        for baseline in [original, other]:
            for amplitude in [-.001, .001]:
                target = baseline+amplitude*direction
                np.testing.assert_array_equal(target, np.clip(target, limits[None, :, 0], limits[None, :, 1]))

    def test_feedback_physics_restores_memory_and_solver_after_another_branch(self):
        zero = np.zeros((4, 29))
        baseline = feedback_physics(self.runtime, self.actor, self.geometry, self.schedule, self.inputs, self.targets, zero)
        feedback_physics(self.runtime, self.actor, self.geometry, self.schedule, self.inputs, self.targets, zero+.001)
        repeated = feedback_physics(self.runtime, self.actor, self.geometry, self.schedule, self.inputs, self.targets, zero)
        for key in baseline: np.testing.assert_array_equal(baseline[key], repeated[key])
        self.assertTrue(baseline["truncated"][-1])


if __name__ == "__main__": unittest.main()
