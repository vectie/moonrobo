"""Versioned mathematical alternatives; original SMC modules remain untouched.

Heading is a piecewise coordinate choice, not a globally smooth yaw on SO(3).
Its chart seam is explicitly defined and tested. Geodesic distance is smooth
near identity and has the unavoidable principal-angle cut locus at pi.
"""
from contextlib import contextmanager
import torch
from .rotations import mat_to_quat


def orthonormal_heading(R):
    """Use the longer projected forward/left axis, forward on ties.

    For R in SO(3), max(||forward_xy||^2, ||left_xy||^2) >= 1/2.
    Thus no epsilon distorts the selected rotation; no vertical singularity.
    A chart change can be discontinuous. Derivatives are within-chart only.
    """
    x, y = R[..., 0, 0], R[..., 1, 0]
    lx, ly = R[..., 1, 1], -R[..., 0, 1]
    forward2, left2 = x*x+y*y, lx*lx+ly*ly
    use_left = left2 > forward2
    a, b = torch.where(use_left, lx, x), torch.where(use_left, ly, y)
    n = (a*a+b*b).clamp_min(1e-24).sqrt()
    c, s = a/n, b/n
    z, one = torch.zeros_like(c), torch.ones_like(c)
    return torch.stack((c, -s, z, s, c, z, z, z, one), -1).reshape(R.shape)


def geodesic_angle_squared(A, B):
    """Principal SO(3) angle squared, with an analytic identity limit.

    A normalized relative quaternion has sin(theta/2)^2=u. The series
    4*(u+u^2/3+8u^3/45) avoids sqrt/atan2's unused singular derivative at u=0.
    The general branch has no acos clamp or artificial flat neighborhood.
    """
    q = mat_to_quat(A @ B.transpose(-1, -2))
    u = q[..., 1:].square().sum(-1)
    small = 4*u*(1+u/3+8*u.square()/45)
    regular = 4*torch.atan2(u.clamp_min(1e-12).sqrt(), q[..., 0].abs()).square()
    return torch.where(u < 1e-8, small, regular)


@contextmanager
def corrected_smc_geometry(networks, mdp, rotations, *, reward=True):
    """Scoped in-memory control for export/validation, never edit ../smc.

    Both world fitting and actor/critic must use this context. Using a new
    reward with the old world/critic heading packages is not admitted.
    """
    changes = [(networks, "yaw_mat", orthonormal_heading),
               (mdp, "yaw_mat", orthonormal_heading),
               (rotations, "yaw_mat", orthonormal_heading)]
    if reward:
        changes += [(mdp, "rot_angle_sq", geodesic_angle_squared),
                    (rotations, "rot_angle_sq", geodesic_angle_squared)]
    prior = [(module, name, getattr(module, name)) for module, name, _ in changes]
    try:
        for module, name, function in changes:
            setattr(module, name, function)
        yield
    finally:
        for module, name, function in prior:
            setattr(module, name, function)
