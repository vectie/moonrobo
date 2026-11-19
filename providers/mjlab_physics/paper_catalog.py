"""Deterministic Appendix F physics and one complete rollout per motion.

The policy and checkpoint loader live in MoonBit. This manager schedules
physical worlds during mjlab's normal episode reset and scores their rewards.
"""
import json
from pathlib import Path

import torch
import mujoco_warp as mjw
from mjlab.sim.sim import SimulationCfg
from mjlab.tasks.tracking.mdp.commands import MotionCommand, MotionCommandCfg


class BenchmarkSimulation(SimulationCfg):
    def apply_wp_opt(self, opt):
        super().apply_wp_opt(opt)
        opt.deterministic = int(mjw.DeterminismType.ALL)


class CatalogCommand(MotionCommand):
    scorer = None
    fresh = None

    def _external_sampling(self, env_ids):
        if self.scorer is None:
            return torch.zeros_like(env_ids)
        self.fresh = env_ids
        return self.scorer.assign(env_ids)

    def _update_command(self, env_ids=None):
        # mjlab advances every row immediately after reset. Score the very
        # first frame on the next physical step, including partial resets.
        if self.fresh is not None:
            self.time_steps[self.fresh] -= 1
            self.fresh = None
        super()._update_command(env_ids)


class CatalogCommandCfg(MotionCommandCfg):
    def build(self, env):
        return CatalogCommand(self, env)


def configure(cfg):
    cfg.sim = BenchmarkSimulation(**vars(cfg.sim))
    # Warp's deterministic sparse J^T D J kernel exceeds its 32-bit sort
    # workspace on large batches. Use its dense Newton factorization of the
    # same Jacobian, with the original solver, timestep and tolerances.
    cfg.sim.mujoco.jacobian = "dense"
    cfg.scene.env_spacing = 0.0
    command = CatalogCommandCfg(**vars(cfg.commands["motion"]))
    command.sampling_mode = "external"
    command.pose_range, command.velocity_range = {}, {}
    command.joint_position_range = (0.0, 0.0)
    cfg.commands["motion"] = command
    if set(cfg.events) != {"foot_friction", "base_com", "encoder_bias"}:
        raise ValueError("unexpected randomization event in author G1")
    cfg.events["foot_friction"].params["ranges"] = (1.0, 1.0)
    cfg.events["base_com"].params["ranges"] = {i: (0.0, 0.0) for i in range(3)}
    cfg.events["encoder_bias"].params["bias_range"] = (0.0, 0.0)
    for obs in cfg.observations.values():
        obs.enable_corruption = False


class CatalogScorer:
    def __init__(self, physics, args):
        self.physics, self.args = physics, args
        self.env, self.cmd = physics.env, physics.command
        live = self.env.unwrapped
        assert int(live.sim.wp_model.opt.deterministic) == int(mjw.DeterminismType.ALL)
        assert set(live.cfg.terminations) == {"time_out", "motion_end", "anchor_pos", "anchor_ori"}
        assert live.cfg.terminations["anchor_pos"].params["threshold"] == 0.25
        assert live.cfg.terminations["anchor_ori"].params["threshold"] == 0.8
        assert not any(g.enable_corruption for g in live.cfg.observations.values())
        assert not torch.count_nonzero(live.scene.env_origins)
        robot = live.scene["robot"]
        # Upstream reads the absolute torso COM, even when its randomized
        # additive offset is zero. Compare to the compiled asset's inertial pose.
        torso = int(robot.indexing.body_ids[robot.body_names.index("torso_link")])
        actual = live.sim.model.body_ipos[:, torso, :]
        nominal = actual.new_tensor(live.sim.mj_model.body_ipos[torso])
        assert torch.allclose(actual, nominal.expand_as(actual), atol=1e-7, rtol=0)
        feet = [i for i, name in enumerate(robot.geom_names)
                if name.startswith(("right_foot", "left_foot")) and name.endswith("_collision")]
        assert len(feet) == 14 and (live.sim.model.geom_friction[:,robot.indexing.geom_ids[feet],0] == 1).all()
        assert not torch.count_nonzero(robot.data.encoder_bias)
        self.max_reward = live.step_dt * sum(x.weight for x in live.cfg.rewards.values() if x.weight > 0)
        assert abs(self.max_reward - 0.1) < 1e-7
        self.ends = self.cmd.motion.motion_ends
        self.starts = torch.cat((self.ends.new_zeros(1), self.ends[:-1]))
        self.lengths = self.ends - self.starts
        self.n = self.env.num_envs
        self.device = self.ends.device
        self.names = json.loads((Path(args["motion_file"]) / "motion_names.json").read_text())
        assert len(self.names) == self.ends.numel() == len(set(self.names))

    def begin(self):
        # Longest first keeps all worlds busy without truncating long clips.
        indices = self.args.get("clip_indices")
        ids = list(range(len(self.names))) if indices is None else indices
        assert len(ids) == len(set(ids)) and all(0 <= i < len(self.names) for i in ids) and ids
        self.ids = self.ends.new_tensor(ids)
        self.order = self.ids[torch.argsort(self.lengths[self.ids], descending=True, stable=True)]
        self.pos = self.steps = 0
        self.slots = self.ends.new_full((self.n,), -1)
        self.count = torch.zeros_like(self.slots)
        self.total = self.count.double()
        self.scored = torch.zeros_like(self.ends)
        self.fell = torch.zeros_like(self.ends, dtype=torch.bool)
        self.reward = self.scored.double()
        self.invalid = torch.zeros((), device=self.device, dtype=torch.bool)
        self.reset_error = torch.zeros((), device=self.device)
        self.cmd.scorer = self
        self.env.reset()
        return self.slots

    def assign(self, env_ids):
        k = min(len(env_ids), len(self.order) - self.pos)
        self.slots[env_ids] = -1
        self.slots[env_ids[:k]] = self.order[self.pos:self.pos+k]
        self.pos += k
        return self.starts[self.slots[env_ids].clamp_min(0)]

    def step(self, actions):
        prev = self.slots.clone()
        valid = prev >= 0
        safe = prev.clamp_min(0)
        self.invalid |= ((self.cmd.time_steps != self.starts[safe] + self.count) & valid).any()
        self.invalid |= ~torch.isfinite(actions).all()
        # Confirm first-frame robot state, not only the reference cursor.
        fresh = (valid & (self.count == 0)).nonzero().flatten()
        if len(fresh):
            times = self.cmd.time_steps[fresh]
            m = self.cmd.motion
            bounds = self.env.unwrapped.scene["robot"].data.soft_joint_pos_limits[fresh]
            q = m.joint_pos[times].clamp(bounds[:,:,0], bounds[:,:,1])
            ref = torch.cat((m.root_pos_w[times],m.root_quat_w[times],q,
                             m.root_lin_vel_w[times],m.root_ang_vel_w[times],m.joint_vel[times]),1)
            obs = self.env.get_observations()["full_state"][fresh]
            self.reset_error = torch.maximum(self.reset_error,(ref-obs).abs().max())
        _, rew, done, _ = self.env.step(actions)
        tm = self.env.unwrapped.termination_manager
        end, fall = tm.get_term("motion_end").bool(), tm.terminated.bool()
        done = done.bool()
        self.invalid |= ((done != (end | fall)) & valid).any() | (~torch.isfinite(rew) & valid).any()
        self.count += valid
        self.total += torch.where(valid, rew.double(), 0.0)
        finishing = (done & valid).nonzero().flatten()
        clips = prev[finishing]
        self.invalid |= ((end[finishing] != (self.count[finishing] == self.lengths[clips])) |
                         (self.scored[clips] != 0) | (self.count[finishing] > self.lengths[clips])).any()
        self.scored[clips] = self.count[finishing]
        self.reward[clips] = self.total[finishing]
        self.fell[clips] = fall[finishing]
        self.count[done] = 0
        self.total[done] = 0
        self.steps += 1
        return self.slots

    def finish(self):
        assert not self.invalid.item() and self.reset_error.item() < 2e-5
        assert self.pos == len(self.order) and (self.slots < 0).all()
        assert (self.scored[self.ids] > 0).all() and (self.scored > 0).sum().item() == len(self.ids)
        counts = self.scored[self.ids].tolist()
        lengths = self.lengths[self.ids].tolist()
        fails = self.fell[self.ids].tolist()
        returns = (self.reward[self.ids] / (self.max_reward * self.lengths[self.ids].double())).tolist()
        records = [[self.names[i], n, t, bad, r] for i,n,t,bad,r in zip(self.ids.tolist(),lengths,counts,fails,returns,strict=True)]
        return dict(physical_steps=self.args["physical_steps"],clips=len(records),failed=sum(fails),
                    mean_return=sum(returns)/len(returns),frames=sum(lengths),executed=sum(counts),
                    vector_steps=self.steps, initial_state_max_abs=self.reset_error.item(),
                    determinism=int(self.env.unwrapped.sim.wp_model.opt.deterministic),
                    source=self.args["manifest_sha256"], columns=["clip","frames","executed","failed","normalized_return"],rows=records)

    def exchange(self, op, arg):
        if op == 19: return self.begin()
        if op == 20: return self.ends[self.slots.clamp_min(0)] - 1
        if op == 21: return self.step(arg)
        if op == 22:
            if self.invalid.item() or not (self.reset_error.item() < 2e-5):
                raise RuntimeError(f"invalid rollout or stale initial state: {self.reset_error.item()}")
            return self.slots.new_tensor([(self.scored > 0).sum().item(), len(self.order)])
        if op == 23:
            output = Path(self.args["output"])
            temp = output.with_suffix(".partial")
            with temp.open("x") as f: json.dump(self.finish(), f, separators=(",",":"), allow_nan=False)
            temp.replace(output)
            return self.slots
        raise ValueError(f"unknown paper evaluation operation {op}")
