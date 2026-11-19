"""Uncensored training recovers a planted feedback law, including saturated labels."""
import unittest

import torch

from learned_balance import LearnedAnkleHead


class LearnedBalanceTest(unittest.TestCase):
    def test_fit_recovers_coefficients_without_treating_clipped_labels_as_linear_residuals(self):
        names = [side + "_ankle_" + axis + "_joint" for side in ["left", "right"] for axis in ["pitch", "roll"]]
        head = LearnedAnkleHead(names, [-.4]*4, [.4]*4)
        generator = torch.Generator().manual_seed(17)
        x = torch.randn(2000, 4, 3, generator=generator)
        planted = torch.tensor([[.12, -.09, .04, .1], [-.08, .2, -.05, -.03],
                                [.04, -.06, .13, .02], [.19, .08, -.07, -.12]])
        goal = .15 * torch.randn(2000, 4, generator=generator)
        residual = (x * planted[:, :3]).sum(-1) + planted[:, 3]
        target = (goal + residual.clamp(-.3, .3)).clamp(-.4, .4)
        report = head.fit(x, goal, target)
        self.assertTrue(all(4 < row["uncensored_points"] < len(x) for row in report["joints"]))
        torch.testing.assert_close(torch.tensor(report["raw_coefficients"]), planted, atol=2e-7, rtol=1e-6)
        actual = (goal + head.residual(x).clamp(-.3, .3)).clamp(-.4, .4)
        torch.testing.assert_close(actual, target, atol=2e-7, rtol=1e-6)


if __name__ == "__main__":
    unittest.main()
