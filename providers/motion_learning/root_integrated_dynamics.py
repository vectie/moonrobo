"""G1 diagnostic variant: integrate root translation from endpoint world velocities.

Joint positions and root orientation retain the existing learned residuals.
Trapezoidal integration approximates substep physics; it is not an exact law.
"""
import torch

from dynamics import ResidualDynamics


class RootIntegratedDynamics(ResidualDynamics):
    def __init__(self, stats, width, dt):
        super().__init__(stats, width, horizontal_translation_invariant=True)
        if len(self.state_mean) != 71 or dt <= 0:
            raise ValueError("this diagnostic targets the G1 36-qpos/35-qvel layout")
        self.dt = dt

    def forward(self, state, action, context):
        predicted = super().forward(state, action, context)
        position = state[..., :3] + .5*self.dt*(state[..., 36:39]+predicted[..., 36:39])
        return torch.cat((position, predicted[..., 3:]), -1)


def load_root_integrated(path):
    checkpoint = torch.load(path, weights_only=True)
    if checkpoint["format"] != "moonrobo.g1-root-integrated-dynamics.v1":
        raise ValueError("expected explicit root-integrated dynamics format")
    stats = {key: value for key, value in checkpoint["model"].items() if key.endswith(("_mean", "_scale"))}
    model = RootIntegratedDynamics(stats, checkpoint["width"], checkpoint["dt_s"])
    model.load_state_dict(checkpoint["model"]); model.eval()
    return model, checkpoint
