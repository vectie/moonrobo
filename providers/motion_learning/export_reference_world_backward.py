"""Export the ORIGINAL SMC backward FX with native's existing input order.

Forward/error libraries remain byte-identical to the already investigated
native package. This candidate remains disabled pending the complete gate.
"""
import ast
import json
import os
from pathlib import Path
import torch
from torch._subclasses.fake_tensor import FakeTensorMode
from compiler_reference_contract_c import reference_compilation


def main():
    root=Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    original=Path("/workspace/moonrobo/runs/hotspot-mlp-aoti-window-export-bf16-g")
    code=Path("/workspace/moonrobo/private/shared-compute-20261026-a/world_smc_backward_fx_a.py")
    names_path=Path("/workspace/moonrobo/private/shared-compute-20261026-a/world_native_backward_fx_a.py")
    assert torch.cuda.mem_get_info()[0]>24*1024**3
    torch.backends.cuda.matmul.allow_tf32=True
    torch.backends.cudnn.allow_tf32=True
    for branch in ("rollout","error"):
        target=root/branch;target.mkdir()
        for path in (original/branch).iterdir():
            if path.suffix in (".so",".cubin") or path.name in ("manifest.json","native.spec"):
                if branch=="rollout" and path.name=="backward.so": continue
                (target/path.name).write_bytes(path.read_bytes())
    smc_function=next(n for n in ast.walk(ast.parse(code.read_text())) if isinstance(n,ast.FunctionDef) and n.name=="forward")
    funcs=[n for n in ast.walk(ast.parse(names_path.read_text())) if isinstance(n,ast.FunctionDef) and n.name=="forward"]
    native_names=[a.arg for a in funcs[0].args.args if a.arg!="self"]
    rename={"primals_6":"primals_8","primals_7":"primals_9","primals_10":"primals_12","primals_11":"primals_13",
            "primals_14":"primals_16","primals_15":"primals_17","primals_19":"primals_5","primals_21":"primals_20"}
    graph=torch.fx.Graph()
    ordered={rename.get(name,name):graph.placeholder(name) for name in native_names}
    environment=dict(ordered)
    assert set(ordered)=={a.arg for a in smc_function.args.args if a.arg!="self"}
    def value(node):
        if isinstance(node,ast.Name):
            if node.id in environment:return environment[node.id]
            return {"torch":torch,"device":torch.device,"inf":float("inf")}[node.id]
        if isinstance(node,ast.Constant):return node.value
        if isinstance(node,ast.Attribute):return getattr(value(node.value),node.attr)
        if isinstance(node,ast.List):return [value(n) for n in node.elts]
        if isinstance(node,ast.Tuple):return tuple(value(n) for n in node.elts)
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,ast.USub):return -value(node.operand)
        if isinstance(node,ast.Call) and ast.unparse(node.func)=="device":
            return torch.device(*[value(n) for n in node.args],**{k.arg:value(k.value) for k in node.keywords})
        raise AssertionError(ast.dump(node))
    # Rebuild the already-generated FX operators without executing constant
    # tensor operations while tracing. No algebra rewrite/decomposition here.
    for node in smc_function.body:
        if isinstance(node,ast.AnnAssign):
            assert isinstance(node.target,ast.Name) and isinstance(node.value,ast.Call)
            expr=node.value;assert node.target.id not in environment
            environment[node.target.id]=graph.call_function(value(expr.func),tuple(value(n) for n in expr.args),{k.arg:value(k.value) for k in expr.keywords})
        elif isinstance(node,ast.Return):
            outputs=[value(n) for n in node.value.elts if not isinstance(n,ast.Constant) or n.value is not None]
            assert len(outputs)==14
            graph.output(tuple(outputs))
        else:
            # Readable FX prints lifetime ends as `temporary = None`.
            assert isinstance(node,ast.Assign) and isinstance(node.value,ast.Constant) and node.value.value is None
    gm=torch.fx.GraphModule(torch.nn.Module(),graph)
    (root/"rollout"/"backward.fx.txt").write_text(gm.code)
    manifest=json.loads((root/"rollout"/"manifest.json").read_text())
    dtype={"torch.float32":torch.float32,"torch.bfloat16":torch.bfloat16,"torch.int64":torch.int64,"torch.bool":torch.bool}
    with FakeTensorMode():
        examples=[torch.empty_strided(item["shape"],item["stride"],dtype=dtype[item["dtype"]],device="cuda") for item in manifest["graphs"]["backward"]["inputs"]]
        # This is already a backward ATen graph. Do not send it through the
        # AOTAutograd frontend a second time as an inference/forward graph.
        from torch._inductor.compile_fx import compile_fx_inner, get_cpp_wrapper_config
        from torch._inductor.virtualized import V
        options={**get_cpp_wrapper_config(),"aot_inductor.output_path":str(root/"rollout"/"backward.so"),"compile_threads":1,"cpp_wrapper":True}
        with torch._inductor.config.patch(options), V.set_aot_compilation(True), torch._guards.compile_context(torch._guards.CompileContext(None)):
            artifact=compile_fx_inner(gm,examples,cpp_wrapper=True,is_backward=True,is_inference=False)
        result=artifact.filename
    assert Path(result).name=="backward.so"
    manifest["backward_source"]="original SMC post-grad FX; direct compile_fx_inner(is_backward=True), native argument permutation only; 14 non-None gradients in parameter order"
    (root/"rollout"/"manifest.json").write_text(json.dumps(manifest,indent=2))
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.memory_reserved()<32*1024**3
    (root/"result.json").write_text(json.dumps(dict(exported=True,diagnostic_only=True,acceptance_not_implied=True,reserved_peak=torch.cuda.max_memory_reserved())))


if __name__=="__main__":
    inputs=json.loads(Path(os.environ["MOONROBO_COMPILER_REFERENCE"]).read_text())
    with reference_compilation(inputs["padding_cache"],inputs["backward_code"],inputs["selected_kernels"],Path(os.environ["MOONROBO_SHARED_OUTPUT"])/"reference-decisions.json"):
        main()
