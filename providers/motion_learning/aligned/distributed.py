"""Minimal synchronous NCCL data parallel support for the aligned learner.

The world model's ``step`` method and the policy's recurrent imagination do
not enter through a single ``nn.Module.forward`` call.  Consequently PyTorch
DDP hooks would not cover these graphs; gradients are reduced explicitly at
the optimizer boundary instead.  Every rank owns one simulator and replay.
"""

from __future__ import annotations

import os
import hashlib
import json

import torch
import torch.distributed as dist


def setup(enabled: bool, backend: str, requested_device: str | None):
    """Initialize from torchrun, returning (device, rank, world_size)."""
    if not enabled:
        return requested_device or ('cuda:0' if backend == 'isaac' else 'cpu'), 0, 1
    if backend != 'isaac':
        raise ValueError('--distributed currently requires the Isaac CUDA backend')
    if not torch.cuda.is_available():
        raise RuntimeError('NCCL distributed training requires CUDA on every rank')
    for key in ('RANK', 'LOCAL_RANK', 'WORLD_SIZE', 'MASTER_ADDR', 'MASTER_PORT'):
        if key not in os.environ:
            raise ValueError(f'--distributed must be launched through torchrun: missing {key}')
    rank = int(os.environ['RANK'])
    local_rank = int(os.environ['LOCAL_RANK'])
    world_size = int(os.environ['WORLD_SIZE'])
    if world_size < 2 or local_rank >= torch.cuda.device_count():
        raise ValueError('distributed run needs at least two ranks and one CUDA GPU per local rank')
    device = f'cuda:{local_rank}'
    if requested_device is not None and torch.device(requested_device) != torch.device(device):
        raise ValueError(f'--device must match torchrun LOCAL_RANK ({device})')
    torch.cuda.set_device(local_rank)
    dist.init_process_group(backend='nccl', init_method='env://')
    return device, rank, world_size


def teardown():
    if dist.is_available() and dist.is_initialized():
        dist.destroy_process_group()


def barrier():
    if dist.is_available() and dist.is_initialized():
        dist.barrier()


@torch.no_grad()
def broadcast_learner(learner):
    """Start every rank from rank zero parameters and normalizer buffers."""
    if not dist.is_available() or not dist.is_initialized():
        return
    for module in (learner.wm, learner.pi, learner.critic):
        for value in module.state_dict().values():
            if torch.is_tensor(value):
                dist.broadcast(value, src=0)


@torch.no_grad()
def average_gradients(module):
    """Average a module's gradients before global clipping and optimizer step."""
    if not dist.is_available() or not dist.is_initialized():
        return
    params = [p for p in module.parameters() if p.requires_grad]
    if not params:
        return
    # All ranks run the same graph. Treat an unused parameter as zero so its
    # presence on another rank cannot alter collective order or deadlock.
    flat = torch.cat([(p.grad if p.grad is not None else torch.zeros_like(p)).reshape(-1)
                      for p in params])
    dist.all_reduce(flat, op=dist.ReduceOp.SUM)
    flat /= dist.get_world_size()
    offset = 0
    for p in params:
        count = p.numel()
        if p.grad is None:
            p.grad = flat[offset:offset + count].reshape_as(p).clone()
        else:
            p.grad.copy_(flat[offset:offset + count].reshape_as(p))
        offset += count


def global_counters(counters: dict, device: str):
    if not dist.is_available() or not dist.is_initialized():
        return counters.copy()
    keys = sorted(counters)
    values = torch.tensor([counters[key] for key in keys], device=device, dtype=torch.long)
    dist.all_reduce(values, op=dist.ReduceOp.SUM)
    return dict(zip(keys, values.cpu().tolist()))


def aggregate_row(row: dict, device: str):
    """Report the arithmetic mean of per-rank losses and rollout diagnostics."""
    if not dist.is_available() or not dist.is_initialized():
        return row
    locations = [('world_model', 'wm_loss'), ('world_model', 'wm_err8')]
    if 'policy' in row:
        locations.extend(('policy', key) for key in
                         ('pi_loss', 'v_loss', 'imag_rew', 'pi_gradnorm', 'imag_survival'))
    values = torch.tensor([row[section][key] for section, key in locations],
                          device=device, dtype=torch.float64)
    dist.all_reduce(values, op=dist.ReduceOp.SUM)
    values /= dist.get_world_size()
    for (section, key), value in zip(locations, values.tolist()):
        row[section][key] = value
    return row


def any_rank_needs_warmup(local_need: bool, device: str):
    if not dist.is_available() or not dist.is_initialized():
        return local_need
    flag = torch.tensor(int(local_need), device=device, dtype=torch.int32)
    dist.all_reduce(flag, op=dist.ReduceOp.MAX)
    return bool(flag.item())


def assert_same_setup(config: dict, identity: dict):
    """Reject mixed configs/assets before collecting different training data."""
    if not dist.is_initialized():
        return
    comparable = {k: v for k, v in identity.items()
                  if k not in ('scene', 'usd_path', 'rank', 'distributed')}
    # Absolute asset paths may legitimately differ between nodes; hashes may not.
    raw = json.dumps([config, comparable], sort_keys=True, default=str).encode()
    signatures = [None] * dist.get_world_size()
    dist.all_gather_object(signatures, hashlib.sha256(raw).hexdigest())
    if len(set(signatures)) != 1:
        raise ValueError('distributed ranks have different configs or asset hashes')


def assert_same_learner(learner):
    """Resume must not silently combine different weights or Adam moments."""
    if not dist.is_initialized():
        return
    signature = hashlib.sha256()

    def add(value):
        if torch.is_tensor(value):
            signature.update(f'T:{value.dtype}:{tuple(value.shape)}:'.encode())
            # RunningNorm.count and Adam's step are zero-dimensional tensors.
            # Dtype-changing view requires at least one dimension; retain the
            # original shape above, then flatten solely for the byte encoding.
            signature.update(value.detach().contiguous().reshape(-1).view(torch.uint8).cpu().numpy().tobytes())
        elif isinstance(value, dict):
            signature.update(b'D{')
            for key in sorted(value, key=str):
                add(key)
                add(value[key])
            signature.update(b'}')
        elif isinstance(value, (list, tuple)):
            signature.update(b'L[' if isinstance(value, list) else b'Q(')
            for item in value:
                add(item)
            signature.update(b']' if isinstance(value, list) else b')')
        else:
            signature.update(json.dumps(value, sort_keys=True, default=str).encode())
            signature.update(b';')

    add(learner.state_dict())
    signatures = [None] * dist.get_world_size()
    dist.all_gather_object(signatures, signature.hexdigest())
    if len(set(signatures)) != 1:
        raise ValueError('distributed rank checkpoints have different learner or optimizer state')


def assert_same_progress(checkpoint: dict):
    if not dist.is_initialized():
        return
    progress = (int(checkpoint['iteration']), float(checkpoint['step_acc']))
    values = [None] * dist.get_world_size()
    dist.all_gather_object(values, progress)
    if len(set(values)) != 1:
        raise ValueError('distributed rank checkpoints have different iteration or UTD progress')


@torch.no_grad()
def synchronize_sampler(sampler):
    """Align reset difficulty estimates between iterations.

    Episodes finish asynchronously within an iteration. Each rank updates its
    local EMA immediately for local resets; we average the estimates before
    the next iteration. Generator and completion counters remain rank-local.
    """
    if not dist.is_initialized():
        return
    world = dist.get_world_size()
    for name in ('bin_G', 'bin_w_avg'):
        value = getattr(sampler, name)
        dist.all_reduce(value, op=dist.ReduceOp.SUM)
        value /= world
