"""Root integration must connect policy actions to velocity and preserve frames."""
import io
import unittest

import torch

from dynamics import imagine
from root_integrated_dynamics import RootIntegratedDynamics, load_root_integrated


class RootIntegratedTest(unittest.TestCase):
    def test_world_translation_velocity_gradient_and_checkpoint_roundtrip(self):
        torch.manual_seed(82)
        stats = {name+suffix: value for name, n in [("state", 71), ("action", 29), ("context", 2)]
            for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        model = RootIntegratedDynamics(stats, 16, .02).double()
        torch.nn.init.uniform_(model.net[-1].weight, -.1, .1)
        state = torch.zeros(2, 71, dtype=torch.float64); state[:, 3] = 1
        state[:, 36:39] = torch.tensor([.1, -.2, .05])
        action = torch.zeros(2, 8, 29, dtype=torch.float64, requires_grad=True)
        context = torch.ones(2, 2, dtype=torch.float64)
        next_state = model(state, action[:, 0], context)
        torch.testing.assert_close(next_state[:, :3]-state[:, :3],
            .01*(state[:, 36:39]+next_state[:, 36:39]), atol=1e-12, rtol=1e-12)
        shift = torch.zeros_like(state); shift[:, :2] = torch.tensor([2., -3.])
        rolled = imagine(model, state, action, context)
        torch.testing.assert_close(imagine(model, state+shift, action, context)-shift[:, None], rolled)
        grad, = torch.autograd.grad(rolled[:, -1, :3].sum(), action)
        self.assertTrue(torch.isfinite(grad).all()); self.assertGreater(float(grad.norm()), 0)
        checkpoint = io.BytesIO()
        torch.save(dict(format="moonrobo.g1-root-integrated-dynamics.v1", model=model.state_dict(), width=16, dt_s=.02), checkpoint)
        checkpoint.seek(0); restored, _ = load_root_integrated(checkpoint)
        torch.testing.assert_close(imagine(restored.double(), state, action, context), rolled)


if __name__ == "__main__": unittest.main()
