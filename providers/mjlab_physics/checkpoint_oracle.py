"""Compute independent inference targets with the pinned author's G1 modules."""
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import torch
from tensordict import TensorDict
from supermimic.models import Dynamics, MultiEncoderAE, build_mlp
from supermimic.representations import GenCoordRepresentation, _assemble_goal


def _archive(path):
    return torch.jit.load(str(path), map_location="cpu")


def _weights(root, name, networks):
    # The MoonBit learner stores interior Linear matrices in its Muon group.
    adam = _archive(root / (name + ".adam"))
    i, m = 0, 0
    for layers in networks:
        linear = [layer for layer in layers if isinstance(layer, torch.nn.Linear)]
        for layer in layers:
            for key, param in layer.named_parameters(recurse=False):
                if key == "weight" and layer in linear[1:-1]:
                    saved = _archive(root / f"{name}.muon-{m}.weight").tensor
                    m += 1
                else:
                    saved = getattr(adam, f"parameter_{i}")
                    i += 1
                assert saved.shape == param.shape
                param.copy_(saved)
    assert i == adam.count


@torch.no_grad()
def write_oracle(checkpoint, corpus, output):
    torch.set_num_threads(1)
    root, ref = Path(checkpoint), Path(corpus)
    index = json.loads((root / "complete.json").read_bytes())
    assert index["format"] == "moonrobo.author-gencoord.weights.v2"
    scale = _archive(root / "action-scale").tensor
    offset = _archive(root / "action-offset").tensor
    rep = GenCoordRepresentation(29, offset)
    rep.dt, rep.substep_coeff = 0.02, 0.625
    wm = Dynamics(rep, 29, 33, scale, offset, (2048,) * 3)
    specs = [SimpleNamespace(name="motion", goal_dim=640), SimpleNamespace(name="velocity", goal_dim=3)]
    actor = MultiEncoderAE(68, 29, specs, {"motion": 1.0, "velocity": 0.0},
                           32, (2048, 1024, 512, 256), 0.1, 1)
    critic = build_mlp(68 + 670 + 33, (256, 128), 1)
    _weights(root, "world", [wm.mlp])
    _weights(root, "actor", [actor.encoders["motion"], actor.decoder])
    _weights(root, "critic", [critic])
    for i, norm in enumerate([wm.state_normalizer, wm.action_normalizer, actor.obs_normalizer,
                              actor.goal_normalizers["motion"]]):
        mean = _archive(root / f"mean-{i}").tensor
        var = _archive(root / f"variance-{i}").tensor
        norm._mean.copy_(mean.reshape_as(norm._mean))
        norm._var.copy_(var.reshape_as(norm._var))
        norm._std.copy_(var.sqrt().reshape_as(norm._std))
    actor.eval()
    wm.eval()
    ends = np.load(ref / "motion_ends.npy", mmap_mode="r")
    # Interior and near-end frames from different clips, including a padded preview.
    ix = np.linspace(0, len(ends) - 1, 8, dtype=int)
    first = np.where(ix == 0, 0, ends[np.maximum(ix-1, 0)])
    last = ends[ix] - 1
    t = first + (last-first) // 2
    t[::2] = last[::2] - 1
    indices = np.minimum(t[:, None] + 5 * np.arange(10), last[:, None])
    fields = [np.load(ref / (k + ".npy"), mmap_mode="r") for k in (
        "root_pos_w", "root_quat_w", "root_lin_vel_w", "root_ang_vel_w", "joint_pos", "joint_vel")]
    flat = torch.from_numpy(np.concatenate([x[np.maximum(t-3, first)] for x in fields], axis=-1))
    window = torch.from_numpy(np.concatenate([x[indices] for x in fields], axis=-1))
    original = torch.cat((flat[:, :7], flat[:, 13:42], flat[:, 7:13], flat[:, 42:]), -1)
    aux, state = rep.extract_aux_state(original), rep.represent(original)
    n = len(ix)
    world, goal = _assemble_goal(window[:, :, 13:].reshape(n, -1), aux[:, :3], aux[:, 3:],
                                 window[:, :, :3], window[:, :, 3:7])
    # Fixed nonzero conditioning shared by both implementations.
    ctx = ((torch.arange(n * 33).reshape(n, 33) % 13).float() - 6) / 120
    ctx[:, 0] = 1.0
    act = actor(TensorDict({"goal_motion": goal, "history": state.unsqueeze(1)},
                           batch_size=[n], device="cpu"))
    value = critic(torch.cat((state, world, ctx), -1))
    next_aux, next_state = wm(state, act, aux, ctx)
    tensors = dict(flat=flat, window=window, context=ctx, action=act, value=value,
                   next_aux=next_aux, next_reduced=next_state)
    result = dict(rows=n, physical_steps=index["physical_steps"], learner_updates=index["updates"],
                  clip_indices=ix.tolist(), frames=t.tolist(),
                  **{k: v.reshape(-1).tolist() for k, v in tensors.items()})
    with Path(output).open("x") as f:
        json.dump(result, f, separators=(",", ":"))


if __name__ == "__main__":
    write_oracle(*sys.argv[1:])
