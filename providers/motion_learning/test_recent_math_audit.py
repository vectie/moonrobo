"""Independent mathematical oracles for the October BF16 alignment audit.

CPU only, tiny tensors. Counterexample tests intentionally assert the observed
SMC limitation; passing is evidence of the limitation, not a fix certification.
No simulation, exported package, production parameter, or GPU is modified.
"""
from __future__ import annotations

import ast
import json
import math
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import torch

from .aligned import rotations as stable
from .aligned.learning import lambda_returns
from .aligned.test_smc_learning_differential import SMC, reference_modules


def rz(theta):
    c, s = theta.cos(), theta.sin()
    z, one = theta * 0, theta * 0 + 1
    return torch.stack((c, -s, z, s, c, z, z, z, one)).reshape(3, 3)


class RecentMathAudit(unittest.TestCase):
    evidence = {}

    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)
        cls.original = reference_modules()

    @classmethod
    def tearDownClass(cls):
        print(json.dumps(dict(schema="moonrobo.independent-math-audit.v1",
                             device="cpu", evidence=cls.evidence), sort_keys=True))

    def test_heading_vertical_is_not_a_rotation(self):
        # Exactly valid 90-degree pitch rotation: R^T R=I, determinant=1.
        R = torch.tensor([[0., 0., 1.], [0., 1., 0.], [-1., 0., 0.]], dtype=torch.float64)
        eye = torch.eye(3, dtype=R.dtype)
        torch.testing.assert_close(R.T @ R, eye, rtol=0, atol=0)
        H = self.original["rotations"].yaw_mat(R)
        Hstable = stable.yaw_mat(R)
        torch.testing.assert_close(H, torch.diag(torch.tensor([0., 0., 1.], dtype=R.dtype)))
        torch.testing.assert_close(Hstable.T @ Hstable, eye, rtol=0, atol=0)
        # Original world p_next = p + H @ dp cannot express horizontal motion here.
        dp = torch.tensor([.2, -.3, .1], dtype=R.dtype)
        self.assertEqual((H @ dp)[:2].abs().sum().item(), 0.)
        self.evidence["heading_vertical"] = dict(
            smc_determinant=torch.linalg.det(H).item(),
            smc_orthogonality_max_abs=(H.T @ H-eye).abs().max().item(),
            stable_determinant=torch.linalg.det(Hstable).item(),
            local_delta=dp.tolist(), smc_world_delta=(H@dp).tolist())

    def test_heading_near_vertical_contracts_and_has_large_jacobian(self):
        # At projected forward length sqrt(1e-9), SMC XY norms shrink by sqrt(1/2).
        x = math.sqrt(1e-9)
        R = torch.tensor([[x, 0., math.sqrt(1-x*x)], [0., 1., 0.],
                          [-math.sqrt(1-x*x), 0., x]], dtype=torch.float64, requires_grad=True)
        H = self.original["rotations"].yaw_mat(R)
        grad = torch.autograd.grad(H[1, 0], R)[0]
        self.assertAlmostEqual(torch.linalg.det(H).item(), .5, places=12)
        self.assertGreater(grad.abs().max().item(), 20000)
        self.evidence["heading_near_vertical"] = dict(
            projected_forward_length=x, smc_determinant=torch.linalg.det(H).item(),
            max_abs_input_derivative=grad.abs().max().item())

    def test_geodesic_identity_floor_and_small_angle_dead_zone(self):
        original = self.original["rotations"].rot_angle_sq
        eye = torch.eye(3, dtype=torch.float64)
        theta = torch.tensor(.001, dtype=torch.float64, requires_grad=True)
        loss = original(rz(theta), eye)
        derivative = torch.autograd.grad(loss, theta)[0]
        corrected = stable.rot_angle_sq(rz(theta), eye)
        corrected_derivative = torch.autograd.grad(corrected, theta)[0]
        self.assertGreater(original(eye, eye).item(), 1.9e-6)
        self.assertEqual(derivative.item(), 0.)
        self.assertAlmostEqual(corrected.item(), .001**2, places=12)
        self.assertAlmostEqual(corrected_derivative.item(), .002, places=10)
        self.evidence["rotation_dead_zone"] = dict(
            smc_identity_squared_error=original(eye, eye).item(),
            smc_dead_zone_upper_radians=math.acos(1-1e-6),
            angle_radians=.001, smc_derivative=derivative.item(),
            mathematical_derivative=.002, stable_derivative=corrected_derivative.item())

    def test_rotation_generic_interior_gradient_matches_analytic_and_finite_difference(self):
        theta = torch.tensor(.37, dtype=torch.float64, requires_grad=True)
        eye = torch.eye(3, dtype=torch.float64)
        f = lambda x: self.original["rotations"].rot_angle_sq(rz(x), eye)
        value = f(theta)
        g = torch.autograd.grad(value, theta)[0]
        h = 1e-6
        fd = (f(theta.detach()+h)-f(theta.detach()-h))/(2*h)
        self.assertAlmostEqual(value.item(), .37**2, places=12)
        self.assertAlmostEqual(g.item(), .74, places=11)
        self.assertAlmostEqual(g.item(), fd.item(), places=8)
        self.evidence["rotation_interior"] = dict(value=value.item(), gradient=g.item(),
                                                 finite_difference=fd.item())

    def test_running_population_variance_matches_concatenated_data(self):
        norm = self.original["networks"].RunningNorm(2).double()
        # The implementation deliberately computes batch moments in FP32;
        # simple dyadic inputs allow an independent exact pooled check.
        x = torch.tensor([[1., 2.], [3., 4.], [-1., 6.], [5., 0.]])
        norm.update(x[:2]); norm.update(x[2:])
        torch.testing.assert_close(norm.mean, x.double().mean(0), rtol=0, atol=0)
        torch.testing.assert_close(norm.var, x.double().var(0, correction=0), rtol=0, atol=0)
        self.evidence["running_variance"] = dict(mean=norm.mean.tolist(), variance=norm.var.tolist(),
                                                 count=norm.count.item())

    def test_lambda_returns_matches_independent_advantage_expansion(self):
        r = torch.tensor([[1.], [2.], [-.5]], dtype=torch.float64)
        v = torch.tensor([[.3], [.4], [.6], [.9]], dtype=torch.float64)
        d = torch.tensor([[.2], [.0], [.7]], dtype=torch.float64)
        gamma, lam = .99, .95
        result = lambda_returns(r, v, d, gamma=gamma, lam=lam)
        delta = r + gamma*(1-d)*v[1:] - v[:-1]
        expected = []
        for t in range(3):
            total, weight = v[t].clone(), torch.ones(1, dtype=torch.float64)
            for k in range(t, 3):
                total = total + weight*delta[k]
                weight = weight*gamma*lam*(1-d[k])
            expected.append(total)
        torch.testing.assert_close(result, torch.stack(expected), rtol=1e-13, atol=1e-13)
        self.evidence["gae_independent_expansion"] = dict(max_abs_error=(result-torch.stack(expected)).abs().max().item())

    def test_original_sampler_can_choose_clip_last_frame(self):
        # Execute the original method, including its actual exclusive-end math.
        tree = ast.parse((SMC / "env.py").read_text())
        cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "TrackingSim")
        method = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == "sample_frames")
        namespace = {"torch": torch}
        exec(compile(ast.Module(body=[method], type_ignores=[]), str(SMC / "env.py"), "exec"), namespace)
        # A 51-frame clip creates bins beginning at 0 and 50 in original MotionLib.
        motion = SimpleNamespace(num_bins=2, bin_start=torch.tensor([0, 50]),
                                 clip_end=torch.tensor([50]), bin_clip=torch.tensor([0, 0]))
        env = SimpleNamespace(motion=motion, bin_G=torch.zeros(2), G_max=10.,
                              bin_w_avg=torch.full((2,), .5), device="cpu")
        with patch.object(torch, "multinomial", return_value=torch.tensor([1])):
            f, _ = namespace["sample_frames"](env, 1)
        self.assertEqual(f.item(), 50)
        self.assertGreater((f+1).item(), motion.clip_end[0].item())
        self.evidence["sampler_terminal_only_bin"] = dict(clip_frames=51, sampled_frame=f.item(),
                                                         required_next_frame=(f+1).item(), last_valid_frame=50)

    def test_original_replay_short_resume_rejects_window(self):
        buffer = self.original["buffer"].ReplayBuffer(16, 1, "cpu")
        buffer.size = 2
        with self.assertRaises(RuntimeError):
            buffer.sample_windows(1, 8)
        self.evidence["resume_short_buffer"] = dict(available_rows=2, requested_window=8, raises=True)


if __name__ == "__main__":
    unittest.main()
