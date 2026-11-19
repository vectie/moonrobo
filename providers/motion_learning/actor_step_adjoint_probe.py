"""Original SMC actor adjoints and same-cotangent native imagined-step VJPs.

Hooks observe the original compiled autograd nodes; they return no replacement
gradient. Parameter contributions are accumulated on CPU in observed backward
order. Four steps retain detailed VJPs; all 32 retain their output cotangents.
This is a numerical diagnostic, never a performance measurement.
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


def compare(name, actual, expected):
    a, b = actual.detach().float().cpu(), expected.detach().float().cpu()
    assert a.shape == b.shape and torch.isfinite(a).all() and torch.isfinite(b).all()
    d = (a-b).abs()
    return dict(name=name, shape=list(a.shape), unequal=int((a != b).sum()),
                violations=int((d > 2e-6+2e-4*b.abs()).sum()), max_abs=float(d.max()))


def main():
    out = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    probe = SharedProbe(Path(os.environ["MOONROBO_SHARED_INPUT"]), compiled=True)
    probe.prepare_actor()
    names = ("p", "r", "v", "w", "q", "qd", "history")
    params = list(probe.pi.parameters())
    parameter_names = {id(p): f"policy-{i}" for i, p in enumerate(params)}
    original = probe.ctx["imag_step"]
    observed, order, handles, totals, incoming, tangent_mutations = {}, [], [], {}, {}, {}
    selected = {0, 1, 15, 31}
    counter = 0
    selected_inputs, selected_saved, upstream_layouts, generated = {}, {}, {}, {}
    active_backward = None

    # Observe actual loaded generated code, without wrapping the Dynamo input
    # function or changing its dispatch. Only one selected backward is logged.
    from torch._inductor.select_algorithm import extern_kernels
    originals = {name: getattr(extern_kernels, name) for name in ("mm", "addmm", "bmm")}
    def external(name):
        def call(*args, **kwargs):
            result = originals[name](*args, **kwargs)
            if active_backward == 31:
                frame = inspect.currentframe().f_back
                while frame and "/inductor-cache/" not in frame.f_code.co_filename:
                    frame = frame.f_back
                assert frame is not None
                path = Path(frame.f_code.co_filename)
                if str(path) not in generated:
                    target = out/path.name
                    target.write_bytes(path.read_bytes())
                    kernels = {key: dict(configs=[str(l.config) for l in kernel.launchers])
                               for key, kernel in frame.f_globals.items()
                               if key.startswith("triton_") and hasattr(kernel, "launchers")}
                    generated[str(path)] = dict(copy=target.name, sha256=hashlib.sha256(target.read_bytes()).hexdigest(),
                                                smc_loaded_kernels=kernels)
                del frame
            return result
        return call

    def step(*args):
        nonlocal counter
        t = counter
        counter += 1
        result = original(*args)
        outputs = (*result[0], result[1], result[2])
        node = result[1].grad_fn
        assert node is not None and all(v.grad_fn is node for v in outputs), "one original compiled step node required"
        output_indices = [v.output_nr for v in outputs]
        output_specs = [(tuple(v.shape), v.dtype) for v in outputs]
        if t == 31:
            actual_inputs = (*args[0], args[1], args[3], args[4], args[5], args[6])
            selected_inputs[t] = [(v.detach().cpu().clone(), tuple(v.stride())) for v in actual_inputs]
            selected_saved[t] = [(v.detach().cpu().clone(), tuple(v.stride())) for v in node.saved_tensors]
        input_edges = {(v.grad_fn, v.output_nr): name for name, v in zip(names, (*args[0], args[1])) if v.requires_grad}
        input_names = {}
        for i, edge in enumerate(node.next_functions):
            parent, _ = edge
            if parent is None:
                continue
            variable = getattr(parent, "variable", None)
            if variable is not None and id(variable) in parameter_names:
                input_names[i] = parameter_names[id(variable)]
            elif edge in input_edges:
                input_names[i] = input_edges[edge]
            else:
                raise AssertionError((t, i, parent.name()))
        assert set(input_names.values()) == set(parameter_names.values()) | (set(names) if t else set())

        def prehook(grad_outputs):
            nonlocal active_backward
            active_backward = t
            assert t not in incoming
            upstream_layouts[t] = [None if grad_outputs[i] is None else tuple(grad_outputs[i].stride()) for i in output_indices]
            incoming[t] = tuple(grad_outputs[i].detach().cpu().contiguous() if grad_outputs[i] is not None
                                else torch.zeros(shape, dtype=dtype)
                                for i, (shape, dtype) in zip(output_indices, output_specs))

        def hook(grad_inputs, grad_outputs):
            nonlocal active_backward
            assert t not in observed
            order.append(t)
            upstream = incoming.pop(t)
            after = tuple(grad_outputs[i].detach().cpu().contiguous() if grad_outputs[i] is not None
                          else torch.zeros(shape, dtype=dtype)
                          for i, (shape, dtype) in zip(output_indices, output_specs))
            tangent_mutations[t] = [compare(str(i), a, b) for i, (a, b) in enumerate(zip(after, upstream))]
            detail = {}
            for i, name in input_names.items():
                value = grad_inputs[i].detach().cpu().contiguous()
                if name.startswith("policy-"):
                    if name not in totals:
                        totals[name] = value.clone()
                    else:
                        totals[name].add_(value)
                if t in selected:
                    detail[name] = value
            observed[t] = dict(upstream=upstream, detail=detail)
            active_backward = None
            # None leaves the original gradient tuple unchanged.

        handles.append(node.register_prehook(prehook))
        handles.append(node.register_hook(hook))
        return result

    probe.ctx["imag_step"] = step
    raw_gradients = {}
    original_clip = torch.nn.utils.clip_grad_norm_

    def clip(parameters, *args, **kwargs):
        parameters = list(parameters)
        if len(parameters) == 20 and parameters[0] is params[0]:
            raw_gradients.update({f"policy-{i}": p.grad.detach().cpu().clone() for i, p in enumerate(parameters)})
        return original_clip(parameters, *args, **kwargs)

    torch.nn.utils.clip_grad_norm_ = clip
    for name in originals:
        setattr(extern_kernels, name, external(name))
    try:
        metrics = probe.actor()
    finally:
        probe.ctx["imag_step"] = original
        torch.nn.utils.clip_grad_norm_ = original_clip
        for name, function in originals.items():
            setattr(extern_kernels, name, function)
        for handle in handles:
            handle.remove()
    assert counter == 32 and len(observed) == 32 and len(raw_gradients) == 20
    sections = dict(original_parameter_join=[compare(k, totals[k], raw_gradients[k]) for k in totals])
    (out/"progress.json").write_text(json.dumps(dict(sections=sections, backward_order=order), indent=2))
    torch.save(dict(steps=observed, order=order, parameter_join=totals, raw_gradients=raw_gradients,
                    upstream_source="original node prehook", tangent_mutations=tangent_mutations,
                    selected_inputs=selected_inputs, selected_saved=selected_saved,
                    upstream_layouts=upstream_layouts, generated=generated), out/"original-adjoints.pt")
    (out/"generated.json").write_text(json.dumps(generated, indent=2))
    if os.environ.get("ACTOR_CAPTURE_ONLY", "1") == "1":
        torch.cuda.synchronize()
        memory = dict(allocated=torch.cuda.memory_allocated(), reserved=torch.cuda.memory_reserved(),
                      peak_reserved=torch.cuda.max_memory_reserved(), free=torch.cuda.mem_get_info()[0])
        (out/"capture-summary.json").write_text(json.dumps(dict(sections=sections, backward_order=order,
            tangent_mutations=tangent_mutations, memory=memory), indent=2))
        assert memory["free"] > 16*1024**3 and memory["peak_reserved"] < 32*1024**3
        (out/"result.json").write_text(json.dumps(dict(diagnostic_only=True, capture_only=True,
            upstream_source="original node prehook", sections=sections, backward_order=order,
            tangent_mutations=tangent_mutations, memory=memory), indent=2))
        return
    probe.reset()
    for p in probe.wm.parameters():
        p.requires_grad_(False)
    package = Path("/workspace/moonrobo/runs/hotspot-mlp-actor-step-export-b")
    pairs = {kind: Pair(package/kind) for kind in ("initial", "recurrent")}
    motion = probe.ctx["motion"]
    live = [*probe.pi.parameters(), *probe.wm.parameters(), probe.pi.obs_norm.mean, probe.pi.obs_norm.var,
            probe.pi.goal_norm.mean, probe.pi.goal_norm.var, probe.wm.in_norm.mean, probe.wm.in_norm.var,
            probe.wm.out_norm.mean, probe.wm.out_norm.var, motion.root_R, probe.goals, probe.noise, probe.ctx["mdp"].default_q]
    reference = Path("/workspace/moonrobo/runs/hotspot-shared-actor-boundary-smc-b")
    records = {r["name"]: r["blob"] for r in json.loads((reference/"boundaries.json").read_text())["records"]}

    def read(name):
        blob = records[name]
        path = reference/blob["file"]
        assert path.parent == reference and path.stat().st_size == int(blob["count"])*8
        with path.open("rb") as f:
            assert hashlib.file_digest(f, "sha256").hexdigest() == blob["sha256"]
        return torch.from_numpy(np.array(np.memmap(path, mode="r", dtype="<f8"))).float().reshape(blob["shape"]).cuda()

    native_totals = {}
    observations = torch.stack([read(f"step-{t}-observation") for t in range(32)], 1)
    full_history = torch.cat([probe.history, observations], 1)
    for t in order:
        history = full_history[:, t:t+10]
        state = unflatten_state(probe.state) if t == 0 else tuple(read(f"step-{t-1}-{k}") for k in names[:6])
        pair = pairs["initial" if t == 0 else "recurrent"]
        args = [*state, history, torch.arange(4096*t, 4096*(t+1), device="cuda"), probe.xi,
                normalize_xi(probe.xi), probe.goals[4096*t:4096*(t+1)], *live]
        for i, spec in enumerate(pair.manifest["graphs"]["forward"]["inputs"]):
            if list(args[i].stride()) != spec["stride"]:
                args[i] = torch.empty_strided(spec["shape"], spec["stride"], dtype=args[i].dtype, device="cuda").copy_(args[i])
        pred = pair.forward(args)
        expected = [read(f"step-{t}-{k}") for k in names[:6]] + [read(f"step-{t}-action")]
        assert all(torch.equal(a, b) for a, b in zip(pred[:7], expected))
        assert torch.equal(pred[7], full_history[:, t+1:t+11])
        grads = pair.backward([g.cuda() for g in observed[t]["upstream"]])
        labels = {**{i: k for i, k in enumerate(names)}, **{11+i: f"policy-{i}" for i in range(20)}}
        rows = {}
        for index, value in zip(pair.manifest["gradient_indices"], grads):
            name = labels[index]
            cpu = value.detach().cpu()
            if name.startswith("policy-"):
                if name not in native_totals:
                    native_totals[name] = cpu.clone()
                else:
                    native_totals[name].add_(cpu)
            if t in selected:
                rows[name] = compare(name, cpu, observed[t]["detail"][name])
        if t in selected:
            sections[f"step-{t}-same-cotangent-vjp"] = list(rows.values())
        pair.values = []
        del pred, grads
        (out/"progress.json").write_text(json.dumps(dict(sections=sections, completed_step=t), indent=2))
    sections["native_same_cotangents_parameter_join"] = [compare(k, native_totals[k], totals[k]) for k in totals]
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16*1024**3 and torch.cuda.max_memory_reserved() < 32*1024**3
    (out/"result.json").write_text(json.dumps(dict(diagnostic_only=True, original_smc_unchanged=True,
        backward_order=order, sections=sections, peak_reserved=torch.cuda.max_memory_reserved()), indent=2))


if __name__ == "__main__":
    main()
