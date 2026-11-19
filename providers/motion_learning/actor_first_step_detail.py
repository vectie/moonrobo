"""Compare actual generated SMC first-step GEMMs with native-equivalent eager.

The eager policy result must match the native executable's captured action
bitwise before any internal eager value is used as native evidence.
"""
import hashlib
import inspect
import json
import os
from pathlib import Path

import numpy as np
import torch
from torch.utils._python_dispatch import TorchDispatchMode
from shared_smc_probe_bf16_original import SharedProbe, unflatten_state, normalize_xi


def stats(a, b):
    assert a.shape == b.shape
    a, b = a.float(), b.float()
    delta = (a-b).abs()
    return dict(shape=list(a.shape), unequal=int((a!=b).sum()),
        violations=int((delta>2e-6+2e-4*b.abs()).sum()), max_abs=float(delta.max()))


class Matrices(TorchDispatchMode):
    def __init__(self, generated=False):
        super().__init__()
        self.rows, self.paths, self.kernels, self.used = [], set(), {}, 0
        self.generated = generated

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        output = func(*args, **(kwargs or {}))
        if func in (torch.ops.aten.mm.default, torch.ops.aten.mm.out,
                    torch.ops.aten.addmm.default, torch.ops.aten.addmm.out):
            self.record(func, args, output)
        return output

    def record(self, func, args, output):
            assert len(self.rows) < 20
            operands = args[:3] if "addmm" in str(func) else args[:2]
            values = []
            for tensor in (*operands, output):
                self.used += tensor.numel()*tensor.element_size()
                assert self.used <= 1536*1024**2
                values.append(tensor.detach().cpu().contiguous())
            self.rows.append(dict(kind=str(func), values=values))
            if self.generated:
                frame = inspect.currentframe().f_back
                while frame:
                    if "/inductor-cache/" in frame.f_code.co_filename:
                        self.paths.add(frame.f_code.co_filename)
                        for name, kernel in frame.f_globals.items():
                            if name.startswith("triton_") and hasattr(kernel, "launchers"):
                                self.kernels[name] = [str(l.config) for l in kernel.launchers]
                        break
                    frame = frame.f_back
                assert frame is not None
                del frame


def main():
    out = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    probe = SharedProbe(Path(os.environ["MOONROBO_SHARED_INPUT"]), compiled=True)
    probe.prepare_actor()
    for p in probe.wm.parameters(): p.requires_grad_(False)
    state = unflatten_state(probe.state)
    f = torch.arange(4096, device="cuda")
    args = (state, probe.history, probe.previous, f, probe.xi, normalize_xi(probe.xi), probe.goals[:4096])
    original = probe.ctx["imag_step"]
    warm = original(*args)
    del warm
    native, compiled = Matrices(), Matrices(True)
    with native:
        eager_action = probe.pi(probe.history, probe.goals[:4096])
    # A dispatch mode outside Dynamo can cause a graph break / eager fallback.
    # Intercept the already-loaded generated wrapper's external GEMM calls
    # instead. All arguments and return tensors pass through unchanged.
    from torch._inductor.codecache import PyCodeCache
    originals = []
    class External:
        def __init__(self, wrapped): self.wrapped = wrapped
        def __getattr__(self, name):
            function = getattr(self.wrapped, name)
            if name not in ("mm", "addmm"): return function
            def call(*xs, **kwargs):
                value = function(*xs, **kwargs)
                compiled.record(name, xs, value)
                return value
            return call
    for module in PyCodeCache.modules:
        if hasattr(module, "extern_kernels"):
            originals.append((module,module.extern_kernels))
            module.extern_kernels = External(module.extern_kernels)
    assert originals
    try:
        result = original(*args)
    finally:
        for module, old in originals: module.extern_kernels = old
    native_path = Path(os.environ["ACTOR_NATIVE_BOUNDARIES"])
    native_action = torch.from_numpy(np.array(np.memmap(native_path/"step-0-action.f64", mode="r", dtype="<f8"))).float().reshape(4096,29)
    reproduction = stats(eager_action.detach().cpu(), native_action)
    assert reproduction["unequal"] == 0, "eager policy is not native-equivalent"
    rows = []
    assert len(native.rows) == 10 and len(compiled.rows) == 14
    for i, (left, right) in enumerate(zip(native.rows, compiled.rows)):
        a, b = left["values"], right["values"]
        # A compiled mm can defer its bias into the next fused kernel. Do not
        # compare that bare product with the native addmm output as if equal.
        comparisons = []
        for label, x, y in zip(("input","weight","output"),a[-3:],b[-3:]):
            if label == "output" and len(a) != len(b):
                comparisons.append(dict(name=label, comparable=False,reason="bias fusion boundary differs"))
            elif x.shape != y.shape:
                comparisons.append(dict(name=label, comparable=False,native_shape=list(x.shape),smc_shape=list(y.shape)))
            else:
                comparisons.append(dict(name=label,comparable=True,**stats(x,y)))
        rows.append(dict(layer=i,native_op=left["kind"],smc_op=right["kind"],operands_and_output=comparisons))
    generated = []
    for name in compiled.paths:
        path=Path(name); target=out/path.name
        target.write_bytes(path.read_bytes())
        generated.append(dict(path=name, copy=target.name, sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
    # Causal forward control: only normalization + BF16 input conversion is
    # compiled. Keep every policy Linear/ELU/tanh in the native-equivalent eager
    # path. This does NOT validate the 32-step actor or its backward pass.
    def normalize_bf16(x, mean, variance):
        return ((x-mean)/torch.sqrt(variance+1e-4)).to(torch.bfloat16)
    norm = torch.compile(normalize_bf16)
    goal_actual = norm(probe.goals[:4096],probe.pi.goal_norm.mean,probe.pi.goal_norm.var)
    goal_control = stats(goal_actual.cpu(), compiled.rows[0]["values"][-3])
    old_goal, old_obs = probe.pi.goal_norm.forward, probe.pi.obs_norm.forward
    probe.pi.goal_norm.forward = lambda x: norm(x,probe.pi.goal_norm.mean,probe.pi.goal_norm.var)
    try:
        goal_only = probe.pi(probe.history,probe.goals[:4096])
        probe.pi.obs_norm.forward = lambda x: norm(x,probe.pi.obs_norm.mean,probe.pi.obs_norm.var)
        both = probe.pi(probe.history,probe.goals[:4096])
    finally:
        probe.pi.goal_norm.forward,probe.pi.obs_norm.forward = old_goal,old_obs
    controls = dict(goal_input=goal_control,
        goal_only_action=stats(goal_only.detach().cpu(),result[1].detach().cpu()),
        both_norms_action=stats(both.detach().cpu(),result[1].detach().cpu()))
    for i in (0,1,2,3,5,6,7,8):
        value=compiled.rows[i]["values"][-1].cuda()
        controls[f"elu_same_input_{i}"]=stats(torch.nn.functional.elu(value).cpu(),compiled.rows[i+1]["values"][-3])
    # Compact numerical evidence for further same-input kernel replay.
    torch.save(dict(native=native.rows, smc=compiled.rows), out/"matrices.pt")
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16*1024**3 and torch.cuda.memory_reserved() < 32*1024**3
    (out/"result.json").write_text(json.dumps(dict(diagnostic_only=True,
        eager_matches_native=reproduction, action=stats(eager_action.detach().cpu(),result[1].detach().cpu()),
        matrices=rows, generated=generated, kernels=compiled.kernels, controls=controls,
        peak_reserved=torch.cuda.max_memory_reserved()),indent=2))


if __name__ == "__main__": main()
