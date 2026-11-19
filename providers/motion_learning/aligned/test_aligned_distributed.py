"""CPU-only regression for checkpoint agreement before NCCL resume."""

from types import SimpleNamespace
import unittest
from unittest.mock import patch

import torch

from . import distributed


class CheckpointAgreementTest(unittest.TestCase):
    def signature(self, state):
        signatures = []

        def gather(output, value):
            signatures.append(value)
            output[:] = [value, value]

        with patch.object(distributed.dist, "is_initialized", return_value=True), \
                patch.object(distributed.dist, "get_world_size", return_value=2), \
                patch.object(distributed.dist, "all_gather_object", side_effect=gather):
            distributed.assert_same_learner(SimpleNamespace(state_dict=lambda: state))
        return signatures[0]

    def test_scalar_normalizer_and_optimizer_state_can_be_hashed(self):
        state = {"norm": {"count": torch.tensor(128.)},
                 "adam": {"step": torch.tensor(3.),
                          "exp_avg": torch.arange(6.).reshape(2, 3)},
                 "bf16": torch.tensor([1., 2.], dtype=torch.bfloat16)}
        signature = self.signature(state)
        self.assertEqual(signature, self.signature(state))
        changed = {**state, "norm": {"count": torch.tensor(129.)}}
        self.assertNotEqual(signature, self.signature(changed))
        reshaped = {**state, "norm": {"count": torch.tensor([128.])}}
        self.assertNotEqual(signature, self.signature(reshaped))

    def test_disagreement_is_rejected(self):
        def gather(output, value):
            output[:] = [value, "other-rank-checkpoint"]

        with patch.object(distributed.dist, "is_initialized", return_value=True), \
                patch.object(distributed.dist, "get_world_size", return_value=2), \
                patch.object(distributed.dist, "all_gather_object", side_effect=gather):
            with self.assertRaisesRegex(ValueError, "different learner or optimizer"):
                distributed.assert_same_learner(SimpleNamespace(
                    state_dict=lambda: {"count": torch.tensor(1.)}))


if __name__ == "__main__":
    unittest.main()
