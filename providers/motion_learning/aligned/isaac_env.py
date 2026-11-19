"""Optional Isaac Lab 3 / Newton / MuJoCo-Warp backend for the aligned learner.

Adapted from smc ``supermimic/env.py`` (MIT, ETH Zurich / Chong Zhang;
see SMC_LICENSE). Importing this module does not import Isaac Lab or Warp.
The runtime API is pinned to IsaacLab commit 46d6cc3d7b115906fad12efd372fbf69f4e3d3ed.
"""

from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path

import torch

from .mdp import MAX_STEP_REWARD, flatten_state
from .robot import G1_JOINT_NAMES, USD_PATH, action_scale, isaaclab_config
from .rotations import mat_to_quat, quat_to_mat, so3_exp

CONTROL_DT = 0.02
PHYSICS_DT = 0.005
PHYSICS_SUBSTEPS = 4
ISAACLAB_REVISION = "46d6cc3d7b115906fad12efd372fbf69f4e3d3ed"


def make_sim(device: str, args=None):
    """Construct the kit-less physics configuration, loading optional packages now."""
    physics_dt = float(getattr(args, "physics_dt", PHYSICS_DT))
    if abs(physics_dt - PHYSICS_DT) > 1e-12:
        raise ValueError("The aligned Isaac backend requires physics_dt=0.005 (four substeps per 0.02 s control step)")
    try:
        import isaaclab.sim as sim_utils
        from isaaclab_newton.physics import MJWarpSolverCfg, NewtonCfg
    except ImportError as exc:
        raise RuntimeError(
            "The isaac backend requires the Isaac Lab 3 kit-less environment, Newton, "
            "MuJoCo-Warp and a CUDA GPU. See docs/G1_ALIGNED_GPU.md. "
            "Use --backend mujoco for the CPU numerical/physics smoke run."
        ) from exc
    physics = NewtonCfg(
        solver_cfg=MJWarpSolverCfg(
            njmax=500, nconmax=128, cone="pyramidal", integrator="implicitfast",
            use_mujoco_contacts=True,
        ),
        num_substeps=PHYSICS_SUBSTEPS,
    )
    return sim_utils.SimulationCfg(dt=CONTROL_DT, device=str(device), physics=physics)


@contextmanager
def make_isaac_env(args, motion, mdp, *, eval_mode=False):
    """Launch one optional GPU runtime and yield the common environment protocol.

    ``args`` is the aligned trainer's Namespace. Required: device and num_envs.
    Optional: usd_path, self_collisions, gamma, max_episode_steps, seed,
    reset_noise, context_resampling and physics_dt. MLP precision is selected
    by the learner, not the physics API.
    """
    device = str(args.device)
    if not device.startswith("cuda") or not torch.cuda.is_available():
        raise RuntimeError("The isaac backend needs an available CUDA device; use --backend mujoco on this host.")
    usd_path = Path(getattr(args, "usd_path", None) or USD_PATH).expanduser().resolve()
    if not usd_path.is_file():
        raise FileNotFoundError(
            f"Missing G1 USD asset: {usd_path}. Convert the retarget model offline "
            "as documented in docs/G1_ALIGNED_GPU.md and set --usd-path."
        )
    sim_cfg = make_sim(device, args)
    from isaaclab.app import launch_simulation

    # Explicitly selecting no visualizers keeps this a kit-less training runtime.
    # The pinned launcher accepts dicts and supplies its own missing defaults.
    launcher_args = {"device": device, "visualizer": [], "headless": True}
    with launch_simulation(sim_cfg, launcher_args):
        env = TrackingSim(
            sim_cfg, args.num_envs, motion, mdp,
            gamma=getattr(args, "gamma", 0.99), eval_mode=eval_mode,
            max_episode_steps=getattr(args, "max_episode_steps", 500),
            reset_noise=getattr(args, "reset_noise", True),
            self_collisions=getattr(args, "self_collisions", True),
            context_resampling=getattr(args, "context_resampling", "episode"),
            usd_path=str(usd_path), seed=getattr(args, "seed", 0),
        )
        yield env


class TrackingSim:
    """Batched G1 environment using the same MDP and motion library as CPU training.

    Solver internals cannot currently be serialized. ``load_state_dict`` starts
    fresh physical episodes and returns an explicit replay-refill requirement.
    It must not be interpreted as an exact physics continuation.
    """

    exact_resume = False

    def __init__(self, sim_cfg, num_envs, motion, mdp, gamma=0.99, eval_mode=False,
                 max_episode_steps=500, reset_noise=True, self_collisions=True,
                 usd_path=None, seed=0, context_resampling="environment"):
        if context_resampling not in ("environment", "episode"):
            raise ValueError("context_resampling must be environment or episode")
        # All simulator imports remain below the optional backend boundary.
        import isaaclab.sim as sim_utils
        from isaaclab.assets import AssetBaseCfg
        from isaaclab.scene import InteractiveSceneCfg
        from isaaclab.sim import SimulationContext
        from isaaclab.utils import configclass, instantiate, replace
        from .sampling import ReturnBinSampler

        robot_cfg = isaaclab_config(usd_path=usd_path, self_collisions=self_collisions)

        @configclass
        class TrackingSceneCfg(InteractiveSceneCfg):
            ground = AssetBaseCfg(prim_path="/World/ground", spawn=sim_utils.GroundPlaneCfg())
            robot = replace(robot_cfg, prim_path="{ENV_REGEX_NS}/Robot")

        self.device = str(sim_cfg.device)
        self.sim = SimulationContext(sim_cfg)
        self.scene = instantiate(TrackingSceneCfg(num_envs=num_envs, env_spacing=0.0, replicate_physics=True))
        self.sim.reset()
        self.robot = self.scene["robot"]
        if list(self.robot.joint_names) != G1_JOINT_NAMES:
            raise ValueError(f"G1 USD joint order differs from the reference order: {self.robot.joint_names}")
        self.N = self.num_envs = num_envs
        self.motion, self.mdp, self.gamma = motion, mdp, gamma
        self.eval_mode = eval_mode
        self.auto_reset = not eval_mode
        self.max_episode_steps = max_episode_steps if not eval_mode else 10**9
        self.reset_noise = reset_noise and not eval_mode
        self.self_collisions = self_collisions
        self.context_resampling = context_resampling
        self.usd_path = str(usd_path or USD_PATH)
        dev = self.device
        self.default_q = self.robot.data.default_joint_pos.torch[0].clone()
        self.alpha = torch.tensor([action_scale(n) for n in G1_JOINT_NAMES], device=dev)
        self.torso_id = self.robot.find_bodies("torso_link")[0][0]
        self._base_torso_com = self.robot.data.body_com_pose_b.torch[:, self.torso_id, :3].clone()

        # Context xi = friction, joint setpoint offsets (29), torso COM offsets (3).
        self.xi = torch.zeros(self.N, 33, device=dev)
        self._setup_friction()
        self.xi[:, 0] = 1.0
        if not eval_mode and context_resampling == "environment":
            self._sample_context(torch.arange(self.N, device=dev))
        self._apply_context()

        self.f = torch.zeros(self.N, dtype=torch.long, device=dev)
        self.ep_step = torch.zeros(self.N, dtype=torch.long, device=dev)
        self.a_prev = torch.zeros(self.N, 29, device=dev)
        self.start_bin = torch.zeros(self.N, dtype=torch.long, device=dev)
        self.ep_disc_ret = torch.zeros(self.N, device=dev)
        self.ep_ret = torch.zeros(self.N, device=dev)
        self.done_eval = torch.zeros(self.N, dtype=torch.bool, device=dev)
        self.failed_eval = torch.zeros(self.N, dtype=torch.bool, device=dev)
        self.sampler = ReturnBinSampler(motion, gamma=gamma, max_step_reward=MAX_STEP_REWARD, seed=seed)
        self.reset()

    @property
    def evaluation_settings(self):
        return {
            "backend": "isaac-newton-mujoco-warp", "control_dt_s": CONTROL_DT,
            "physics_substeps": PHYSICS_SUBSTEPS, "physics_dt_s": PHYSICS_DT,
            "reset_noise": self.reset_noise, "context_resampling": self.context_resampling,
            "randomization": not self.eval_mode, "auto_reset": self.auto_reset,
            "training_timeout_enabled": not self.eval_mode,
            "self_collisions": self.self_collisions, "simulated_replica_count": self.N,
            "isaaclab_revision": ISAACLAB_REVISION,
        }

    def for_evaluation(self):
        """End training episodes and expose slot zero to the sequential evaluator.

        Call after saving the training checkpoint. All slots receive identical
        deterministic resets/actions; only slot zero is measured. Continuing
        training afterward requires a physical reset and replay/history refill.
        """
        self.eval_mode, self.auto_reset, self.reset_noise = True, False, False
        self.xi.zero_()
        self.xi[:, 0] = 1.0
        self._setup_friction()
        self._apply_context()
        self.reset()
        return _EvaluationView(self)

    def _setup_friction(self):
        import warp as wp

        model = self.sim.backend_manager.get_model()
        self._mu_view = wp.to_torch(self.robot._root_view.get_attribute("shape_material_mu", model)[:, 0])
        shape_body = wp.to_torch(model.shape_body)
        mu_all = wp.to_torch(model.shape_material_mu)
        mu_all[shape_body < 0] = 1.0 if self.eval_mode else 0.3

    def _sample_context(self, env_ids):
        n = len(env_ids)
        self.xi[env_ids, 0] = torch.empty(n, device=self.device).uniform_(0.3, 1.2)
        self.xi[env_ids, 30] = torch.empty(n, device=self.device).uniform_(-0.025, 0.025)
        self.xi[env_ids, 31:33] = torch.empty(n, 2, device=self.device).uniform_(-0.05, 0.05)

    def _apply_context(self, env_ids=None):
        from newton import ModelFlags

        if env_ids is None:
            self._mu_view[:] = self.xi[:, :1]
        else:
            self._mu_view[env_ids] = self.xi[env_ids, :1]
        self.sim.backend_manager.add_model_change(ModelFlags.SHAPE_PROPERTIES)
        coms = (self._base_torso_com + self.xi[:, 30:33]).unsqueeze(1)
        if env_ids is None:
            self.robot.set_coms_index(coms=coms, body_ids=[self.torso_id])
        else:
            self.robot.set_coms_index(coms=coms[env_ids], body_ids=[self.torso_id], env_ids=env_ids)

    def state(self):
        d = self.robot.data
        pose = d.root_link_pose_w.torch.clone()
        vel = d.root_link_vel_w.torch.clone()
        p = pose[:, :3] - self.scene.env_origins
        quat = pose[:, 3:7]  # Isaac Lab 3 stores xyzw; numerical rotations use wxyz.
        R = quat_to_mat(torch.cat((quat[:, 3:4], quat[:, :3]), -1))
        return p, R, vel[:, :3], vel[:, 3:6], d.joint_pos.torch.clone(), d.joint_vel.torch.clone()

    def sample_frames(self, n):
        return self.sampler.sample(n)

    def reset(self, env_ids=None, frames=None):
        dev = self.device
        if env_ids is None:
            env_ids = torch.arange(self.N, device=dev)
        else:
            env_ids = torch.as_tensor(env_ids, dtype=torch.long, device=dev)
        n = len(env_ids)
        if n == 0:
            return
        if frames is None:
            frames, bins = self.sample_frames(n)
        else:
            frames = torch.as_tensor(frames, dtype=torch.long, device=dev)
            if frames.shape != env_ids.shape:
                raise ValueError("reset frames must provide one frame per environment")
            bins = self.motion.frame_bin[frames]
        if not self.eval_mode and self.context_resampling == "episode":
            self._sample_context(env_ids)
            self._apply_context(env_ids)
        p, R, v, w, q, qd = (x.clone() for x in self.motion.ref_state(frames))
        if self.reset_noise:
            p += torch.empty(n, 3, device=dev).uniform_(-1, 1) * p.new_tensor([0.05, 0.05, 0.01])
            rv = torch.empty(n, 3, device=dev).uniform_(-1, 1) * p.new_tensor([0.1, 0.1, 0.2])
            R = so3_exp(rv) @ R
            v += torch.empty(n, 3, device=dev).uniform_(-1, 1) * p.new_tensor([0.5, 0.5, 0.2])
            w += torch.empty(n, 3, device=dev).uniform_(-1, 1) * p.new_tensor([0.52, 0.52, 0.78])
            q += torch.empty_like(q).uniform_(-0.1, 0.1)
        q = q.clamp(self.mdp.kin.q_lo, self.mdp.kin.q_hi)
        quat = mat_to_quat(R)
        pose = torch.cat((p + self.scene.env_origins[env_ids], quat[:, 1:4], quat[:, 0:1]), -1)
        self.robot.write_root_link_pose_to_sim_index(root_pose=pose, env_ids=env_ids)
        self.robot.write_root_link_velocity_to_sim_index(root_velocity=torch.cat((v, w), -1), env_ids=env_ids)
        self.robot.write_joint_position_to_sim_index(position=q, env_ids=env_ids)
        self.robot.write_joint_velocity_to_sim_index(velocity=qd, env_ids=env_ids)
        self.robot.set_joint_position_target_index(target=q, env_ids=env_ids)
        self.f[env_ids] = frames
        self.ep_step[env_ids] = 0
        self.a_prev[env_ids] = 0.0
        self.start_bin[env_ids] = bins
        self.ep_disc_ret[env_ids] = 0.0
        self.ep_ret[env_ids] = 0.0
        self.done_eval[env_ids] = False
        self.failed_eval[env_ids] = False
        if not self.eval_mode:
            self.xi[env_ids, 1:30] = torch.empty(n, 29, device=dev).uniform_(-0.01, 0.01)
        self.scene.reset(env_ids)
        self.refresh()

    def refresh(self):
        """Make simulator reads consistent with explicitly written reset states."""
        if hasattr(self.sim, "forward"):
            self.sim.forward()
        self.scene.update(0.0)

    def step(self, a):
        # Physics state/actions stay float32 even if learner MLPs use bf16 autocast.
        a = a.detach().to(device=self.device, dtype=self.a_prev.dtype)
        S = self.state()
        f, xi, a_prev, ep_step = self.f.clone(), self.xi.clone(), self.a_prev.clone(), self.ep_step.clone()
        active = ~self.done_eval if self.eval_mode else torch.ones(self.N, dtype=torch.bool, device=self.device)
        target = self.default_q + xi[:, 1:30] + self.alpha * a
        self.robot.set_joint_position_target_index(target=target)
        self.scene.write_data_to_sim()
        self.sim.step(render=False)
        self.scene.update(CONTROL_DT)
        S1 = self.state()
        f1 = f + active.long()
        r, terms = self.mdp.reward(S1, f1, a, a_prev, terms=True)
        term = self.mdp.termination(S1, f1) & active
        clip_end = self.motion.clip_end[self.motion.clip_id[f]]
        timeout = f1 >= clip_end
        if not self.eval_mode:
            timeout |= ep_step + 1 >= self.max_episode_steps
        done = term | timeout | ~active
        r = torch.where(active, r, 0.0)
        out = {
            "s": flatten_state(S), "a": a.clone(), "a_prev": a_prev, "f": f,
            "s1": flatten_state(S1), "r": r, "term": term, "done": done,
            "ep_step": ep_step, "xi": xi, "terms": terms,
            "timeout": timeout, "truncated": timeout & ~term,
        }
        self.ep_disc_ret += (self.gamma ** ep_step.float()) * r
        self.ep_ret += r
        self.f = f1
        self.ep_step = ep_step + active.long()
        self.a_prev = a.clone()
        if self.eval_mode:
            self.failed_eval |= term
            self.done_eval |= done
            return out
        ids = done.nonzero(as_tuple=False).squeeze(-1)
        if self.auto_reset and len(ids):
            T = self.ep_step[ids].float()
            self.sampler.update(
                self.start_bin[ids], self.ep_disc_ret[ids], episode_lengths=T,
                undiscounted_returns=self.ep_ret[ids], terminated=term[ids],
            )
            out["ep_len"] = T
            out["ep_ret_norm"] = self.ep_ret[ids] / (T * MAX_STEP_REWARD)
            self.reset(ids)
        return out

    def state_dict(self):
        """Save sampling/context state; no claim to serialize Newton solver internals."""
        return {
            "format": "moonrobo.aligned.isaac-warm-state.v1",
            "backend": "isaac", "exact_resume": False, "replay_refill_required": True,
            "sampler": self.sampler.state_dict(), "xi": self.xi.detach().cpu().clone(),
            "num_envs": self.N, "self_collisions": self.self_collisions,
            "context_resampling": self.context_resampling,
            "usd_path": self.usd_path, "isaaclab_revision": ISAACLAB_REVISION,
        }

    def load_state_dict(self, state):
        """Restore adaptive sampling/context, reset physics, require replay refill."""
        if state.get("format") != "moonrobo.aligned.isaac-warm-state.v1":
            raise ValueError("not an aligned Isaac warm-resume state")
        if state["num_envs"] != self.N or state["self_collisions"] != self.self_collisions:
            raise ValueError("Isaac resume environment count or collision configuration changed")
        if state["usd_path"] != self.usd_path:
            raise ValueError("Isaac resume robot asset path changed")
        if state.get("context_resampling", "environment") != self.context_resampling:
            raise ValueError("Isaac resume context resampling protocol changed")
        self.sampler.load_state_dict(state["sampler"])
        self.xi.copy_(state["xi"].to(self.device))
        self._apply_context()
        self.reset()
        return {"exact_resume": False, "replay_refill_required": True, "physical_episodes_reset": self.N}


class _EvaluationView:
    """One measured environment backed by an already allocated GPU scene."""

    eval_mode, auto_reset, num_envs = True, False, 1

    def __init__(self, env):
        self.env = env
        self.mdp, self.motion, self.device = env.mdp, env.motion, env.device

    @property
    def f(self):
        return self.env.f[:1]

    @property
    def a_prev(self):
        return self.env.a_prev[:1]

    @property
    def xi(self):
        return self.env.xi[:1]

    @property
    def evaluation_settings(self):
        return dict(self.env.evaluation_settings, measured_replica_count=1)

    def state(self):
        return tuple(value[:1] for value in self.env.state())

    def reset(self, env_ids=None, frames=None):
        if frames is None or len(frames) != 1:
            raise ValueError("sequential GPU evaluation requires exactly one reference start frame")
        self.env.reset(frames=frames.expand(self.env.N))

    def step(self, action):
        if len(action) != 1:
            raise ValueError("sequential GPU evaluation requires exactly one policy action")
        result = self.env.step(action.expand(self.env.N, -1))
        return {
            key: value[:1] if isinstance(value, torch.Tensor) else value
            for key, value in result.items()
        }
