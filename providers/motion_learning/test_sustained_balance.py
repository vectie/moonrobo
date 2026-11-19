"""Recover an independent planted pose/rate law and its clipped waist coupling."""
import unittest

import torch

from sustained_balance import SustainedBalanceHead


class SustainedBalanceTest(unittest.TestCase):
    def test_censored_fit_recovers_pose_rate_and_pre_damping_waist_coupling(self):
        names = [side+"_ankle_"+axis+"_joint" for side in ["left", "right"] for axis in ["pitch", "roll"]] + ["waist_pitch_joint"]
        generator = torch.Generator().manual_seed(23)
        count, nu = 4000, len(names)
        obs = torch.zeros(count, 3*nu+6)
        obs[:, nu:2*nu] = .4*torch.randn(count, nu, generator=generator)
        pitch, roll = (.08*torch.randn(count, 2, generator=generator)).unbind(-1)
        obs[:, 2*nu:2*nu+3] = torch.stack((pitch.sin(), -roll.sin()*pitch.cos(), -roll.cos()*pitch.cos()), -1)
        omega = .2*torch.randn(count, 3, generator=generator)
        obs[:, 2*nu+3:2*nu+6] = omega
        features = .015*torch.randn(count, 6, generator=generator)
        goal = .05*torch.randn(count, nu, generator=generator)
        p = 16*features[:, 0] + 32*features[:, 3] + pitch + .25*omega[:, 1] + .2
        r = -16*features[:, 1] - 32*features[:, 4] + roll + .25*omega[:, 0]
        residual = torch.stack((p, r, p, r), -1) - .02*obs[:, nu:nu+4]
        waist = -.25*p.clamp(-.45, .45) - .02*obs[:, nu+4]
        target = torch.cat(((goal[:, :4]+residual.clamp(-.45, .45)).clamp(-.8, .8),
            (goal[:, 4]+waist.clamp(-.45, .45)).clamp(-.8, .8)[:, None]), -1)
        head = SustainedBalanceHead(names, [-.8]*nu, [.8]*nu)
        report = head.fit(obs, goal, target, features)
        planted = torch.tensor([[16, 32, -.02, 1, .25, .2], [-16, -32, -.02, 1, .25, 0],
                                [16, 32, -.02, 1, .25, .2], [-16, -32, -.02, 1, .25, 0]])
        torch.testing.assert_close(torch.tensor(report["raw_coefficients"]), planted, atol=2e-4, rtol=1e-5)
        torch.testing.assert_close(torch.tensor(report["waist"]["raw_coefficients"]), torch.tensor([-.25, -.02, 0]), atol=2e-6, rtol=1e-5)
        torch.testing.assert_close(head(obs, goal, features), target, atol=3e-6, rtol=1e-5)
        reduced = SustainedBalanceHead(names, [-.8]*nu, [.8]*nu, pose_rate=False)
        reduced.fit(obs, goal, target, features)
        self.assertGreater(float((reduced(obs, goal, features)-target).square().mean().detach()), 1e-4)


if __name__ == "__main__":
    unittest.main()
