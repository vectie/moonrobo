"""CPU protocol tests; these do not claim to exercise CUDA or Newton physics."""

import sys
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import torch

from .isaac_env import TrackingSim, make_isaac_env, make_sim
from .robot import G1_JOINT_NAMES


class FakeRobot:
    def __init__(self, n):
        pose = torch.zeros(n, 7)
        pose[:, 6] = 1.0
        self.data = SimpleNamespace(**{
            name: SimpleNamespace(torch=value) for name, value in {
                "root_link_pose_w": pose, "root_link_vel_w": torch.zeros(n, 6),
                "joint_pos": torch.zeros(n, 29), "joint_vel": torch.zeros(n, 29),
            }.items()
        })
        self.target = torch.zeros(n, 29)

    def set_joint_position_target_index(self, target, env_ids=None):
        if env_ids is None:
            self.target[:] = target
        else:
            self.target[env_ids] = target

    def write_root_link_pose_to_sim_index(self, root_pose, env_ids):
        self.data.root_link_pose_w.torch[env_ids] = root_pose

    def write_root_link_velocity_to_sim_index(self, root_velocity, env_ids):
        self.data.root_link_vel_w.torch[env_ids] = root_velocity

    def write_joint_position_to_sim_index(self, position, env_ids):
        self.data.joint_pos.torch[env_ids] = position

    def write_joint_velocity_to_sim_index(self, velocity, env_ids):
        self.data.joint_vel.torch[env_ids] = velocity


class FakeMotion:
    clip_end = torch.tensor([4])
    clip_id = torch.zeros(5, dtype=torch.long)
    frame_bin = torch.zeros(5, dtype=torch.long)

    def ref_state(self, frames):
        n = len(frames)
        return (torch.zeros(n, 3), torch.eye(3).expand(n, 3, 3), torch.zeros(n, 3),
                torch.zeros(n, 3), torch.zeros(n, 29), torch.zeros(n, 29))


class FakeSampler:
    def __init__(self):
        self.updates = []
        self.marker = 17

    def sample(self, n):
        return torch.zeros(n, dtype=torch.long), torch.zeros(n, dtype=torch.long)

    def update(self, bins, returns, **kwargs):
        self.updates.append((bins.clone(), returns.clone(), kwargs))

    def state_dict(self):
        return {"marker": self.marker}

    def load_state_dict(self, state):
        self.marker = state["marker"]


def fixture(n=2):
    env = TrackingSim.__new__(TrackingSim)
    env.device, env.N, env.num_envs = "cpu", n, n
    env.gamma = 0.99
    env.self_collisions, env.eval_mode, env.auto_reset, env.reset_noise = True, False, True, False
    env.context_resampling = "environment"
    env.max_episode_steps = 500
    env.usd_path = "/fake/g1.usda"
    env.motion, env.sampler, env.robot = FakeMotion(), FakeSampler(), FakeRobot(n)
    env.mdp = SimpleNamespace(
        kin=SimpleNamespace(q_lo=torch.full((29,), -3.), q_hi=torch.full((29,), 3.)),
        reward=lambda s, f, a, prev, terms=False: (torch.full((n,), .1), {}) if terms else torch.full((n,), .1),
        termination=lambda s, f: torch.zeros(n, dtype=torch.bool),
    )
    env.scene = SimpleNamespace(env_origins=torch.zeros(n, 3), reset=Mock(), update=Mock(), write_data_to_sim=Mock())
    env.sim = SimpleNamespace(step=Mock(), forward=Mock())
    env._setup_friction, env._apply_context = Mock(), Mock()
    env.default_q, env.alpha = torch.full((29,), .2), torch.full((29,), .3)
    env.xi = torch.zeros(n, 33)
    env.xi[:, 0] = .7
    env.xi[:, 1:30] = .01
    env.f, env.ep_step, env.start_bin = (torch.zeros(n, dtype=torch.long) for _ in range(3))
    env.a_prev = torch.zeros(n, 29)
    env.ep_disc_ret, env.ep_ret = torch.zeros(n), torch.zeros(n)
    env.done_eval, env.failed_eval = torch.zeros(n, dtype=torch.bool), torch.zeros(n, dtype=torch.bool)
    return env


class IsaacProtocolTest(unittest.TestCase):
    def test_pinned_physics_config_uses_four_five_millisecond_solver_steps(self):
        sim_module = SimpleNamespace(SimulationCfg=SimpleNamespace)
        with patch.dict(sys.modules, {
            "isaaclab": SimpleNamespace(sim=sim_module), "isaaclab.sim": sim_module,
            "isaaclab_newton": SimpleNamespace(),
            "isaaclab_newton.physics": SimpleNamespace(MJWarpSolverCfg=SimpleNamespace, NewtonCfg=SimpleNamespace),
        }):
            config = make_sim("cuda:0")
        self.assertEqual(config.dt, .02)
        self.assertEqual(config.physics.num_substeps, 4)
        self.assertEqual(config.dt / config.physics.num_substeps, .005)
        self.assertEqual(config.physics.solver_cfg.integrator, "implicitfast")
        self.assertEqual(config.physics.solver_cfg.cone, "pyramidal")
        self.assertTrue(config.physics.solver_cfg.use_mujoco_contacts)
        with self.assertRaisesRegex(ValueError, "physics_dt=0.005"):
            make_sim("cuda:0", SimpleNamespace(physics_dt=.002))

    def test_gpu_joint_order_mismatch_is_rejected_before_raw_state_access(self):
        class SceneConfig:
            def __init__(self, **kwargs):
                pass

        # smc also requires SDK order rather than silently interpreting a USD permutation.
        names = G1_JOINT_NAMES.copy()
        names[0], names[1] = names[1], names[0]
        robot = SimpleNamespace(joint_names=names)
        sim_module = SimpleNamespace(GroundPlaneCfg=SimpleNamespace, SimulationContext=lambda cfg: SimpleNamespace(reset=Mock()))
        with patch.dict(sys.modules, {
            "isaaclab": SimpleNamespace(sim=sim_module), "isaaclab.sim": sim_module,
            "isaaclab.assets": SimpleNamespace(AssetBaseCfg=SimpleNamespace),
            "isaaclab.scene": SimpleNamespace(InteractiveSceneCfg=SceneConfig),
            "isaaclab.utils": SimpleNamespace(configclass=lambda c: c, instantiate=lambda c: {"robot": robot},
                                                replace=lambda c, **kwargs: c),
        }), patch.object(sys.modules[TrackingSim.__module__], "isaaclab_config", return_value=SimpleNamespace()):
            with self.assertRaisesRegex(ValueError, "joint order"):
                TrackingSim(SimpleNamespace(device="cpu"), 2, None, None, usd_path="/fake/g1.usda")

    def test_optional_backend_reports_missing_runtime_without_breaking_cpu_import(self):
        with patch.dict(sys.modules, {"isaaclab": None}):
            with self.assertRaisesRegex(RuntimeError, "kit-less"):
                make_sim("cuda:0")
        with patch("torch.cuda.is_available", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "CUDA"):
                with make_isaac_env(SimpleNamespace(device="cuda:0"), None, None):
                    self.fail("unavailable GPU launched")

    def test_training_transition_preserves_pre_reset_state_and_timeout(self):
        env = fixture()
        env.f[1] = 3
        out = env.step(torch.ones(2, 29))
        self.assertEqual(out["f"].tolist(), [0, 3])
        self.assertEqual(out["done"].tolist(), [False, True])
        self.assertEqual(out["term"].tolist(), [False, False])
        self.assertEqual(out["truncated"].tolist(), [False, True])
        self.assertEqual(env.f.tolist(), [1, 0])
        self.assertEqual(env.ep_step.tolist(), [1, 0])
        self.assertTrue(torch.allclose(env.robot.target[0], torch.full((29,), .51)))
        self.assertEqual(len(env.sampler.updates), 1)
        self.assertEqual(env.sampler.updates[0][2]["episode_lengths"].tolist(), [1])
        self.assertTrue(torch.allclose(out["xi"][:, 1:30], torch.full((2, 29), .01)))

    def test_evaluation_view_disables_randomization_and_training_timeout(self):
        env = fixture()
        env.max_episode_steps = 1
        env.xi[:, 30:] = .02
        view = env.for_evaluation()
        self.assertEqual(view.f.numel(), 1)
        self.assertTrue(env.eval_mode)
        self.assertFalse(env.auto_reset)
        self.assertTrue(torch.equal(env.xi[:, 0], torch.ones(2)))
        self.assertTrue(torch.equal(env.xi[:, 1:], torch.zeros(2, 32)))
        self.assertEqual(view.evaluation_settings["simulated_replica_count"], 2)
        self.assertEqual(view.evaluation_settings["measured_replica_count"], 1)
        view.reset(frames=torch.tensor([0]))
        first = view.step(torch.zeros(1, 29))
        self.assertFalse(first["done"].item())
        view.reset(frames=torch.tensor([3]))
        last = view.step(torch.zeros(1, 29))
        self.assertTrue(last["done"].item())
        self.assertEqual(view.f.item(), 4)
        exhausted = view.step(torch.zeros(1, 29))
        self.assertEqual(view.f.item(), 4)
        self.assertEqual(exhausted["r"].item(), 0.)

    def test_warm_resume_declares_refill_and_starts_new_episodes(self):
        env = fixture()
        env.f[:] = 3
        state = env.state_dict()
        env.sampler.marker = 0
        result = env.load_state_dict(state)
        self.assertFalse(result["exact_resume"])
        self.assertTrue(result["replay_refill_required"])
        self.assertEqual(result["physical_episodes_reset"], 2)
        self.assertEqual(env.f.tolist(), [0, 0])
        self.assertEqual(env.sampler.marker, 17)
        self.assertFalse(state["exact_resume"])
        env.self_collisions = False
        with self.assertRaisesRegex(ValueError, "collision"):
            env.load_state_dict(state)

    def test_context_writes_physics_and_warm_resume_resamples_only_episode_offsets(self):
        env = fixture()
        env._mu_view = torch.zeros(2, 5)
        env._base_torso_com = torch.tensor([[.1, .2, .3], [.4, .5, .6]])
        env.torso_id = 7
        env.robot.set_coms_index = Mock()
        env.sim.backend_manager = SimpleNamespace(add_model_change=Mock())
        env.xi[:, 30:33] = torch.tensor([[.01, .02, -.03], [-.01, -.02, .03]])
        saved = env.state_dict()
        env.xi.fill_(0)
        env._apply_context = lambda: TrackingSim._apply_context(env)
        with patch.dict(sys.modules, {"newton": SimpleNamespace(ModelFlags=SimpleNamespace(SHAPE_PROPERTIES=42))}):
            env.load_state_dict(saved)
        self.assertTrue(torch.equal(env.xi[:, 0], saved["xi"][:, 0]))
        self.assertTrue(torch.equal(env.xi[:, 30:33], saved["xi"][:, 30:33]))
        self.assertTrue(torch.equal(env._mu_view, saved["xi"][:, :1].expand(2, 5)))
        call = env.robot.set_coms_index.call_args.kwargs
        self.assertEqual(call["body_ids"], [7])
        self.assertTrue(torch.equal(call["coms"], (env._base_torso_com + saved["xi"][:, 30:33]).unsqueeze(1)))
        env.sim.backend_manager.add_model_change.assert_called_once_with(42)
        self.assertTrue((env.xi[:, 1:30].abs() <= .01).all())
        self.assertFalse(torch.equal(env.xi[:, 1:30], saved["xi"][:, 1:30]))

    def test_evaluation_passes_raw_action_without_collection_cap(self):
        env = fixture()
        view = env.for_evaluation()
        view.reset(frames=torch.tensor([0]))
        out = view.step(torch.full((1, 29), 25.))
        self.assertTrue(torch.equal(out["a"], torch.full((1, 29), 25.)))
        self.assertTrue(torch.allclose(env.robot.target, torch.full((2, 29), .2 + .3 * 25)))

    def test_episode_context_resamples_only_selected_environment_and_updates_physics(self):
        env = fixture()
        env.context_resampling = "episode"
        env._mu_view = torch.full((2, 5), .7)
        env._base_torso_com = torch.tensor([[.1, .2, .3], [.4, .5, .6]])
        env.torso_id = 7
        env.robot.set_coms_index = Mock()
        env.sim.backend_manager = SimpleNamespace(add_model_change=Mock())
        before = env.xi.clone()
        env._apply_context = lambda ids=None: TrackingSim._apply_context(env, ids)
        with torch.random.fork_rng(devices=[]), patch.dict(sys.modules, {
            "newton": SimpleNamespace(ModelFlags=SimpleNamespace(SHAPE_PROPERTIES=42)),
        }):
            torch.manual_seed(31)
            env.reset(env_ids=torch.tensor([1]), frames=torch.tensor([0]))
        self.assertTrue(torch.equal(env.xi[0], before[0]))
        self.assertFalse(torch.equal(env.xi[1], before[1]))
        self.assertTrue(.3 <= env.xi[1, 0] <= 1.2)
        self.assertTrue(env.xi[1, 30].abs() <= .025)
        self.assertTrue((env.xi[1, 31:33].abs() <= .05).all())
        self.assertTrue(torch.equal(env._mu_view[0], torch.full((5,), .7)))
        self.assertTrue(torch.equal(env._mu_view[1], env.xi[1, :1].expand(5)))
        kwargs = env.robot.set_coms_index.call_args.kwargs
        self.assertEqual(kwargs["env_ids"].tolist(), [1])
        self.assertTrue(torch.equal(kwargs["coms"], (env._base_torso_com[1:] + env.xi[1:, 30:33]).unsqueeze(1)))
        with self.assertRaisesRegex(ValueError, "resampling protocol"):
            env.load_state_dict(dict(env.state_dict(), context_resampling="environment"))


if __name__ == "__main__":
    unittest.main()
