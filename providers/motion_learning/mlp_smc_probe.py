"""Numerical MLP adapter; all deployment/guards/orchestration are in .mbtx.

Use SMC's actual mlp factory with fixed exported inputs, upstream gradients and
iteration-60 weights. Keep expanded-baseline differences visible separately
from the native-ATen versus SMC acceptance gate.
"""
import hashlib
import inspect
import json
import os
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from shared_smc_probe_v17 import networks


def read_tensor(root, record):
    b = record["blob"]
    assert b["dtype"] == "f64le" and 0 < int(b["count"]) <= 16777216
    path = root / b["file"]
    assert path.parent == root and path.stat().st_size == int(b["count"]) * 8
    with path.open("rb") as f:
        assert hashlib.file_digest(f, "sha256").hexdigest() == b["sha256"]
    a = np.fromfile(path, dtype="<f8").reshape(b["shape"])
    return torch.from_numpy(a).to(device="cuda", dtype=torch.float32)


def compare(name, actual, expected):
    a, b = actual.detach().flatten(), expected.flatten()
    violations, maximum, over, nonfinite = 0, 0., 0., 0
    for start in range(0, a.numel(), 65536):
        x = a[start:start+65536].double().cpu().numpy()
        y = b[start:start+65536].double().cpu().numpy()
        delta, limit = np.abs(x-y), 2e-6 + 2e-4*np.abs(y)
        nonfinite += int(np.count_nonzero(~np.isfinite(x) | ~np.isfinite(y)))
        violations += int(np.count_nonzero(delta > limit))
        maximum, over = max(maximum, float(delta.max())), max(over, float((delta/limit).max()))
    return dict(name=name, elements=a.numel(), violations=violations, nonfinite=nonfinite,
                max_abs=maximum, max_over_bound=over)


def main():
    out = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    source = Path(os.environ["MOONROBO_SHARED_INPUT"])
    baseline = Path(os.environ["MLP_NATIVE_GATE"])
    mode = os.environ["MOONROBO_MLP_MODE"]
    compiled = os.environ.get("MLP_COMPILED", "0") == "1"
    events = os.environ.get("MOONROBO_MLP_EVENTS", "0") == "1"
    assert mode in ("gate", "world", "actor") and not (out / "result.json").exists()
    assert torch.cuda.mem_get_info()[0] > 64 * 1024**3
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    networks.AMP_DTYPE = None
    initial = {r["name"]: r for r in json.loads((source / "initial.json").read_text())["records"]}
    reference = {r["name"]: r for r in json.loads((baseline / "result.json").read_text())["records"]}
    load = lambda name: read_tensor(baseline, reference[name])
    checks, cases = [], []
    if mode == "gate":
        for width in (4, 2048):
            for fixture in range(3):
                prefix = f"ln-{width}-{fixture}-"
                x = load(prefix+"x").requires_grad_()
                ln = nn.LayerNorm(width, eps=1e-5).cuda()
                with torch.no_grad():
                    ln.weight.copy_(load(prefix+"w"))
                    ln.bias.copy_(load(prefix+"b"))
                y = ln(x)
                (y * load(prefix+"dy")).sum().backward()
                for name, actual in (("y", y), ("dx", x.grad), ("dw", ln.weight.grad), ("db", ln.bias.grad)):
                    checks.append(compare(prefix+name, actual, load(prefix+name)))
    for task in (("world", "actor") if mode == "gate" else (mode,)):
        net = networks.mlp(133, [2048, 2048, 2048], 70, act=nn.SiLU, layer_norm=True).cuda()
        for i, p in enumerate(net.parameters()):
            with torch.no_grad():
                p.copy_(read_tensor(source, initial[f"world-{i}-parameter"]))
            p.requires_grad_(task == "world")
        forward = torch.compile(net) if compiled else net
        x = load(task+"-x").requires_grad_()
        dy = load(task+"-dy")
        chunk = 2048 if task == "world" else 512
        rows = []
        for rep in range(1 if mode == "gate" else 60):
            x.grad = None
            net.zero_grad(set_to_none=True)
            torch.cuda.synchronize()
            assert torch.cuda.mem_get_info()[0] > 16 * 1024**3
            spans = []
            outputs = []
            start = time.perf_counter_ns()
            for block, offset in enumerate(range(0, x.shape[0], chunk)):
                ev = [torch.cuda.Event(enable_timing=True) for _ in range(3)] if events else None
                if ev: ev[0].record()
                y = forward(x.narrow(0, offset, chunk))
                loss = (y * dy.narrow(0, offset, chunk)).sum()
                if ev: ev[1].record()
                loss.backward()
                if ev: ev[2].record(); spans.append(ev)
                if mode == "gate": outputs.append(y.detach())
            submit = time.perf_counter_ns()
            torch.cuda.synchronize()
            end = time.perf_counter_ns()
            rows.append(dict(rep=rep, steady=rep >= 10, wall_ms=(end-start)/1e6,
                             submit_ms=(submit-start)/1e6,
                             forward_ms=sum(a.elapsed_time(b) for a,b,c in spans) if events else None,
                             backward_ms=sum(b.elapsed_time(c) for a,b,c in spans) if events else None))
            if mode == "gate":
                for block, y in enumerate(outputs):
                    checks.append(compare(f"{task}-y-{block}", y, load(f"{task}-y-{block}")))
                checks.append(compare(task+"-dx", x.grad, load(task+"-dx")))
                if task == "world":
                    for i, p in enumerate(net.parameters()):
                        checks.append(compare(f"world-dp-{i}", p.grad, load(f"world-dp-{i}")))
        cases.append(dict(task=task, batch=x.shape[0], microbatch=chunk, rows=rows))
    passed = all(c["violations"] == 0 and c["nonfinite"] == 0 for c in checks)
    result = dict(mode=mode, compiled=compiled, checks=checks, passed=passed,
                  atol=2e-6, rtol=2e-4, cases=cases,
                  memory=dict(allocated_peak=torch.cuda.max_memory_allocated(),
                              reserved_peak=torch.cuda.max_memory_reserved(),
                              free=torch.cuda.mem_get_info()[0]),
                  implementation=dict(layernorm=inspect.getsource(nn.LayerNorm.forward),
                                      functional=inspect.getsource(torch.nn.functional.layer_norm),
                                      mlp=inspect.getsource(networks.mlp), torch=torch.__version__))
    (out / "result.json").write_text(json.dumps(result, indent=2))
    assert passed, "SMC/native MLP numerical gate failed; evidence retained"


if __name__ == "__main__":
    main()
