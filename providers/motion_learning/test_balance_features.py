"""Native FK agreement, derivatives and causal observation-only balance features."""
import json
import unittest

import mujoco
import numpy as np
import torch

from balance_features import (BalanceKinematics, ObservationBalanceHistory, causal_velocity,
    make_spec, observation_transports, sequence_features)


def toy_model():
    return mujoco.MjModel.from_xml_string('''<mujoco><compiler angle="radian"/>
      <worldbody><body name="root" pos="0 0 1"><freejoint/>
        <inertial pos=".01 .02 -.04" mass="2" diaginertia=".1 .1 .1"/>
        <site name="left_foot" pos="0 .1 -.8"/>
        <body name="moving" pos=".2 0 -.1" quat=".98 .1 .02 .12">
          <joint name="hinge" axis="0 1 1" pos=".04 .02 .01" ref=".3"/>
          <inertial pos=".05 -.02 -.1" mass="1" diaginertia=".1 .1 .1"/>
          <site name="right_foot" pos="0 -.1 -.7"/>
          <body name="fixed" pos=".1 .05 .02" quat=".99 .1 0 0">
            <inertial pos=".02 0 0" mass=".2" diaginertia=".01 .01 .01"/>
          </body>
        </body>
      </body></worldbody><actuator><position joint="hinge" kp="10" ctrlrange="-1 1"/></actuator></mujoco>''')


class BalanceFeaturesTest(unittest.TestCase):
    def test_static_geometry_matches_native_with_joint_anchor_reference_and_arbitrary_root(self):
        model = toy_model(); data = mujoco.MjData(model)
        spec = json.loads(json.dumps(make_spec(model)))
        feature = BalanceKinematics(spec, dtype=torch.float64)
        random = np.random.default_rng(21)
        positions, gravity, expected, centers, sites = [], [], [], [], []
        for _ in range(32):
            data.qpos[:3] = random.uniform(-20, 20, 3)
            quaternion = random.normal(size=4); quaternion /= np.linalg.norm(quaternion)
            data.qpos[3:7] = quaternion
            data.qpos[7] = random.uniform(-.4, .7)
            mujoco.mj_forward(model, data)
            rotation = data.xmat[1].reshape(3, 3)
            feet = data.site_xpos[[model.site("left_foot").id, model.site("right_foot").id]]
            difference = data.subtree_com[1] - feet.mean(0); difference[2] = 0
            positions.append([data.qpos[7]]); gravity.append(-rotation[2].copy())
            expected.append(rotation.T @ difference)
            centers.append(rotation.T @ (data.subtree_com[1] - data.xpos[1]))
            sites.append((feet - data.xpos[1]) @ rotation)
        q, g = torch.tensor(positions, dtype=torch.float64), torch.tensor(np.asarray(gravity), dtype=torch.float64)
        com, feet = feature.geometry(q)
        np.testing.assert_allclose(com.detach(), centers, atol=1e-13, rtol=1e-12)
        np.testing.assert_allclose(feet.detach(), sites, atol=1e-13, rtol=1e-12)
        np.testing.assert_allclose(feature(q, g).detach(), expected, atol=1e-13, rtol=1e-12)
        self.assertTrue(torch.autograd.gradcheck(feature,
            (q[:2].clone().requires_grad_(), g[:2].clone().requires_grad_()), eps=1e-6, atol=1e-6, rtol=1e-4))

    def test_frame_transport_removes_spurious_velocity_for_a_fixed_world_error(self):
        dt, rate, count = .02, .7, 30
        angle = torch.arange(count, dtype=torch.float64) * dt * rate
        e = torch.stack((.03 * angle.cos() + .04 * angle.sin(), -.03 * angle.sin() + .04 * angle.cos(), torch.zeros_like(angle)), -1)
        g = torch.tensor([0., 0., -1.], dtype=torch.float64).expand(count, -1)
        omega = torch.tensor([0., 0., rate], dtype=torch.float64).expand(count, -1)
        for method in ["gyro", "gravity_gyro"]:
            transport = observation_transports(g, omega, dt, method)
            for window in [10, None]:
                velocity = causal_velocity(e, transport, dt, window)
                torch.testing.assert_close(velocity, torch.zeros_like(velocity), atol=2e-15, rtol=0)
        wrong = causal_velocity(e, observation_transports(g, omega, dt, "body_difference"), dt)
        self.assertGreater(float(wrong.abs().max()), .01)
        # Gravity correction recovers pure pitch changes even with zero gyro.
        g = torch.stack((angle.sin(), torch.zeros_like(angle), -angle.cos()), -1)
        transport = observation_transports(g, torch.zeros_like(g), dt, "gravity_gyro")
        torch.testing.assert_close((transport[1:] @ g[:-1, :, None]).squeeze(-1), g[1:], atol=1e-14, rtol=0)

    def test_online_history_equals_offline_prefix_and_has_no_future_dependency(self):
        geometry = BalanceKinematics(make_spec(toy_model()), dtype=torch.float64)
        time = torch.arange(25, dtype=torch.float64)
        obs = torch.zeros(25, 9, dtype=torch.float64)
        obs[:, 0] = .3 + .1 * (.2 * time).sin()
        obs[:, 4] = -1  # nu=1 => gravity at columns 2:5
        obs[:, 7] = .05
        offline = sequence_features(geometry, obs, .02)
        online = ObservationBalanceHistory(geometry, .02)
        actual = torch.stack([online(row) for row in obs])
        torch.testing.assert_close(actual, offline, atol=1e-13, rtol=1e-12)
        torch.testing.assert_close(sequence_features(geometry, obs[:8], .02), offline[:8], atol=1e-13, rtol=1e-12)
        inputs = obs.clone().requires_grad_()
        gradient, = torch.autograd.grad(sequence_features(geometry, inputs, .02)[7].sum(), inputs)
        self.assertTrue(bool(torch.isfinite(gradient).all()))
        self.assertGreater(float(gradient[:8].abs().max()), 0)
        torch.testing.assert_close(gradient[8:], torch.zeros_like(gradient[8:]), atol=0, rtol=0)
        fresh = ObservationBalanceHistory(geometry, .02)
        torch.testing.assert_close(fresh(obs[9])[3:], torch.zeros(3, dtype=torch.float64), atol=0, rtol=0)

    def test_full_observer_matches_offline_with_constant_memory_and_fresh_reset(self):
        geometry = BalanceKinematics(make_spec(toy_model()), dtype=torch.float64)
        time = torch.arange(80, dtype=torch.float64)
        obs = torch.zeros(80, 9, dtype=torch.float64)
        obs[:, 0] = .3 + .1 * (.2 * time).sin()
        angle = .02 * time
        obs[:, 2], obs[:, 4], obs[:, 6] = angle.sin(), -angle.cos(), 1.
        online = ObservationBalanceHistory(geometry, .02, window=None)
        actual = torch.stack([online(row) for row in obs])
        torch.testing.assert_close(actual, sequence_features(geometry, obs, .02, window=None), atol=1e-13, rtol=1e-12)
        self.assertEqual(len(online.frames), 2)
        fresh = ObservationBalanceHistory(geometry, .02, window=None)
        torch.testing.assert_close(fresh(obs[20])[3:], torch.zeros(3, dtype=torch.float64), atol=0, rtol=0)


if __name__ == "__main__":
    unittest.main()
