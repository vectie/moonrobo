"""Reference-only inputs, relative feedback, causal runner and checkpoint tests."""
from pathlib import Path
import tempfile
import unittest

import numpy as np
import torch

from balance_features import BalanceKinematics, make_spec
from cpu_physics import PhysicsRuntime
from full_body_reference import FullBodyReference, capture_frame, layout_for
from reference_actor import ReferenceActor, ReferenceRunner, load_reference_actor, save_reference_actor
from reference_initialization import prediction, training_points


class ReferenceActorTest(unittest.TestCase):
    def setUp(self):
        scene = Path(__file__).resolve().parents[2]/"target/mujoco_menagerie/unitree_g1/scene_mjx.xml"
        self.rt = PhysicsRuntime(scene)
        case = dict(id="stand", family="procedural-stand", motion="stand", keyframe="home", split="train", friction=1.)
        frames = []
        episode, _ = self.rt.rollout(case, 41, "position", .4,
            trace_callback=lambda rt, i, action, goal: frames.append(capture_frame(rt)))
        frames.append(capture_frame(self.rt))
        arrays = {key: np.stack([f[key] for f in frames]) for key in frames[0]}
        arrays.update(source_setpoint=np.asarray([s["applied_action"] for s in episode["steps"]]),
            observation=np.asarray([s["observation"] for s in episode["steps"]]))
        self.ref = FullBodyReference(arrays, layout_for(self.rt))
        self.spec = make_spec(self.rt.model)
        self.geometry = BalanceKinematics(self.spec)
        indices = [self.rt.names.index(side+"_ankle_"+axis+"_joint") for side in ["left", "right"] for axis in ["pitch", "roll"]]
        self.actor = ReferenceActor(len(self.ref.goals[0]), 29, *self.rt.model.actuator_ctrlrange.T,
            [[16, 32, -.02, 1, .25], [-16, -32, -.02, 1, .25]]*2, indices)
        self.points = training_points([({}, self.ref)], 10, 10)

    def test_causal_runner_matches_supervised_inputs_and_round_trip(self):
        with torch.no_grad():
            self.actor.decoder[-1].weight.normal_(0, .002)
            self.actor.decoder[0].weight[:, self.actor.latent_dim:].zero_()
        expected = prediction(self.actor, self.points, torch.arange(self.ref.steps)).detach().numpy()
        runner = ReferenceRunner(self.actor, self.geometry, self.rt.dt)
        actual = np.asarray([runner(self.ref.arrays["observation"][i], self.ref.goals[i], *self.ref.preview(i, 10))
            for i in range(self.ref.steps)])
        np.testing.assert_allclose(actual, expected, atol=1e-7, rtol=1e-6)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"actor.pt"
            save_reference_actor(path, self.actor, self.spec, self.rt.dt, dict(test=True))
            restored, _, metadata = load_reference_actor(path)
            torch.testing.assert_close(prediction(restored, self.points, torch.arange(self.ref.steps)),
                torch.tensor(expected), atol=0, rtol=0)
            self.assertFalse(metadata["physical_execution_allowed"])
            prediction(restored, self.points, torch.arange(self.ref.steps)).sum().backward()
            self.assertGreater(float(restored.decoder[0].weight.grad[:, restored.latent_dim:].abs().max()), 0)
        # Changing archived teacher controls changes labels but not model inputs.
        changed = {**self.ref.arrays, "source_setpoint": self.ref.arrays["source_setpoint"]+.1}
        other = training_points([({}, FullBodyReference(changed, self.ref.layout))], 10, 10)
        for name in ["history", "current", "future", "valid"]:
            torch.testing.assert_close(other[name], self.points[name], atol=0, rtol=0)

    def test_feedback_is_relative_and_preserves_input_gradients(self):
        rows = torch.tensor([0])
        baseline = prediction(self.actor, self.points, rows)
        actual = torch.tensor([[.001, 0., 0., 0., 0., 0.]], requires_grad=True)
        action = self.actor(self.points["history"][rows], self.points["current"][rows],
            self.points["future"][rows], self.points["valid"][rows], actual, torch.zeros(1, 6))
        difference = (action-baseline)[0, self.actor.indices]
        torch.testing.assert_close(difference, torch.tensor([.016, 0., .016, 0.]), atol=1e-7, rtol=1e-6)
        action.sum().backward()
        self.assertTrue(torch.isfinite(actual.grad).all())
        self.assertGreater(float(actual.grad.abs().sum()), 0)
        self.assertIsNone(self.actor.feedback_coefficients.grad)


if __name__ == "__main__":
    unittest.main()
