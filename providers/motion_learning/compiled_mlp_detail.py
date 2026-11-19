"""Numerical-only repeatability probe of unchanged SMC compiled MLP.

No timing claims: snapshots intentionally synchronize. MoonBit owns orchestration
and the unchanged resource guards. This does not change the production backend.
"""
import hashlib
import json
import os
from pathlib import Path

import torch
from torch import nn
from precision_mlp_probe_a import networks, read_tensor, compare


def digest(tensor):
    raw = tensor.detach().contiguous().view(torch.uint8).cpu().numpy().tobytes()
    return hashlib.sha256(raw).hexdigest()


def main():
    out = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    source = Path(os.environ["MOONROBO_SHARED_INPUT"])
    baseline = Path(os.environ["COMPILED_NATIVE_GATE"])
    assert torch.cuda.mem_get_info()[0] > 24 * 1024**3
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    amp = os.environ["MOONROBO_SHARED_AMP"]
    networks.AMP_DTYPE = torch.bfloat16 if amp == "bf16" else None
    torch._logging.set_logs(output_code=True)
    initial = {r["name"]: r for r in json.loads((source / "initial.json").read_text())["records"]}
    reference = {r["name"]: r for r in json.loads((baseline / "result.json").read_text())["records"]}
    load = lambda name: read_tensor(baseline, reference[name])
    net = networks.mlp(133, [2048, 2048, 2048], 70, act=nn.SiLU, layer_norm=True).cuda()
    with torch.no_grad():
        for i, p in enumerate(net.parameters()):
            p.copy_(read_tensor(source, initial[f"world-{i}-parameter"]))
    x, dy = load("x").requires_grad_(), load("dy")
    expected = {name: load(name) for name in ["y", "dx", *[f"dp-{i}" for i in range(14)]]}
    forward = torch.compile(lambda x: networks.run_mlp(net, x))
    rows, checks, first_dx = [], [], None
    # Preserve the original uninterrupted 60-call workload before adding
    # snapshot traffic. The second block observes every call in the same process.
    for block in ("uninterrupted", "observed"):
        for rep in range(60):
            x.grad = None
            net.zero_grad(set_to_none=True)
            torch.cuda.synchronize()
            assert torch.cuda.mem_get_info()[0] > 16 * 1024**3
            assert torch.cuda.memory_reserved() < 32 * 1024**3
            y = forward(x)
            (y * dy).sum().backward()
            torch.cuda.synchronize()
            if block == "observed" or rep == 59:
                if first_dx is None:
                    first_dx = x.grad.detach().clone()
                rows.append(dict(block=block, rep=rep, dx_sha256=digest(x.grad),
                    native=compare("dx", x.grad, expected["dx"]),
                    first=compare("dx", x.grad, first_dx)))
        checks += [dict(block=block, **compare("y", y, expected["y"]))]
        checks += [dict(block=block, **compare(f"dp-{i}", p.grad, expected[f"dp-{i}"]))
                   for i, p in enumerate(net.parameters())]
    # Retain the actual input gradient for the later same-kernel VJP diagnosis.
    torch.save(dict(x=x.detach().cpu(), dy=dy.cpu(), dx=x.grad.detach().cpu()), out / "numerical.pt")
    (out / "result.json").write_text(json.dumps(dict(
        passed=True, diagnostic_only=True, acceptance_not_implied=True, amp=amp,
        torch=torch.__version__, rows=rows, checks=checks,
        generated_source="output_code records in training.stderr.log",
        inputs=dict(x=digest(x), dy=digest(dy), parameters=[digest(p) for p in net.parameters()]),
        settings=dict(tf32=torch.backends.cuda.matmul.allow_tf32,
            bf16_reduced_precision_reduction=torch.backends.cuda.matmul.allow_bf16_reduced_precision_reduction,
            deterministic=torch.are_deterministic_algorithms_enabled()),
        reserved_peak=torch.cuda.max_memory_reserved()), indent=2))


if __name__ == "__main__":
    main()
