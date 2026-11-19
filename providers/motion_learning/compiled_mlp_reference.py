"""Original SMC compiled MLP numerical reference and bounded timing adapter."""
import json
import os
import time
from pathlib import Path
import torch
from torch import nn
from precision_mlp_probe_a import networks, read_tensor, compare


def main():
    out = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    source = Path(os.environ["MOONROBO_SHARED_INPUT"])
    baseline = Path(os.environ["COMPILED_NATIVE_GATE"])
    gate = os.environ["MOONROBO_COMPILED_GATE"] == "1"
    amp = os.environ["MOONROBO_SHARED_AMP"]
    assert torch.cuda.mem_get_info()[0] > 24 * 1024**3
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    networks.AMP_DTYPE = torch.bfloat16 if amp == "bf16" else None
    initial = {r["name"]: r for r in json.loads((source / "initial.json").read_text())["records"]}
    reference = {r["name"]: r for r in json.loads((baseline / "result.json").read_text())["records"]}
    load = lambda name: read_tensor(baseline, reference[name])
    net = networks.mlp(133, [2048, 2048, 2048], 70, act=nn.SiLU, layer_norm=True).cuda()
    with torch.no_grad():
        for i, p in enumerate(net.parameters()):
            p.copy_(read_tensor(source, initial[f"world-{i}-parameter"]))
    x, dy = load("x").requires_grad_(), load("dy")
    forward = torch.compile(lambda x: networks.run_mlp(net, x))
    rows = []
    for rep in range(60 if not gate else 2):
        x.grad = None
        net.zero_grad(set_to_none=True)
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0] > 16 * 1024**3
        assert torch.cuda.memory_reserved() < 32 * 1024**3
        start = time.perf_counter_ns()
        y = forward(x)
        (y * dy).sum().backward()
        torch.cuda.synchronize()
        rows.append(dict(rep=rep, steady=rep >= 10, wall_ms=(time.perf_counter_ns()-start)/1e6))
    checks = [compare("y", y, load("y")), compare("dx", x.grad, load("dx"))]
    checks += [compare(f"dp-{i}", p.grad, load(f"dp-{i}")) for i, p in enumerate(net.parameters())]
    # Native Adam has its own separately tested gate. Here isolate freshness:
    # load precisely the native updated weights, then rerun the original graph.
    with torch.no_grad():
        for i, p in enumerate(net.parameters()):
            p.copy_(load(f"updated-p-{i}"))
    checks.append(compare("updated-y", forward(x), load("updated-y")))
    passed = all(c["violations"] == 0 and c["nonfinite"] == 0 for c in checks)
    (out / "result.json").write_text(json.dumps(dict(passed=passed, checks=checks, rows=rows,
        amp=amp, torch=torch.__version__, reserved_peak=torch.cuda.max_memory_reserved()), indent=2))
    assert passed, "original compiled SMC numerical gate failed; do not enable"


if __name__ == "__main__":
    main()
