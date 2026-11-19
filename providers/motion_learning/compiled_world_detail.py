"""Separate rollout and loss VJPs on the same tensors; diagnostic, not training.

Original SMC rollout/error AST and original torch.compile boundaries are retained.
The AOTI calls mirror native saved-layout restoration. No optimizer is run here.
"""
import ast
import json
import os
from pathlib import Path
from types import SimpleNamespace

import torch
from torch.utils._python_dispatch import TorchDispatchMode
from precision_mlp_probe_a import read_tensor, compare
from shared_smc_probe_bf16_original import networks, WorldModel, unflatten_state, normalize_xi


class Pair:
    def __init__(self, path):
        self.manifest = json.loads((path / "manifest.json").read_text())
        self.fw = torch._C._aoti.AOTIModelContainerRunnerCuda(str(path / "forward.so"), 1, "cuda:0", str(path))
        self.bw = torch._C._aoti.AOTIModelContainerRunnerCuda(str(path / "backward.so"), 1, "cuda:0", str(path))
        self.layouts = []

    def forward(self, args):
        self.values = self.fw.run(list(args))
        return tuple(self.values[:self.manifest["output_count"]])

    def backward(self, upstream):
        args = self.values[self.manifest["output_count"]:] + [v.contiguous() for v in upstream]
        specs = self.manifest["graphs"]["backward"]["inputs"]
        assert len(args) == len(specs)
        for i, (arg, spec) in enumerate(zip(args, specs)):
            assert list(arg.shape) == spec["shape"] and str(arg.dtype) == spec["dtype"]
            if list(arg.stride()) != spec["stride"]:
                self.layouts.append(dict(index=i, actual=list(arg.stride()), expected=spec["stride"]))
                args[i] = torch.empty_strided(spec["shape"], spec["stride"], device=arg.device, dtype=arg.dtype).copy_(arg)
        result = self.bw.run(args)
        assert len(result) == len(self.manifest["gradient_indices"])
        return tuple(result)


def memory():
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16 * 1024**3
    assert torch.cuda.memory_reserved() < 32 * 1024**3


class MatmulTrace(TorchDispatchMode):
    """Bounded numerical interception, never used for timing or training."""
    def __init__(self):
        super().__init__()
        self.values = []

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        result = func(*args, **(kwargs or {}))
        if func in (torch.ops.aten.mm.default, torch.ops.aten.mm.out):
            assert len(self.values) < 96
            tensors = [args[0], args[1], result]
            assert all(t.numel() <= 4194304 for t in tensors)
            self.values.append([(t.detach().cpu(), list(t.stride())) for t in tensors])
        return result


def main():
    out, source = Path(os.environ["MOONROBO_SHARED_OUTPUT"]), Path(os.environ["MOONROBO_SHARED_INPUT"])
    package = Path("/workspace/moonrobo/runs/hotspot-mlp-aoti-window-export-bf16-g")
    assert torch.cuda.mem_get_info()[0] > 24 * 1024**3
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    networks.AMP_DTYPE = torch.bfloat16
    torch._inductor.config.trace.enabled = True
    torch._inductor.config.trace.debug_dir = str(out / "compile-debug")
    fixture = json.loads((source / "fixture.json").read_text())
    initial = json.loads((source / "initial.json").read_text())
    records = {r["name"]: r for r in fixture["records"] + initial["records"]}
    load = lambda name: read_tensor(source, records[name])
    wm = WorldModel().cuda()
    with torch.no_grad():
        for i, p in enumerate(wm.parameters()):
            p.copy_(load(f"world-{i}-parameter"))
        for norm, saved in zip((wm.in_norm, wm.out_norm), fixture["metadata"]["normalizers"][:2]):
            norm.mean.copy_(torch.tensor(saved["mean"], device="cuda"))
            norm.var.copy_(torch.tensor(saved["variance"], device="cuda"))
    ctx = dict(torch=torch, wm=wm, unflatten_state=unflatten_state, normalize_xi=normalize_xi,
               args=SimpleNamespace(wm_window=8),
               ERR_FLOOR=torch.tensor([.003]*3+[.005]*3+[.02]*3+[.05]*3+[.003]*29+[.05]*29, device="cuda"))
    tree = ast.parse(Path(os.environ["SHARED_SMC_TRAIN"]).read_text())
    definitions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in ("_wm_rollout", "_wm_err")]
    assert len(definitions) == 2
    exec(compile(ast.Module(body=definitions, type_ignores=[]), "original-smc-world-boundaries", "exec"), ctx)
    rollout, error = torch.compile(ctx["_wm_rollout"]), torch.compile(ctx["_wm_err"])
    params = tuple(wm.parameters())
    s, a, xi, target, mask = (load("world-"+k) for k in ("s", "actions", "xi", "s1", "mask"))
    native_rollout, native_error = Pair(package / "rollout"), Pair(package / "error")
    native_pred = native_rollout.forward([s, a, xi, *params, wm.in_norm.mean, wm.in_norm.var, wm.out_norm.mean, wm.out_norm.var])
    smc_pred = rollout(s, a, xi)
    sections = {}

    def record(name, actual, expected, labels):
        memory()
        assert len(actual) == len(expected) == len(labels)
        rows = [compare(label, x.detach(), y.detach()) for label, x, y in zip(labels, actual, expected)]
        sections[name] = rows
        (out / "progress.json").write_text(json.dumps(sections, indent=2))
        print(name, "violations", sum(r["violations"] for r in rows), "max_abs", max(r["max_abs"] for r in rows), flush=True)

    state_names = ("p", "r", "v", "w", "q", "qd")
    weights = [f"world-{i}" for i in range(14)]
    record("rollout_forward", native_pred, smc_pred, state_names)
    record("rollout_forward_steps", [x[:,j] for x in native_pred for j in range(8)],
           [x[:,j] for x in smc_pred for j in range(8)], [f"{k}-{j}" for k in state_names for j in range(8)])
    # Exact SAME predictions for both error functions isolates their derivatives
    # from differences produced by the rollout. The target/mask are identical.
    common_pred = tuple(x.detach().requires_grad_() for x in native_pred)
    smc_loss, smc_last = error(common_pred, target, mask)
    smc_error_grad = torch.autograd.grad(smc_loss, common_pred)
    native_loss = native_error.forward([*common_pred, target, mask, wm.out_norm.var, ctx["ERR_FLOOR"]])[0]
    native_error_grad = native_error.backward([torch.tensor([1.,0.], device="cuda")])
    record("error_same_input_value", [native_loss[0]], [smc_loss], ["loss"])
    record("error_same_input_vjp", native_error_grad, smc_error_grad, state_names)
    # SAME cotangents remove the error VJP as a possible explanation.
    native_grad = native_rollout.backward(smc_error_grad)
    smc_grad = torch.autograd.grad(smc_pred, params, smc_error_grad, retain_graph=True)
    record("rollout_same_cotangent_vjp", native_grad, smc_grad, weights)
    native_with_own_error = native_rollout.backward(native_error_grad)
    record("error_contribution_to_native_vjp", native_with_own_error, native_grad, weights)
    # Recreate the complete SMC gradient with its own predictions and error,
    # while keeping the original rollout and error compile boundaries.
    smc_own_pred = tuple(x.detach().requires_grad_() for x in smc_pred)
    smc_own_loss, _ = error(smc_own_pred, target, mask)
    smc_own_error = torch.autograd.grad(smc_own_loss, smc_own_pred)
    smc_complete = torch.autograd.grad(smc_pred, params, smc_own_error, retain_graph=True)
    record("complete_unclipped_vjp", native_with_own_error, smc_complete, weights)
    def clipped(values):
        norm = torch.linalg.vector_norm(torch.stack([torch.linalg.vector_norm(g, 2) for g in values]), 2)
        scale = (1. / (norm + 1.e-6)).clamp(max=1.)
        return [g*scale for g in values]
    record("complete_clipped_vjp", clipped(native_with_own_error), clipped(smc_complete), weights)
    # Isolate which terminal time slices introduce a VJP discrepancy. These
    # are diagnostic impulses, not a replacement training objective.
    native_sum, smc_sum = [torch.zeros_like(p) for p in params], [torch.zeros_like(p) for p in params]
    for j in range(8):
        cotangents = [torch.zeros_like(v) for v in smc_error_grad]
        for dst, src in zip(cotangents, smc_error_grad):
            dst[:,j].copy_(src[:,j])
        ng = native_rollout.backward(cotangents)
        sg = torch.autograd.grad(smc_pred, params, cotangents, retain_graph=j<7)
        record(f"rollout_impulse_{j}", ng, sg, weights)
        for n, r, gn, gr in zip(native_sum, smc_sum, ng, sg):
            n.add_(gn); r.add_(gr)
    record("native_sum_impulses_vs_joint", native_sum, native_grad, weights)
    record("smc_sum_impulses_vs_joint", smc_sum, smc_grad, weights)
    # The Python observer sees SMC mm but not AOTI shim calls on Torch 2.11.
    # Retain the failed diagnostic as an explicit opt-in, disabled by default;
    # unequal/empty counts must never be reported as paired operator evidence.
    capture = os.environ.get("MOONROBO_CAPTURE_WORLD_MM", "0") == "1"
    native_mm, smc_mm = MatmulTrace(), MatmulTrace()
    if capture:
        smc_trace_pred = rollout(s, a, xi)
        with native_mm:
            native_rollout.backward(smc_error_grad)
        with smc_mm:
            torch.autograd.grad(smc_trace_pred, params, smc_error_grad)
    matrix_rows = []
    for i, (left, right) in enumerate(zip(native_mm.values, smc_mm.values)):
        row = dict(index=i, values=[])
        for name, (n, ns), (r, rs) in zip(("a", "b", "out"), left, right):
            item = dict(name=name, native_shape=list(n.shape), smc_shape=list(r.shape), native_stride=ns, smc_stride=rs)
            if n.shape == r.shape:
                item["comparison"] = compare(name, n, r)
            row["values"].append(item)
        matrix_rows.append(row)
    (out / "matmul-boundaries.json").write_text(json.dumps(dict(
        native_count=len(native_mm.values), smc_count=len(smc_mm.values), rows=matrix_rows,
        attempted=capture, paired_capture_complete=capture and len(native_mm.values)==len(smc_mm.values)==63,
        diagnostic_only=True, no_timing_claim=True), indent=2))
    memory()
    (out / "result.json").write_text(json.dumps(dict(passed=True, diagnostic_only=True,
        acceptance_not_implied=True, sections=sections, torch=torch.__version__,
        layouts=dict(rollout=native_rollout.layouts,error=native_error.layouts),
        matrix_counts=dict(native=len(native_mm.values),smc=len(smc_mm.values)),
        reserved_peak=torch.cuda.max_memory_reserved()), indent=2))
    # AOTI runners own cubins. Ensure all launches finish before their teardown.
    torch.cuda.synchronize()


if __name__ == "__main__":
    main()
