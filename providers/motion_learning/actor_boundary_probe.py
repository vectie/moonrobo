"""Bounded snapshots of the ORIGINAL compiled SMC actor; never for timing.

All 4096 rows and all 32 steps are retained. Hooks copy values without replacing
outputs or derivatives. The native diagnostic records the same boundaries.
"""
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import torch
from shared_smc_probe_bf16_original import SharedProbe, Meter


def main():
    root = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    torch._inductor.config.trace.enabled = True
    torch._inductor.config.trace.debug_dir = str(root / "compile-debug")
    probe = SharedProbe(Path(os.environ["MOONROBO_SHARED_INPUT"]), compiled=True)
    assert probe.chunk == 4096
    probe.prepare_actor()
    records, used = [], 0

    def capture(name, tensor):
        nonlocal used
        value = tensor.detach().to(device="cpu", dtype=torch.float64).contiguous()
        used += value.numel() * 8
        assert used <= 1024**3 and len(records) < 512
        path = root / (name + ".f64")
        assert not path.exists()
        value.numpy().tofile(path)
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        records.append(dict(name=name, blob=dict(file=path.name, shape=list(value.shape),
            count=value.numel(), byte_length=value.numel()*8, dtype="f64le", sha256=digest)))

    original = probe.ctx["imag_step"]
    step = 0

    def imag(*args):
        nonlocal step
        result = original(*args)
        state, action, history, _, _ = result
        capture(f"step-{step}-action", action)
        for name, value in zip(("p", "r", "v", "w", "q", "qd"), state):
            capture(f"step-{step}-{name}", value)
        # History shift is reconstructible from the previous history + newest obs.
        capture(f"step-{step}-observation", history[:, -1])
        step += 1
        return result

    reward = probe.ctx["reward_term"]

    def reward_term(*args):
        r, d = reward(*args)
        capture("rewards", r.reshape(32, 4096))
        capture("failures", d.reshape(32, 4096))
        return r, d

    clip = torch.nn.utils.clip_grad_norm_

    def clip_norm(parameters, *args, **kwargs):
        parameters = list(parameters)
        if parameters and parameters[0] is next(probe.pi.parameters()):
            for i, p in enumerate(parameters):
                capture(f"raw-policy-{i}", p.grad)
        return clip(parameters, *args, **kwargs)

    probe.ctx["imag_step"], probe.ctx["reward_term"] = imag, reward_term
    torch.nn.utils.clip_grad_norm_ = clip_norm
    try:
        metrics = probe.actor_update(Meter("off"))
    finally:
        torch.nn.utils.clip_grad_norm_ = clip
    assert step == 32
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16*1024**3
    assert torch.cuda.memory_reserved() < 32*1024**3
    (root / "boundaries.json").write_text(json.dumps(dict(records=records, bytes=used), indent=2))
    comparison = []
    native = Path(os.environ["ACTOR_NATIVE_BOUNDARIES"])
    index = {r["name"]: r["blob"] for r in json.loads((native / "boundaries.json").read_text())["records"]}
    for item in records:
        name, blob = item["name"], item["blob"]
        expected = index[name]
        assert expected["shape"] == blob["shape"]
        lhs = np.memmap(native / expected["file"], dtype="<f8", mode="r")
        rhs = np.memmap(root / blob["file"], dtype="<f8", mode="r")
        delta = np.abs(lhs-rhs)
        comparison.append(dict(name=name, max_abs=float(delta.max()),
            unequal=int(np.count_nonzero(lhs != rhs)),
            violations=int(np.count_nonzero(delta > 2e-6+2e-4*np.abs(rhs))),
            count=len(lhs)))
    (root / "result.json").write_text(json.dumps(dict(diagnostic_only=True,
        numerical_pass=all(r["violations"] == 0 for r in comparison),
        metrics=metrics, boundaries=comparison,
        peak_reserved=torch.cuda.max_memory_reserved()), indent=2))


if __name__ == "__main__":
    main()
