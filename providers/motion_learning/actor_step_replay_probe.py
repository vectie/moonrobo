"""Bounded one-step replay of adjoints already observed from original SMC.

The original capture finished its actor update and CPU export before a later
native replay hit the unchanged host guard. Verify its raw gradients against
the independent original SMC snapshots; never call that interrupted run an
accepted end-to-end test. This process holds only one step's GPU graph.
"""
import hashlib
import inspect
import json
import os
from pathlib import Path

import numpy as np
import torch
from compiled_world_detail_d import Pair
from shared_smc_probe_bf16_original import SharedProbe, unflatten_state, normalize_xi


def compare(name, a, b):
    a, b = a.detach().float().cpu(), b.detach().float().cpu()
    assert a.shape == b.shape and torch.isfinite(a).all() and torch.isfinite(b).all()
    d = (a-b).abs()
    return dict(name=name, shape=list(a.shape), unequal=int((a != b).sum()),
                violations=int((d > 2e-6+2e-4*b.abs()).sum()), max_abs=float(d.max()))


def main():
    out = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    source = Path("/workspace/moonrobo/runs/hotspot-shared-actor-adjoints-e/original-adjoints.pt")
    saved = torch.load(source, map_location="cpu", weights_only=True)
    assert saved["upstream_source"] == "original node prehook"
    observed, order = saved["steps"], saved["order"]
    assert sorted(order) == list(range(32)) and len(observed) == 32
    probe = SharedProbe(Path(os.environ["MOONROBO_SHARED_INPUT"]), compiled=True)
    probe.prepare_actor()
    for p in probe.wm.parameters():
        p.requires_grad_(False)
    names = ("p", "r", "v", "w", "q", "qd", "history")
    package = Path("/workspace/moonrobo/runs/hotspot-mlp-actor-step-export-b")
    pairs = {kind: Pair(package/kind) for kind in ("initial", "recurrent")}
    motion = probe.ctx["motion"]
    live = [*probe.pi.parameters(), *probe.wm.parameters(), probe.pi.obs_norm.mean, probe.pi.obs_norm.var,
            probe.pi.goal_norm.mean, probe.pi.goal_norm.var, probe.wm.in_norm.mean, probe.wm.in_norm.var,
            probe.wm.out_norm.mean, probe.wm.out_norm.var, motion.root_R, probe.goals, probe.noise, probe.ctx["mdp"].default_q]
    reference = Path("/workspace/moonrobo/runs/hotspot-shared-actor-boundary-smc-b")
    records = {r["name"]: r["blob"] for r in json.loads((reference/"boundaries.json").read_text())["records"]}

    def read(name, device="cuda"):
        blob = records[name]
        path = reference/blob["file"]
        assert path.parent == reference and path.stat().st_size == int(blob["count"])*8
        with path.open("rb") as f:
            assert hashlib.file_digest(f, "sha256").hexdigest() == blob["sha256"]
        return torch.from_numpy(np.array(np.memmap(path, mode="r", dtype="<f8"))).float().reshape(blob["shape"]).to(device)

    verification = [compare(f"policy-{i}", saved["raw_gradients"][f"policy-{i}"], read(f"raw-policy-{i}", "cpu")) for i in range(20)]
    # The heavily instrumented capture is NOT accepted as the training
    # reference. Report its perturbation; validate its own exact node replay.
    # Full native acceptance continues to use unchanged independent SMC-b.
    sections = dict(instrumented_capture_vs_independent_original=verification,
                    original_parameter_join=[compare(k, v, saved["raw_gradients"][k]) for k, v in saved["parameter_join"].items()])
    observations = torch.stack([read(f"step-{t}-observation") for t in range(32)], 1)
    full_history = torch.cat([probe.history, observations], 1)
    native_totals, generated = {}, {}

    def generated_vjp(step, args, upstream):
        original = probe.ctx["imag_step"]
        direct_names = {}
        if step in saved["selected_inputs"]:
            actual = []
            checks = []
            for index, (cpu, strides) in enumerate(saved["selected_inputs"][step]):
                checks.append(compare(str(index), args[index], cpu))
                value = torch.empty_strided(cpu.shape, strides, dtype=cpu.dtype, device="cuda").copy_(cpu)
                actual.append(value)
            sections[f"step-{step}-reconstructed-inputs"] = checks
            args = actual + args[11:]
        # Recreate the original node signature, including input gradients only
        # on recurrent steps. Test against actual captured node contributions.
        xs = [v.detach().requires_grad_(step > 0) for v in args[:7]]
        def evaluate(record=False):
            value = original(tuple(xs[:6]), xs[6], probe.previous, args[7], args[8], args[9], args[10])
            outputs = (*value[0], value[1], value[2])
            if record and step in saved["selected_saved"]:
                node = value[1].grad_fn
                parameter_names = {id(p): f"policy-{i}" for i, p in enumerate(probe.pi.parameters())}
                leaves = {id(v): name for name, v in zip(names, xs)}
                for i, (parent, _) in enumerate(node.next_functions):
                    variable = getattr(parent, "variable", None)
                    if variable is not None:
                        label = parameter_names.get(id(variable), leaves.get(id(variable)))
                        assert label is not None
                        direct_names[i] = label
                intermediate = value[1].grad_fn.saved_tensors
                expected = saved["selected_saved"][step]
                assert len(intermediate) == len(expected), (len(intermediate), len(expected))
                sections[f"step-{step}-saved-forward"] = [dict(**compare(str(i), v, cpu),
                    actual_stride=list(v.stride()), expected_stride=list(strides))
                    for i, (v, (cpu, strides)) in enumerate(zip(intermediate, expected))]
                sections[f"step-{step}-original-forward"] = [compare(k, v, read(f"step-{step}-{k}"))
                    for k, v in zip((*names[:6], "action"), outputs[:7])]
            inputs = ([*xs] if step > 0 else []) + list(probe.pi.parameters())
            cotangents = []
            for g, strides in zip(upstream, saved["upstream_layouts"][step]):
                cotangents.append(g.clone() if strides is None else torch.empty_strided(g.shape, strides, dtype=g.dtype, device=g.device).copy_(g))
            return torch.autograd.grad(outputs, inputs, cotangents)
        warm = evaluate()
        del warm
        from torch._inductor.codecache import PyCodeCache
        old = []
        paths = set()
        kernels = {}
        class External:
            def __init__(self, wrapped): self.wrapped = wrapped
            def __getattr__(self, name):
                function = getattr(self.wrapped, name)
                if name not in ("mm", "addmm", "bmm"): return function
                def call(*values, **kwargs):
                    result = function(*values, **kwargs)
                    frame = inspect.currentframe().f_back
                    while frame and "/inductor-cache/" not in frame.f_code.co_filename:
                        frame = frame.f_back
                    assert frame is not None
                    paths.add(frame.f_code.co_filename)
                    for key, kernel in frame.f_globals.items():
                        if key.startswith("triton_") and hasattr(kernel, "launchers"):
                            kernels[key] = dict(configs=[str(l.config) for l in kernel.launchers])
                    del frame
                    return result
                return call
        for module in PyCodeCache.modules:
            if hasattr(module, "extern_kernels"):
                old.append((module, module.extern_kernels))
                module.extern_kernels = External(module.extern_kernels)
        try:
            grads = evaluate(record=True)
        finally:
            for module, previous in old:
                module.extern_kernels = previous
        labels = ([*names] if step > 0 else []) + [f"policy-{i}" for i in range(20)]
        control = [compare(k, g, observed[step]["detail"][k]) for k, g in zip(labels, grads)]
        sections[f"step-{step}-original-vjp-reproduction"] = control
        assert paths
        rows = []
        for filename in paths:
            path = Path(filename)
            target = out/path.name
            if not target.exists(): target.write_bytes(path.read_bytes())
            rows.append(dict(path=filename, copy=target.name, sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        generated[str(step)] = dict(code=rows, smc_loaded_kernels=kernels)
        if step in saved["selected_saved"]:
            # Replay the exact backward used by the full original actor. This
            # bypasses a second forward and its possibly different saved state.
            artifact = next(iter(saved["generated"].values()))
            module = next(m for m in PyCodeCache.modules
                          if Path(m.__file__).name == artifact["copy"])
            assert hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest() == artifact["sha256"]
            inputs = [torch.empty_strided(v.shape, strides, dtype=v.dtype, device="cuda").copy_(v)
                      for v, strides in saved["selected_saved"][step]]
            inputs += [g.clone() for g in upstream]
            exact = module.call(inputs)
            direct = [compare(name, exact[i], observed[step]["detail"][name]) for i, name in direct_names.items()]
            sections[f"step-{step}-actual-generated-backward-reproduction"] = direct
            (out/"progress.json").write_text(json.dumps(dict(sections=sections, completed_step=step, generated=generated), indent=2))
            assert all(r["unequal"] == 0 for r in direct), "actual generated backward failed exact replay"
        (out/"progress.json").write_text(json.dumps(dict(sections=sections, completed_step=step, generated=generated), indent=2))
        # The isolated-forward control is reported separately. The reference
        # for native gradients remains the verified full-actor node capture.

    for t in [31]:
        state = unflatten_state(probe.state) if t == 0 else tuple(read(f"step-{t-1}-{k}") for k in names[:6])
        pair = pairs["initial" if t == 0 else "recurrent"]
        args = [*state, full_history[:, t:t+10], torch.arange(4096*t, 4096*(t+1), device="cuda"), probe.xi,
                normalize_xi(probe.xi), probe.goals[4096*t:4096*(t+1)], *live]
        for i, spec in enumerate(pair.manifest["graphs"]["forward"]["inputs"]):
            if list(args[i].stride()) != spec["stride"]:
                args[i] = torch.empty_strided(spec["shape"], spec["stride"], dtype=args[i].dtype, device="cuda").copy_(args[i])
        pred = pair.forward(args)
        expected = [read(f"step-{t}-{k}") for k in names[:6]] + [read(f"step-{t}-action")]
        assert all(torch.equal(a, b) for a, b in zip(pred[:7], expected))
        assert torch.equal(pred[7], full_history[:, t+1:t+11])
        upstream = [g.cuda() for g in observed[t]["upstream"]]
        if observed[t]["detail"]:
            generated_vjp(t, args, upstream)
        native_upstream = [g.clone() for g in upstream]
        grads = pair.backward(native_upstream)
        if observed[t]["detail"]:
            sections[f"step-{t}-native-cotangent-mutation"] = [compare(str(i), a, b) for i, (a, b) in enumerate(zip(native_upstream, upstream))]
        labels = {**{i: k for i, k in enumerate(names)}, **{11+i: f"policy-{i}" for i in range(20)}}
        rows = []
        for index, value in zip(pair.manifest["gradient_indices"], grads):
            name = labels[index]
            cpu = value.detach().cpu()
            if name.startswith("policy-"):
                if name not in native_totals: native_totals[name] = cpu.clone()
                else: native_totals[name].add_(cpu)
            if observed[t]["detail"]:
                rows.append(compare(name, cpu, observed[t]["detail"][name]))
        if rows:
            sections[f"step-{t}-same-cotangent-vjp"] = rows
        pair.values = []
        del pred, grads, expected
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0] > 16*1024**3 and torch.cuda.max_memory_reserved() < 32*1024**3
        (out/"progress.json").write_text(json.dumps(dict(sections=sections, completed_step=t, generated=generated), indent=2))
    (out/"result.json").write_text(json.dumps(dict(diagnostic_only=True, original_smc_unchanged=True,
        scope="single last-step diagnostic; instrumented capture is not the numerical acceptance reference",
        capture_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), backward_order=order,
        sections=sections, generated=generated, peak_reserved=torch.cuda.max_memory_reserved()), indent=2))


if __name__ == "__main__":
    main()
