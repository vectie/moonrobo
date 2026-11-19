"""Executable collect/model/BPTT/GAE baseline; launch through run_g1_aligned.mbtx.

CPU smoke and CUDA scale profiles share the training equations, not compute budgets.
Checkpoint files are trusted local PyTorch artifacts, including full replay and RNG.
"""
from __future__ import annotations

import argparse
from contextlib import nullcontext
import hashlib
import json
import math
from pathlib import Path
import time

import torch

from .buffer import ReplayBuffer, require_actor_horizon
from .distributed import (aggregate_row, any_rank_needs_warmup, assert_same_learner,
                          assert_same_progress, assert_same_setup, barrier, broadcast_learner,
                          global_counters, setup, synchronize_sampler, teardown)
from .evaluation import evaluate_policy
from .kinematics import G1Kinematics
from .learning import AlignedLearner
from .memory_budget import check_training_memory, host_memory_observation
from .mdp import MDP, unflatten_state
from .motion import MotionLib
from .robot import USD_PATH, default_joint_pos_list


def digest(path):
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def trainer_sources():
    # macOS tar metadata sidecars are not executable Python sources.
    return [p for p in sorted(Path(__file__).parent.glob('*.py'))
            if not p.name.startswith('.')]


def checkpoint(learner, buffer, env, history, iteration, counters, config, identity, step_acc):
    return dict(format='moonrobo.aligned-checkpoint.v1', learner=learner.state_dict(),
        replay=buffer.state_dict(), env=env.state_dict(), history=history,
        iteration=iteration, counters=counters.copy(), config=config, identity=identity,
        step_acc=step_acc, torch_rng=torch.get_rng_state(),
        cuda_rng=torch.cuda.get_rng_state_all() if torch.cuda.is_available() else [])


def run(args):
    device, rank, world_size = setup(getattr(args, 'distributed', False), args.backend, args.device)
    try:
        return _run(args, device, rank, world_size)
    finally:
        teardown()


def _run(args, device, rank, world_size):
    cfg = json.loads(Path(args.config).read_text())
    torch.set_num_threads(cfg.get('threads', 4))
    torch.manual_seed(cfg.get('seed', 0) + rank)
    torch.backends.cuda.matmul.allow_tf32 = cfg.get('allow_tf32', True)
    torch.backends.cudnn.allow_tf32 = cfg.get('allow_tf32', True)
    if device.startswith('cuda') and not torch.cuda.is_available():
        raise RuntimeError('CUDA requested but unavailable; use the explicitly labelled CPU smoke profile')
    from . import networks
    networks.AMP_DTYPE = torch.bfloat16 if cfg.get('amp') == 'bf16' else None
    if networks.AMP_DTYPE is not None and not device.startswith('cuda'):
        raise ValueError('bf16 profile requires CUDA')
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    memory_plan = None
    if args.backend == 'isaac':
        memory_plan = check_training_memory(
            cfg, args.motion_dir, device_free_bytes=torch.cuda.mem_get_info()[0],
            manifest_path=args.motion_manifest,
            reference_storage=cfg.get('reference_storage', 'eager'))
        if rank == 0:
            print(json.dumps({'memory_preflight': memory_plan.as_dict()}), flush=True)
        torch.cuda.reset_peak_memory_stats(device)
    checkpoint_name = f'checkpoint.rank{rank:04d}.pt' if world_size > 1 else 'checkpoint.pt'
    checkpoint_path = out/checkpoint_name
    if checkpoint_path.exists() and not args.resume:
        raise ValueError('existing run: pass --resume to continue without losing replay')
    scene = Path(args.scene).resolve()
    kin = G1Kinematics(device, mjcf_path=str(scene))
    storage = cfg.get('reference_storage', 'eager')
    motion_kwargs = dict(storage=storage,
                         cache_dir=cfg.get('motion_cache_dir') or str(out/'reference-cache'),
                         max_gather_frames=cfg.get('max_reference_gather_frames', 131072))
    if args.motion_manifest:
        motion = MotionLib.from_manifest(args.motion_manifest, kin, device, **motion_kwargs)
    else:
        motion = MotionLib.from_dir(args.motion_dir, kin, device, **motion_kwargs)
    actor_catalog = require_actor_horizon(motion, cfg.get('horizon', 32))
    mdp = MDP(kin, motion, torch.tensor(default_joint_pos_list(), device=device),
              observation_mode=cfg.get('observation_mode', 'paper'))
    learner = AlignedLearner(mdp, cfg, device=device)
    N, H = cfg['num_envs'], cfg.get('hist', 10)
    buffer = ReplayBuffer(cfg.get('buffer_steps', 1000), N, device)
    history = torch.zeros(N, H, mdp.obs_dim, device=device)
    motion_identity = (
        dict(motion_manifest_sha256=digest(args.motion_manifest),
             motion_clip_count=len(motion.names)) if args.motion_manifest else
        dict(motions=[dict(name=p.name, sha256=digest(p))
                      for p in sorted(Path(args.motion_dir).glob('*.csv'))]))
    identity = dict(scene=str(scene), scene_sha256=digest(scene),
        **motion_identity,
        backend=args.backend, device=device, observation_mode=cfg.get('observation_mode', 'paper'),
        physics_substep_seconds=cfg.get('physics_dt', .005),
        context_resampling=cfg.get('context_resampling', 'episode'),
        self_collisions=cfg.get('self_collisions', True))
    if world_size > 1:
        identity['distributed'] = dict(world_size=world_size, rank=rank,
                                       num_envs_per_rank=N, seed=cfg.get('seed', 0) + rank)
        identity['trainer_sources_sha256'] = {
            p.name: digest(p) for p in trainer_sources()}
    if args.backend == 'isaac':
        usd_path = Path(args.usd_path or USD_PATH).expanduser().resolve()
        if not usd_path.is_file():
            raise FileNotFoundError(f'Missing G1 USD asset: {usd_path}')
        identity['usd_path'] = str(usd_path)
        identity['usd_sha256'] = digest(usd_path)
        from .isaac_env import make_isaac_env
        args.device, args.num_envs = device, N
        args.gamma, args.seed = cfg.get('gamma', .99), cfg.get('seed', 0) + rank
        args.max_episode_steps = cfg.get('max_episode_steps', 500)
        args.self_collisions = cfg.get('self_collisions', True)
        args.reset_noise = cfg.get('reset_noise', True)
        args.context_resampling = cfg.get('context_resampling', 'episode')
        args.physics_dt = cfg.get('physics_dt', .005)
        context = make_isaac_env(args, motion, mdp)
    else:
        from .mujoco_env import MujocoTrackingEnv
        context = nullcontext(MujocoTrackingEnv(scene, N, motion, mdp, seed=cfg.get('seed', 0),
            gamma=cfg.get('gamma', .99), self_collisions=cfg.get('self_collisions', True),
            reset_noise=cfg.get('reset_noise', True), max_episode_steps=cfg.get('max_episode_steps', 500),
            physics_dt=cfg.get('physics_dt', .005), context_resampling=cfg.get('context_resampling', 'episode')))
    assert_same_setup(cfg, identity)
    if world_size > 1 and not args.resume:
        broadcast_learner(learner)
    start, step_acc = 0, 0.
    counters = dict(physical_transitions=0, imagined_transitions=0, actor_updates=0, model_updates=0,
                    critic_updates=0, model_fit_transition_slots=0)
    started = time.monotonic()
    with context as env:
        resume_kind = 'fresh'
        if args.resume:
            resume_path = Path(args.resume)
            if resume_path.is_dir():
                resume_path /= checkpoint_name
            if world_size > 1 and resume_path.name != checkpoint_name:
                raise ValueError(f'distributed resume requires this rank checkpoint: {checkpoint_name}')
            ck = torch.load(resume_path, map_location=device, weights_only=False)
            if ck['identity'] != identity or ck['config'] != cfg:
                raise ValueError('resume requires identical config, dataset hashes, scene and backend')
            if world_size > 1:
                assert_same_progress(ck)
            learner.load_state_dict(ck['learner'])
            if world_size > 1:
                assert_same_learner(learner)
            buffer.load_state_dict(ck['replay'])
            result = env.load_state_dict(ck['env'])
            history.copy_(ck['history'])
            start, counters, step_acc = ck['iteration'], ck['counters'], ck['step_acc']
            torch.set_rng_state(ck['torch_rng'].cpu())
            if ck['cuda_rng']:
                torch.cuda.set_rng_state_all(ck['cuda_rng'])
            resume_kind = 'exact' if result.get('exact_resume') else 'warm-reset-refill'
            if resume_kind != 'exact':
                buffer = ReplayBuffer(cfg.get('buffer_steps', 1000), N, device)
                history.zero_()

        @torch.no_grad()
        def collect(steps):
            for _ in range(steps):
                obs = mdp.obs(env.state(), env.a_prev, env.xi, env.f)
                if cfg.get('observation_noise', True):
                    obs = mdp.add_noise(obs)
                history.copy_(torch.where((env.ep_step == 0)[:, None, None],
                    obs[:, None].expand_as(history), torch.cat((history[:, 1:], obs[:, None]), 1)))
                goal = motion.goal(env.f, cfg.get('goal_frames', 10))
                learner.pi.obs_norm.update(obs)
                learner.pi.goal_norm.update(goal)
                action = learner.pi(history, goal)
                action = (action+cfg.get('action_noise', .1)*torch.randn_like(action)).clamp(-20, 20)
                tr = env.step(action)
                buffer.add(tr)
                learner.observe(tr)
                counters['physical_transitions'] += N

        # Readiness depends on replay contents, not iteration number (fixes empty-resume).
        if any_rank_needs_warmup(
                not buffer.can_sample_windows(cfg.get('wm_window', 8)), device):
            collect(max(cfg.get('warmup_steps', 64), cfg.get('wm_window', 8)))
            if world_size > 1:
                synchronize_sampler(env.sampler)
        iterations = args.iterations if args.iterations is not None else cfg['iterations']
        rows = []
        for it in range(start, iterations):
            decay = cfg.get('lr_decay_iters', 250000)
            lr = cfg.get('lr', .0002)*(.03+.97*.5*(1+math.cos(math.pi*min(it/decay, 1))))
            for opt in (learner.opt_wm, learner.opt_pi, learner.opt_v):
                for group in opt.param_groups:
                    group['lr'] = lr
            step_acc += 1/cfg.get('utd', .4)
            n = int(step_acc)
            step_acc -= n
            collect(n)
            if world_size > 1:
                synchronize_sampler(env.sampler)
            actor_readiness = None
            if it >= cfg.get('wm_only_iters', 500):
                actor_readiness = buffer.ensure_actor_ready(
                    motion, cfg.get('horizon', 32), cfg.get('wm_window', 8), collect,
                    any_need=lambda need: any_rank_needs_warmup(need, device),
                    after_collect=lambda: synchronize_sampler(env.sampler) if world_size > 1 else None,
                    context=dict(**actor_catalog, iteration=it+1, rank=rank))
            wm = learner.fit_world_model(buffer)
            counters['model_updates'] += cfg.get('wm_batches', 10)
            counters['model_fit_transition_slots'] += cfg.get('wm_batches', 10)*cfg.get('wm_batch', 2048)*cfg.get('wm_window', 8)
            row = dict(iteration=it+1, world_model=wm, learning_rate=lr,
                       actor_readiness=actor_readiness,
                       actor_readiness_scope='rank-local; extra steps lower effective update/data ratio')
            if it >= cfg.get('wm_only_iters', 500):
                row['policy'] = learner.update_policy(buffer)
                counters['actor_updates'] += 1
                counters['critic_updates'] += row['policy']['critic_updates']
                counters['imagined_transitions'] += cfg.get('pi_batch', 4096)*cfg.get('horizon', 32)
            row = aggregate_row(row, device)
            rows.append(row)
            if rank == 0:
                print(json.dumps(row), flush=True)
            if (it+1) % cfg.get('checkpoint_every', 2000) == 0 or it+1 == iterations:
                ck = checkpoint(learner, buffer, env, history, it+1, counters, cfg, identity, step_acc)
                temporary = out/f'{checkpoint_name}.tmp'
                torch.save(ck, temporary)
                temporary.replace(checkpoint_path)
        totals = global_counters(counters, device)
        report = dict(format='moonrobo.supermimic-aligned-training.v1', profile=cfg.get('profile'),
            identity=identity, config=cfg, resume_kind=resume_kind, iteration=iterations,
            counters=totals, local_counters=counters.copy(),
            wall_seconds_this_invocation=time.monotonic()-started, updates=rows,
            memory_preflight=memory_plan.as_dict() if memory_plan else None,
            result_scope=('runtime-integration gate' if cfg.get('profile') in ('smc-spark-runtime-gate', 'smc-spark-ddp-runtime-gate')
                          else 'method-integration smoke' if cfg.get('profile') in ('cpu-smoke', 'smc-protocol-cpu-check')
                          else 'training'),
            hardware_execution=args.backend == 'isaac', checkpoint_sha256=digest(checkpoint_path))
        if world_size > 1:
            report['distributed'] = dict(world_size=world_size, rank=rank,
                                         metrics_scope='all_ranks_mean', counters_scope='all_ranks',
                                         sampler_sync='average_EMA_between_iterations',
                                         checkpoint_file=checkpoint_name)
        report['physics_settings'] = dict(getattr(env, 'evaluation_settings', {}))
        report['source_files'] = {p.name: digest(p) for p in trainer_sources()}
        report['memory_observed'] = host_memory_observation()
        if device.startswith('cuda'):
            torch.cuda.synchronize(device)
            report['memory_observed']['torch_peak_allocated_bytes'] = torch.cuda.max_memory_allocated(device)
            report['memory_observed']['torch_peak_reserved_bytes'] = torch.cuda.max_memory_reserved(device)
            report['memory_observed']['cuda_free_bytes_after_checkpoint'] = torch.cuda.mem_get_info(device)[0]
        report['parameters'] = {name: sum(p.numel() for p in getattr(learner, name).parameters())
                                for name in ('wm', 'pi', 'critic')}
        report['motion_frames'] = motion.num_frames
        report['dependencies'] = dict(torch=torch.__version__)
        report_path = out/(f'report.rank{rank:04d}.json' if world_size > 1 else 'report.json')
        report_path.write_text(json.dumps(report, indent=2)+'\n')
        if world_size > 1 and rank == 0:
            (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')
        if args.evaluate and rank == 0:
            if args.backend == 'isaac':
                ev = evaluate_policy(env.for_evaluation(), learner.pi, hist=H, goal_frames=cfg.get('goal_frames', 10))
            else:
                from .mujoco_env import MujocoTrackingEnv
                ev_env = MujocoTrackingEnv(scene, 1, motion, mdp, eval_mode=True, auto_reset=False,
                    self_collisions=cfg.get('self_collisions', True), physics_dt=cfg.get('physics_dt', .005),
                    context_resampling=cfg.get('context_resampling', 'episode'))
                ev = evaluate_policy(ev_env, learner.pi, hist=H, goal_frames=cfg.get('goal_frames', 10))
            ev['checkpoint_sha256'], ev['identity'] = report['checkpoint_sha256'], identity
            (out/'evaluation.json').write_text(json.dumps(ev, indent=2)+'\n')
            print(json.dumps({'evaluation_file': str(out/'evaluation.json')}), flush=True)
        # Keep the process group alive while rank zero evaluates. No evaluation
        # code uses collectives; other ranks wait here before clean teardown.
        barrier()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--motion-dir', required=True)
    parser.add_argument('--motion-manifest',
                        help='hash-verified nested G1 catalog; overrides --motion-dir discovery')
    parser.add_argument('--scene', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--backend', choices=['mujoco', 'isaac'], default='mujoco')
    parser.add_argument('--device')
    parser.add_argument('--usd-path')
    parser.add_argument('--resume')
    parser.add_argument('--iterations', type=int, help='total target iteration, not additional iterations')
    parser.add_argument('--evaluate', action='store_true')
    parser.add_argument('--distributed', action='store_true',
                        help='torchrun/NCCL data parallel; config batch and environment sizes are per rank')
    run(parser.parse_args())


if __name__ == '__main__':
    main()
