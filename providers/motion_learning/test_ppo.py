import unittest

import torch

from ppo import physical_gae


class PhysicalGAETest(unittest.TestCase):
    def test_fall_removes_bootstrap(self):
        advantage, target = physical_gae(torch.tensor([1., 2.]), torch.tensor([3., 4.]),
                                          torch.tensor([4., 500.]), torch.tensor([0., 1.]),
                                          torch.tensor([0., 0.]), .9, 1.)
        torch.testing.assert_close(advantage, torch.tensor([-.2, -2.]))
        torch.testing.assert_close(target, torch.tensor([2.8, 2.]))

    def test_time_limit_bootstraps_without_leaking_next_episode(self):
        _, target = physical_gae(torch.tensor([1., 100.]), torch.zeros(2),
                                 torch.tensor([5., 0.]), torch.tensor([0., 1.]),
                                 torch.tensor([1., 0.]), .9, 1.)
        torch.testing.assert_close(target, torch.tensor([5.5, 100.]))


if __name__ == "__main__":
    unittest.main()
