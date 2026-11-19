"""Independent SO(3), finite-difference and across-step mathematical gates."""
import json
import math
import unittest
import torch
from .aligned.geometry_math import orthonormal_heading, geodesic_angle_squared


def rotation(vector):
    # Independent exact matrix exponential, not the production quaternion code.
    x, y, z = vector.unbind(-1)
    zero = x*0
    K = torch.stack((zero,-z,y,z,zero,-x,-y,x,zero), -1).reshape(vector.shape[:-1]+(3,3))
    return torch.linalg.matrix_exp(K)


class GeometryMathTests(unittest.TestCase):
    evidence = {}

    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    @classmethod
    def tearDownClass(cls):
        print(json.dumps(dict(schema="moonrobo.geometry-math.v1", device="cpu",
                             evidence=cls.evidence), sort_keys=True))

    def test_heading_rotations_and_invertibility_through_full_pitch_and_roll(self):
        worst = 0.
        for axis in (0,1):
            v = torch.zeros(257,3,dtype=torch.float64)
            v[:,axis] = torch.linspace(-2*math.pi,2*math.pi,257,dtype=torch.float64)
            H = orthonormal_heading(rotation(v))
            eye = torch.eye(3,dtype=torch.float64).expand_as(H)
            err = (H.transpose(-1,-2)@H-eye).abs().max().item()
            worst = max(worst,err)
            torch.testing.assert_close(H.transpose(-1,-2)@H,eye,rtol=0,atol=1e-12)
            torch.testing.assert_close(torch.linalg.det(H),torch.ones(257,dtype=torch.float64),rtol=0,atol=1e-12)
            delta = torch.tensor([.2,-.3,.1],dtype=torch.float64).expand(257,3)
            recovered = (H.transpose(-1,-2)@(H@delta[...,None])).squeeze(-1)
            torch.testing.assert_close(recovered,delta,rtol=0,atol=1e-12)
        self.evidence["heading_full_roll_pitch_orthogonality_max_abs"] = worst

    def test_heading_equivariance_and_generic_directional_derivatives(self):
        for values in ((.2,.5,.3),(0.,math.pi/2,0.),(math.pi/2,0.,0.),(.2,math.pi-.01,.1)):
            v = torch.tensor(values,dtype=torch.float64,requires_grad=True)
            self.assertTrue(torch.autograd.gradcheck(lambda t: orthonormal_heading(rotation(t)),(v,),eps=1e-6,atol=2e-6,rtol=2e-5))
            R = rotation(v.detach())
            Z = rotation(torch.tensor([0.,0.,.71],dtype=torch.float64))
            torch.testing.assert_close(orthonormal_heading(Z@R), Z@orthonormal_heading(R),rtol=1e-12,atol=1e-12)
        self.evidence["heading_local_gradcheck_cases"] = 4

    def test_heading_chart_seam_is_explicit_not_claimed_smooth(self):
        # At the seam a deterministic value is defined, not a unique derivative.
        v = torch.tensor([.8,.8,0.],dtype=torch.float64)
        R = rotation(v)
        H = orthonormal_heading(R)
        self.assertTrue(torch.isfinite(H).all())
        torch.testing.assert_close(H.T@H,torch.eye(3,dtype=H.dtype),atol=1e-12,rtol=0)
        self.assertLess(abs((R[0,0]**2+R[1,0]**2-R[0,1]**2-R[1,1]**2).item()),1e-14)
        # Each open chart has the correct local derivative. Crossing the seam
        # has a finite jump, which must not be misreported as a smooth VJP.
        for offset in (-1e-3,1e-3):
            x=(v+torch.tensor([offset,0.,0.],dtype=v.dtype)).requires_grad_()
            self.assertTrue(torch.autograd.gradcheck(lambda t:orthonormal_heading(rotation(t)),(x,),eps=1e-7))
        left=orthonormal_heading(rotation(v+torch.tensor([-1e-7,0.,0.],dtype=v.dtype)))
        right=orthonormal_heading(rotation(v+torch.tensor([1e-7,0.,0.],dtype=v.dtype)))
        self.evidence["heading_chart_jump_max_abs"]=(left-right).abs().max().item()
        self.evidence["heading_seam_contract"] = "forward on exact ties; piecewise derivatives only; no global smoothness claim"

    def test_geodesic_exact_identity_nonzero_small_angle_gradients(self):
        rows = []
        for theta in (0.,1e-8,1e-6,1e-4,.001,.1):
            v = torch.tensor([theta,0.,0.],dtype=torch.float64,requires_grad=True)
            eye = torch.eye(3,dtype=v.dtype)
            loss = geodesic_angle_squared(rotation(v),eye)
            g = torch.autograd.grad(loss,v)[0]
            self.assertAlmostEqual(loss.item(),theta*theta,delta=max(1e-25,theta*theta*1e-11))
            torch.testing.assert_close(g,torch.tensor([2*theta,0.,0.],dtype=v.dtype),atol=1e-13,rtol=1e-10)
            rows.append(dict(angle=theta,loss=loss.item(),gradient=g[0].item()))
        self.evidence["small_angle"] = rows

    def test_geodesic_near_pi_and_cut_locus(self):
        axis = torch.tensor([1.,2.,3.],dtype=torch.float64); axis=axis/axis.norm()
        eye = torch.eye(3,dtype=axis.dtype)
        for t in (math.pi-1e-3,math.pi-1e-6,math.pi+1e-6,math.pi+1e-3):
            theta = torch.tensor(t,dtype=torch.float64,requires_grad=True)
            y = geodesic_angle_squared(rotation(axis*theta),eye)
            g = torch.autograd.grad(y,theta)[0]
            a = t if t<math.pi else 2*math.pi-t
            self.assertAlmostEqual(y.item(),a*a,places=10)
            self.assertAlmostEqual(g.item(),2*a*(1 if t<math.pi else -1),places=8)
        pi = geodesic_angle_squared(rotation(axis*math.pi),eye)
        self.assertAlmostEqual(pi.item(),math.pi**2,places=10)
        self.evidence["pi_contract"] = "principal value pi^2; correct opposite one-sided derivatives; no unique two-sided derivative at pi"

    def test_geodesic_gradcheck_generic_and_series_boundary(self):
        for angle in (1e-5,1.999e-4,2.001e-4,.7,math.pi-1e-3):
            v = torch.tensor([angle,0.,0.],dtype=torch.float64,requires_grad=True)
            eye=torch.eye(3,dtype=v.dtype)
            self.assertTrue(torch.autograd.gradcheck(lambda x: geodesic_angle_squared(rotation(x),eye),(v,),eps=1e-7,atol=2e-6,rtol=2e-5))
        self.evidence["geodesic_gradcheck_cases"] = 5

    def test_32_step_gradient_crosses_vertical_and_inverted_states(self):
        # Analytic expected translation path: yaw=0 for a pure pitch sweep.
        # Actual gradient crosses heading calls at vertical and inverted states.
        theta = torch.tensor(.012,dtype=torch.float64,requires_grad=True)
        # A separate fixed target sequence is essential for finite differences.
        frozen_targets=[(t+1)*math.pi/16 + .012*(t+1)/32+.003 for t in range(32)]
        def actual(parameter):
            p=torch.zeros(3,dtype=parameter.dtype); total=parameter*0
            R=torch.eye(3,dtype=parameter.dtype)
            increment=rotation(torch.stack((parameter*0,parameter/32+math.pi/16,parameter*0)))
            for t in range(32):
                R=R@increment
                p=p+orthonormal_heading(R)@torch.stack((parameter,.3*parameter,.01+parameter*0))
                T=rotation(torch.tensor([0.,frozen_targets[t],0.],dtype=parameter.dtype))
                total=total+p.square().sum()+.1*geodesic_angle_squared(R,T)
            return total
        y=actual(theta); gradient=torch.autograd.grad(y,theta)[0]
        expected=2*1.09*.012*sum((t+1)**2 for t in range(32))-.0006*sum((t+1)/32 for t in range(32))
        h=1e-6; fd=(actual(theta.detach()+h)-actual(theta.detach()-h))/(2*h)
        self.assertAlmostEqual(gradient.item(),expected,places=8)
        self.assertAlmostEqual(gradient.item(),fd.item(),places=7)
        self.evidence["cross_step"] = dict(steps=32,autograd=gradient.item(),analytic=expected,finite_difference=fd.item())

    def test_fp32_large_angle_and_identity_finite(self):
        v=torch.tensor([[0.,0.,0.],[.0001,0.,0.],[0.,math.pi/2,0.],[math.pi,0.,0.],[0.,0.,math.pi-1e-4]],requires_grad=True)
        R=rotation(v); H=orthonormal_heading(R)
        loss=geodesic_angle_squared(R,torch.eye(3).expand_as(R))
        g=torch.autograd.grad(loss.sum()+H.square().sum(),v)[0]
        self.assertTrue(torch.isfinite(g).all());self.assertTrue(torch.isfinite(loss).all())
        self.assertEqual(loss[0].item(),0.)
        self.assertGreater(g[1,0].item(),0.)
        self.evidence["fp32_finite"] = True


if __name__ == "__main__": unittest.main()
