"""Numerical compiler adapter for the native AOTAutograd experiment.

MoonBit owns deployment, execution and resource guards. This exports forward and
first-order VJP graphs with *all weights as inputs*, never frozen constants. The
runtime is C++ AOTInductor, not a Python subprocess. PyTorch 2.11 is pinned by the
benchmark image; these compiler interfaces are intentionally experimental.
"""
import copy
import json
import os
from pathlib import Path

import torch
from torch import nn
from torch._functorch.aot_autograd import aot_function
from torch._functorch.partitioners import min_cut_rematerialization_partition
from torch._inductor.decomposition import select_decomp_table
from functorch.compile import make_boxed_func
from precision_mlp_probe_a import networks, read_tensor


def main():
    out = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    source = Path(os.environ["MOONROBO_SHARED_INPUT"])
    assert torch.__version__.startswith("2.11.0")
    assert torch.cuda.mem_get_info()[0] > 24 * 1024**3
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    amp = os.environ["MOONROBO_SHARED_AMP"]
    assert amp in ("none", "bf16")
    networks.AMP_DTYPE = torch.bfloat16 if amp == "bf16" else None
    initial = {r["name"]: r for r in json.loads((source / "initial.json").read_text())["records"]}
    net = networks.mlp(133, [2048, 2048, 2048], 70, act=nn.SiLU, layer_norm=True).cuda()
    with torch.no_grad():
        for i, p in enumerate(net.parameters()):
            p.copy_(read_tensor(source, initial[f"world-{i}-parameter"]))
    names = list(dict(net.named_parameters()))
    x = ((torch.arange(2048 * 133, device="cuda", dtype=torch.int64) * 17 % 1009).float() - 504) / 504
    x = x.reshape(2048, 133).requires_grad_()
    dy = ((torch.arange(2048 * 70, device="cuda", dtype=torch.int64) * 31 % 101).float() - 50) / 50
    dy = dy.reshape(2048, 70)

    def operation(x, *params):
        with torch.autocast("cuda", dtype=torch.bfloat16, enabled=amp == "bf16"):
            return torch.func.functional_call(net, dict(zip(names, params)), (x,)).float()

    graphs = {}

    def capture(kind):
        def compiler(gm, args):
            graphs[kind] = (copy.deepcopy(gm), list(args))
            (out / (kind + ".fx.txt")).write_text(gm.code)
            return make_boxed_func(gm.forward)
        return compiler

    compiled = aot_function(operation, fw_compiler=capture("forward"),
                            bw_compiler=capture("backward"),
                            partition_fn=min_cut_rematerialization_partition,
                            decompositions=select_decomp_table())
    params = list(net.parameters())
    y = compiled(x, *params)
    torch.autograd.grad(y, [x] + params, dy)
    manifest = dict(schema=1, torch=torch.__version__, amp=amp,
                    input_count=1+len(params), batch=2048, widths=[133,2048,2048,2048,70],
                    output_count=1, first_order_only=True, parameter_constants=False,
                    guards_unchanged=True, graphs={})
    for kind in ("forward", "backward"):
        gm, args = graphs[kind]
        assert all(isinstance(a, torch.Tensor) for a in args)
        outputs = next(n for n in gm.graph.nodes if n.op == "output")
        values = list(outputs.args[0])
        assert all(v is not None for v in values), "VJP must cover all explicit inputs"
        path = torch._inductor.aot_compile(gm, tuple(args), options={
            "aot_inductor.output_path": str(out / (kind + ".so")),
            "aot_inductor.debug_compile": False,
            "compile_threads": 1,
        })
        assert isinstance(path, str)
        manifest["graphs"][kind] = dict(path=Path(path).name,
            inputs=[dict(shape=list(a.shape), stride=list(a.stride()), dtype=str(a.dtype)) for a in args],
            output_count=len(values))
        print("EXPORTED", kind, path, flush=True)
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16 * 1024**3
    assert torch.cuda.memory_reserved() < 32 * 1024**3
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    dtype_codes = {"torch.float32": 6, "torch.bfloat16": 15}
    spec = ["MR_AOTI_V1", torch.__version__.split("+")[0],
            " ".join(map(str, torch.cuda.get_device_capability())),
            f'{manifest["input_count"]} {len(manifest["graphs"]["backward"]["inputs"])} 1']
    for kind in ("forward", "backward"):
        for item in manifest["graphs"][kind]["inputs"]:
            spec.append(" ".join(map(str, [len(item["shape"]), dtype_codes[item["dtype"]],
                                          *item["shape"], *item["stride"]])))
    (out / "native.spec").write_text("\n".join(spec) + "\n")
    (out / "result.json").write_text(json.dumps(dict(exported=True, amp=amp,
        reserved_peak=torch.cuda.max_memory_reserved(), allocated_peak=torch.cuda.max_memory_allocated()), indent=2))


if __name__ == "__main__":
    main()
