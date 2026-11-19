"""Experimental export of SMC's eight-step rollout and error boundary.

All live parameters and normalizer means/variances are explicit arguments.
The six state outputs and their separate gradient edges are preserved. No
quaternion conversion, detaching of rollout state, or changed loss is introduced.
The complete BF16 update has NOT passed its strict numerical acceptance gate.
Keep this route default-disabled. See compiled-mlp-20261028-a evidence.
"""
import ast
import copy
import json
import os
from pathlib import Path
from types import SimpleNamespace

import torch
from torch import nn
from torch._functorch.aot_autograd import aot_function
from torch._functorch.partitioners import min_cut_rematerialization_partition
from torch._inductor.decomposition import select_decomp_table
from functorch.compile import make_boxed_func
from precision_mlp_probe_a import read_tensor
from shared_smc_probe_bf16_original import networks, WorldModel, unflatten_state, normalize_xi


def export_pair(operation, arguments, upstream, folder):
    folder.mkdir()
    graphs = {}

    def capture(kind):
        def compiler(gm, args):
            graphs[kind] = copy.deepcopy(gm), list(args)
            (folder / (kind + ".fx.txt")).write_text(gm.code)
            return make_boxed_func(gm.forward)
        return compiler

    operation_aot = aot_function(operation, fw_compiler=capture("forward"), bw_compiler=capture("backward"),
                                 partition_fn=min_cut_rematerialization_partition,
                                 decompositions=select_decomp_table())
    output = operation_aot(*arguments)
    torch.autograd.grad(output, [a for a in arguments if a.requires_grad], upstream)
    output_count = len(output) if isinstance(output, (tuple, list)) else 1
    manifest = dict(schema=2, torch=torch.__version__, input_count=len(arguments),
                    output_count=output_count, first_order_only=True, parameter_constants=False, graphs={})
    manifest["saved_layout_contract"] = "captured FX; native bridge restores padded saved layouts"
    manifest["numerical_acceptance"] = "separate complete-update gate required"
    for kind in ("forward", "backward"):
        gm, args = graphs[kind]
        assert all(isinstance(a, torch.Tensor) for a in args)
        node = next(n for n in gm.graph.nodes if n.op == "output")
        outputs = list(node.args[0])
        if kind == "backward":
            indices = [i for i, v in enumerate(outputs) if v is not None]
            assert len(outputs) == len(arguments)
            manifest["gradient_indices"] = indices
            node.args = (tuple(outputs[i] for i in indices),)
            gm.recompile()
        else:
            assert all(v is not None for v in outputs)
        path = torch._inductor.aot_compile(gm, tuple(args), options={
            "aot_inductor.output_path": str(folder / (kind + ".so")), "compile_threads": 1})
        manifest["graphs"][kind] = dict(path=Path(path).name,
            inputs=[dict(shape=list(a.shape), stride=list(a.stride()), dtype=str(a.dtype)) for a in args],
            output_count=len(node.args[0]))
        print("EXPORTED", folder.name, kind, flush=True)
    dtype_codes = {"torch.float32": 6, "torch.bfloat16": 15,
                   "torch.int64": 4, "torch.bool": 11}
    indices = manifest["gradient_indices"]
    spec = ["MR_AOTI_V2", torch.__version__.split("+")[0], " ".join(map(str, torch.cuda.get_device_capability())),
            f'{len(arguments)} {len(manifest["graphs"]["backward"]["inputs"])} {output_count}',
            " ".join(map(str, [len(indices), *indices]))]
    for kind in ("forward", "backward"):
        for item in manifest["graphs"][kind]["inputs"]:
            spec.append(" ".join(map(str, [len(item["shape"]), dtype_codes[item["dtype"]], *item["shape"], *item["stride"]])))
    (folder / "native.spec").write_text("\n".join(spec)+"\n")
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2))
    torch.cuda.synchronize()
    return tuple(t.detach() for t in output) if isinstance(output, (tuple, list)) else output.detach()


def main():
    out, source = Path(os.environ["MOONROBO_SHARED_OUTPUT"]), Path(os.environ["MOONROBO_SHARED_INPUT"])
    assert torch.__version__.startswith("2.11.0") and torch.cuda.mem_get_info()[0] > 24 * 1024**3
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    amp = os.environ["MOONROBO_SHARED_AMP"]
    assert amp in ("none", "bf16")
    networks.AMP_DTYPE = torch.bfloat16 if amp == "bf16" else None
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

    class Rollout(nn.Module):
        def __init__(self):
            super().__init__()
            self.wm = wm

        def forward(self, s, a, xi):
            return ctx["_wm_rollout"](s, a, xi)

    module = Rollout()
    names = list(dict(module.named_parameters()))
    buffer_names = ["wm.in_norm.mean", "wm.in_norm.var", "wm.out_norm.mean", "wm.out_norm.var"]
    buffers = dict(module.named_buffers())

    def rollout(s, a, xi, *live):
        mapping = dict(zip(names + buffer_names, live))
        return torch.func.functional_call(module, mapping, (s, a, xi))

    args = [load("world-s"), load("world-actions"), load("world-xi"),
            *module.parameters(), *(buffers[k] for k in buffer_names)]
    with torch.no_grad():
        examples = rollout(*args)
    predicted = export_pair(rollout, args, tuple(torch.ones_like(t) for t in examples), out / "rollout")

    class Error(nn.Module):
        def __init__(self):
            super().__init__()
            self.wm = wm
            self.register_buffer("floor", ctx["ERR_FLOOR"])

        def forward(self, states, target, mask):
            # Bind the original function's constant explicitly for fake-tensor
            # tracing and runtime provenance; do not capture a live CUDA tensor.
            original_floor = ctx["ERR_FLOOR"]
            ctx["ERR_FLOOR"] = self.floor
            try:
                loss, last = ctx["_wm_err"](states, target, mask)
            finally:
                ctx["ERR_FLOOR"] = original_floor
            m = mask[:, -1]
            metric = (last.detach() * m).sum() / m.sum().clamp(min=1)
            return torch.stack((loss, metric))

    error_module = Error()

    def error(p, r, v, w, q, qd, target, mask, variance, floor):
        return torch.func.functional_call(error_module, {"wm.out_norm.var": variance, "floor": floor}, ((p,r,v,w,q,qd), target, mask))

    export_pair(error, [*(t.requires_grad_() for t in predicted), load("world-s1"), load("world-mask"), wm.out_norm.var, ctx["ERR_FLOOR"]],
                torch.tensor([1., 0.], device="cuda"), out / "error")
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16 * 1024**3 and torch.cuda.memory_reserved() < 32 * 1024**3
    (out / "result.json").write_text(json.dumps(dict(exported=True, amp=amp, scope="original rollout/error AST; six rollout outputs preserved; detached metric summary",
        parameters_and_normalizers_are_live_inputs=True, reserved_peak=torch.cuda.max_memory_reserved()), indent=2))


if __name__ == "__main__":
    contract = os.environ.get("MOONROBO_COMPILER_REFERENCE")
    if contract:
        from compiler_reference_contract_c import reference_compilation
        inputs=json.loads(Path(contract).read_text())
        with reference_compilation(inputs["padding_cache"],inputs["backward_code"],inputs["selected_kernels"],
                                   Path(os.environ["MOONROBO_SHARED_OUTPUT"])/"reference-decisions.json"):
            main()
    else:
        main()
