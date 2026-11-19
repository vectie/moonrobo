"""Physical snapshot and first-control gradient checks for action-response data."""
from pathlib import Path
import unittest

import numpy as np
import torch

from balance_features import BalanceKinematics, make_spec
from cpu_physics import PhysicsRuntime
from dynamics import ResidualDynamics
from full_body_reference import FullBodyReference, capture_frame, layout_for
from reference_action_response import feasible_direction, first_action_tape, physics_branch, reward_targets, tape_objective


class ReferenceActionResponseTest(unittest.TestCase):
    def setUp(self):
        self.runtime = PhysicsRuntime(Path(__file__).resolve().parents[2]/"target/mujoco_menagerie/unitree_g1/scene_mjx.xml")
        self.geometry = BalanceKinematics(make_spec(self.runtime.model)).double()
        self.case = dict(id="stand", family="stand", split="train", keyframe="home", motion="stand", friction=1.)
        frames = []
        episode, _ = self.runtime.rollout(self.case, 77, "position", .4,
            trace_callback=lambda runtime, i, action, goal: frames.append(capture_frame(runtime)))
        frames.append(capture_frame(self.runtime))
        arrays = {k: np.stack([f[k] for f in frames]) for k in frames[0]}
        arrays.update(source_setpoint=np.asarray([s["applied_action"] for s in episode["steps"]]),
            observation=np.asarray([s["observation"] for s in episode["steps"]]))
        self.reference = FullBodyReference(arrays, layout_for(self.runtime))
        self.snapshot = dict(integration=arrays["integration"][0], state=arrays["state"][0],
            observation=arrays["observation"][0], actions=arrays["source_setpoint"][:8], context=np.asarray([1., 1.]))
        self.targets = reward_targets(self.reference, 0, 8)

    def test_only_first_action_changes_and_clipping_matches_runtime(self):
        limits = self.runtime.model.actuator_ctrlrange.copy()
        actions = self.snapshot["actions"].copy()
        result = first_action_tape(actions, np.ones(29), 100., limits)
        np.testing.assert_array_equal(result[1:], actions[1:])
        np.testing.assert_array_equal(result[0], self.runtime.clip_control(actions[0]+100.))
        np.testing.assert_array_equal(actions, self.snapshot["actions"])

    def test_gradient_direction_excludes_saturated_coordinates_for_both_amplitudes(self):
        limits = np.tile([-1., 1.], (29, 1))
        action = np.zeros(29)
        action[:2] = [-1., .999]
        direction, _, count = feasible_direction(torch.ones(29, dtype=torch.float64), action, limits, .001)
        self.assertEqual(count, 27)
        np.testing.assert_array_equal(direction[:2], np.zeros(2))
        self.assertAlmostEqual(float(np.mean(direction**2)), 1.)
        for amplitude in [-.001, -.0001, .0001, .001]:
            np.testing.assert_array_equal(first_action_tape(action[None], direction, amplitude, limits)[0], action+amplitude*direction)

    def test_full_solver_restore_gives_identical_physics_after_other_branch(self):
        baseline = physics_branch(self.runtime, self.snapshot, self.snapshot["actions"], self.targets, self.geometry)
        actions = first_action_tape(self.snapshot["actions"], np.ones(29), .001, self.runtime.model.actuator_ctrlrange)
        physics_branch(self.runtime, self.snapshot, actions, self.targets, self.geometry)
        repeated = physics_branch(self.runtime, self.snapshot, self.snapshot["actions"], self.targets, self.geometry)
        for key in baseline:
            np.testing.assert_array_equal(baseline[key], repeated[key])
        self.assertTrue(baseline["truncated"][-1])
        self.assertFalse(baseline["terminated"].any())

    def test_first_action_autograd_matches_model_finite_difference(self):
        stats = {name+suffix: value for name, n in [("state", 71), ("action", 29), ("context", 2)]
            for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        torch.manual_seed(179)
        model = ResidualDynamics(stats, 16, True).double()
        with torch.no_grad(): model.net[-1].weight.normal_(0, .0001)
        for p in model.parameters(): p.requires_grad_(False)
        action = torch.from_numpy(self.snapshot["actions"][0].copy()).requires_grad_(True)
        result = tape_objective(model, self.geometry, self.snapshot, self.targets, 8, action, .99)
        gradient, = torch.autograd.grad(result, action)
        direction = torch.linspace(-1., 1., 29, dtype=torch.float64)
        epsilon = 1e-6
        with torch.no_grad():
            plus = tape_objective(model, self.geometry, self.snapshot, self.targets, 8, action+epsilon*direction, .99)
            minus = tape_objective(model, self.geometry, self.snapshot, self.targets, 8, action-epsilon*direction, .99)
        self.assertTrue(torch.isfinite(gradient).all())
        self.assertGreater(float(gradient.norm()), 0.)
        self.assertAlmostEqual(float((gradient*direction).sum()), float((plus-minus)/(2*epsilon)), places=6)


if __name__ == "__main__":
    unittest.main()
