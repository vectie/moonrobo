"""Actual MuJoCo checks of the smc simulator protocol, without a GPU parity claim."""
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np
import torch

from .kinematics import G1Kinematics
from .motion import MotionLib
from .mdp import MDP
from .mujoco_env import MujocoTrackingEnv
from .robot import default_joint_pos_list, G1_JOINT_NAMES, motor_of, _kp, _kd

ROOT = Path(__file__).resolve().parents[3]
DATA = ROOT/'target/learning/g1-aligned-data'
SCENE = DATA/'g1_description/scene.xml'


class PhysicsProtocolTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not SCENE.exists():
            raise unittest.SkipTest('prepare the real LAFAN1/G1 assets first')
        cls.temp = tempfile.TemporaryDirectory()
        clip = Path(cls.temp.name)/'real-fragment.csv'
        # A real reference fragment used only as a unit-test fixture.
        np.savetxt(clip, np.loadtxt(DATA/'lafan1_g1/dance1_subject1.csv', delimiter=',', max_rows=128), delimiter=',')
        cls.kin = G1Kinematics('cpu', mjcf_path=str(SCENE))
        cls.motion = MotionLib([str(clip)], cls.kin, 'cpu')
        cls.mdp = MDP(cls.kin, cls.motion, torch.tensor(default_joint_pos_list()), observation_mode='smc')

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, 'temp'):
            cls.temp.cleanup()

    def make(self, mode='environment', **kwargs):
        return MujocoTrackingEnv(SCENE, 2, self.motion, self.mdp, context_resampling=mode,
                                self_collisions=False, reset_noise=False, **kwargs)

    def test_four_substeps_and_original_motor_constants(self):
        env = self.make(auto_reset=False)
        env.reset(frames=torch.tensor([0, 0]))
        for m in env.models:
            self.assertEqual(m.opt.timestep, .005)
            for aid, name in zip(env.aids, G1_JOINT_NAMES):
                effort, _, arm = motor_of(name)
                self.assertEqual(m.actuator_gainprm[aid, 0], _kp(arm))
                self.assertEqual(m.actuator_biasprm[aid, 2], -_kd(arm))
                np.testing.assert_array_equal(m.actuator_forcerange[aid], [-effort, effort])
        env.step(torch.zeros(2, 29))
        self.assertEqual(env.substeps, 4)
        self.assertAlmostEqual(env.datas[0].time, .02, places=14)
        self.assertEqual(env.evaluation_settings['physics_substeps'], 4)

    def test_smc_context_is_fixed_per_environment_but_calibration_resets(self):
        env = self.make()
        before = env.xi.clone()
        env.reset(frames=torch.tensor([0, 0]))
        torch.testing.assert_close(before[:, [0, 30, 31, 32]], env.xi[:, [0, 30, 31, 32]], rtol=0, atol=0)
        self.assertFalse(torch.equal(before[:, 1:30], env.xi[:, 1:30]))
        for idx, m in enumerate(env.models):
            np.testing.assert_allclose(m.body_ipos[env.torso], env.base_com[idx]+env.xi[idx, 30:33].numpy())
            np.testing.assert_allclose(m.geom_friction[m.geom_bodyid == 0, 0], .3)

    def test_episode_context_resamples_selected_environment_only(self):
        env = self.make('episode')
        before = env.xi.clone()
        env.reset(ids=torch.tensor([0]), frames=torch.tensor([0]))
        torch.testing.assert_close(before[1], env.xi[1], rtol=0, atol=0)
        self.assertFalse(torch.equal(before[0, [0, 30, 31, 32]], env.xi[0, [0, 30, 31, 32]]))

    def test_profiles_separate_paper_from_smc_and_experimental_observations(self):
        paper = json.loads((ROOT/'examples/learning/g1-aligned-scale.json').read_text())
        smc = json.loads((ROOT/'examples/learning/g1-smc-scale.json').read_text())
        self.assertEqual((paper['observation_mode'], paper['wm_only_iters']), ('paper', 0))
        self.assertEqual((smc['observation_mode'], smc['wm_only_iters']), ('smc', 500))
        self.assertEqual(smc['context_resampling'], 'environment')
        self.assertFalse(smc['self_collisions'])
        self.assertEqual(smc['amp'], 'bf16')
        for config in (paper, smc):
            self.assertEqual(config['physics_dt'], .005)
            self.assertEqual(config['wm_hidden'], [2048]*3)
            self.assertEqual(config['horizon'], 32)


if __name__ == '__main__':
    unittest.main()
