"""Teacher labels must never masquerade as actual student controls."""
import unittest
from unittest.mock import patch

import numpy as np
import torch

from dataset_aggregation import collect_labels


class AggregationTest(unittest.TestCase):
    def test_labels_are_separate_and_heldout_cases_are_not_collected(self):
        class Student(torch.nn.Module):
            def forward(self, obs, goal):
                return torch.ones(len(obs), 1)
        class Teacher:
            def __init__(self, runtime, config):
                pass
            def __call__(self, obs, goal):
                return np.array([2.])
        class Runtime:
            def rollout(self, case, seed, controller, duration, height, upright, policy):
                self_case = case["id"]
                if self_case != "training":
                    raise AssertionError("held-out case reached collector")
                steps = []
                for i in range(2):
                    obs, goal = [float(i)], np.array([0.])
                    action = policy(obs, goal)
                    steps.append(dict(observation=obs, goal=goal.tolist(), applied_action=action.tolist()))
                return dict(id=str(seed), split="train", steps=steps), {}
        experiment = dict(duration_s=1, fall_height_m=.35, fall_upright_z=.5,
            cases=[dict(id="training", split="train"), dict(id="heldout", split="validation")])
        with patch("dataset_aggregation.teacher_feedback.BalanceTeacher", Teacher):
            episodes, labels, tensors = collect_labels(Runtime(), Student(), experiment, {}, [1, 2])
        self.assertEqual(len(episodes), 2)
        self.assertEqual(labels, [[2.], [2.], [2.], [2.]])
        self.assertEqual([s["applied_action"] for e in episodes for s in e["steps"]], [[1.]] * 4)
        self.assertEqual(tensors[0].flatten().tolist(), [0., 1., 0., 1.])
        self.assertEqual(tensors[2].flatten().tolist(), [2.] * 4)


if __name__ == "__main__":
    unittest.main()
