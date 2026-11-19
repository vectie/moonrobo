"""Native-only actor backward export using original SMC padding decisions.

Keep the accepted forward artifacts unchanged. Reconstruct the existing native
ATen backward graph without sending it through AOTAutograd a second time.
No acceptance or performance claim is implied by successful compilation.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import torch
from torch._subclasses.fake_tensor import FakeTensorMode
from compiler_reference_contract_c import reference_compilation
from compiled_world_detail_d import Pair
from shared_smc_probe_bf16_original import SharedProbe, unflatten_state, normalize_xi


def graph_from_code(code):
    function = next(n for n in ast.parse(code).body if isinstance(n, ast.FunctionDef))
    graph = torch.fx.Graph()
    env = {a.arg: graph.placeholder(a.arg) for a in function.args.args if a.arg != "self"}
    def value(n):
        if isinstance(n, ast.Name):
            return env[n.id] if n.id in env else {"torch":torch, "inf":float("inf")}[n.id]
        if isinstance(n, ast.Constant): return n.value
        if isinstance(n, ast.Attribute): return getattr(value(n.value), n.attr)
        if isinstance(n, ast.List): return [value(x) for x in n.elts]
        if isinstance(n, ast.Tuple): return tuple(value(x) for x in n.elts)
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.USub): return -value(n.operand)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "device":
            return torch.device(*[value(a) for a in n.args], **{k.arg:value(k.value) for k in n.keywords})
        raise AssertionError(ast.dump(n))
    for n in function.body:
        if isinstance(n, ast.Return):
            graph.output(tuple(v for v in value(n.value) if v is not None))
        elif isinstance(n, ast.Assign):
            if isinstance(n.value, ast.Constant) and n.value.value is None: continue
            assert len(n.targets)==1 and isinstance(n.targets[0],ast.Name) and isinstance(n.value,ast.Call)
            env[n.targets[0].id] = graph.call_function(value(n.value.func), tuple(value(a) for a in n.value.args),
                                                      {k.arg:value(k.value) for k in n.value.keywords})
        else: raise AssertionError(ast.dump(n))
    return torch.fx.GraphModule(torch.nn.Module(), graph)


def main():
    root = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    base = Path("/workspace/moonrobo/runs")
    original = base/"hotspot-mlp-actor-step-export-b"
    reference = base/"hotspot-shared-actor-adjoints-e"
    assert torch.cuda.mem_get_info()[0] > 24*1024**3
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    code_name, record = next(iter(json.loads((reference/"generated.json").read_text()).items()))
    code = reference/record["copy"]
    assert hashlib.sha256(code.read_bytes()).hexdigest() == record["sha256"]
    choices = root/"reference-kernel-choices.json"
    # Single-factor candidate: transfer only padding decisions. Some captured
    # kernels were still lazy at the first GEMM; they are not valid tuning
    # records and must not be treated as frozen one-choice launchers.
    choices.write_text(json.dumps(dict(smc_loaded_kernels={})))
    caches = list((reference/"inductor-cache/cache").iterdir())
    caches = [p for p in caches if p.is_file() and "cache" in json.loads(p.read_text())]
    assert len(caches)==1
    # The archive also contains unrelated 512-sample experiments with
    # contradictory cost decisions. Scope this causal candidate to the one
    # actual actor GEMM whose generated 136-column output we verified.
    selected = {k:v for k,v in json.loads(caches[0].read_text())["cache"].items()
                if isinstance(v,bool) and "torch.Size([4096, 2048])" in k
                and "torch.Size([2048, 133])" in k and "torch.bfloat16" in k
                and "op='aten.mm'" in k}
    assert len(selected)==1 and next(iter(selected.values())) is True
    assert "empty_strided_cuda((4096, 136), (136, 1), torch.bfloat16)" in code.read_text()
    selected_cache = root/"selected-padding-reference.json"
    selected_cache.write_text(json.dumps(dict(cache=selected),indent=2))
    dtype = {str(t):t for t in (torch.float32,torch.bfloat16,torch.int64,torch.bool)}
    probe=SharedProbe(Path(os.environ["MOONROBO_SHARED_INPUT"]),compiled=False)
    probe.prepare_actor()
    for p in probe.wm.parameters(): p.requires_grad_(False)
    motion=probe.ctx["motion"]
    live=[*probe.pi.parameters(),*probe.wm.parameters(),probe.pi.obs_norm.mean,probe.pi.obs_norm.var,
          probe.pi.goal_norm.mean,probe.pi.goal_norm.var,probe.wm.in_norm.mean,probe.wm.in_norm.var,
          probe.wm.out_norm.mean,probe.wm.out_norm.var,motion.root_R,probe.goals,probe.noise,probe.ctx["mdp"].default_q]
    args=[*unflatten_state(probe.state),probe.history,torch.arange(4096,device="cuda"),probe.xi,
          normalize_xi(probe.xi),probe.goals[:4096],*live]
    unchanged = {}
    for kind in ("initial", "recurrent"):
        target = root/kind
        target.mkdir()
        for p in (original/kind).iterdir():
            if p.name=="backward.so": continue
            if p.suffix in (".so", ".cubin") or p.name in ("manifest.json", "native.spec"):
                (target/p.name).write_bytes(p.read_bytes())
                unchanged[str(target/p.name)] = hashlib.sha256(p.read_bytes()).hexdigest()
        manifest = json.loads((target/"manifest.json").read_text())
        pair=Pair(original/kind)
        for i,spec in enumerate(manifest["graphs"]["forward"]["inputs"]):
            if list(args[i].stride())!=spec["stride"]:
                args[i]=torch.empty_strided(spec["shape"],spec["stride"],dtype=args[i].dtype,device="cuda").copy_(args[i])
        predictions=pair.forward(args)
        concrete=pair.values[manifest["output_count"]:]+[torch.ones_like(v) for v in predictions]
        assert len(concrete)==len(manifest["graphs"]["backward"]["inputs"])
        for i,(v,spec) in enumerate(zip(concrete,manifest["graphs"]["backward"]["inputs"])):
            assert list(v.shape)==spec["shape"] and str(v.dtype)==spec["dtype"]
            if list(v.stride())!=spec["stride"]:
                # Match the retained native CompiledBlock/Pair adapter.
                concrete[i]=torch.empty_strided(spec["shape"],spec["stride"],dtype=v.dtype,device=v.device).copy_(v)
        gm = graph_from_code((original/kind/"backward.fx.txt").read_text())
        # This graph is already past the frontend's padding pass. A backend
        # cache hook alone is insufficient here. Reproduce the explicit
        # pad -> mm -> slice subgraph found in SMC's generated backward.
        placeholders = [n for n in gm.graph.nodes if n.op=="placeholder"]
        specs = dict(zip(placeholders,manifest["graphs"]["backward"]["inputs"],strict=True))
        candidates = [n for n in gm.graph.nodes if n.op=="call_function"
                      and n.target==torch.ops.aten.mm.default and n.args[1] in specs
                      and specs[n.args[1]]["shape"]==[2048,133]
                      and specs[n.args[1]]["dtype"]=="torch.bfloat16"]
        assert len(candidates)==1
        mm = candidates[0]
        with gm.graph.inserting_before(mm):
            padded = gm.graph.call_function(torch.ops.aten.constant_pad_nd.default,(mm.args[1],[0,3],0.0))
        mm.args = (mm.args[0],padded)
        with gm.graph.inserting_after(mm):
            cropped = gm.graph.call_function(torch.ops.aten.slice.Tensor,(mm,1,0,133))
        for user in list(mm.users):
            if user is not cropped: user.replace_input_with(mm,cropped)
        gm.graph.lint()
        gm.recompile()
        output=next(n for n in gm.graph.nodes if n.op=="output")
        assert len(output.args[0])==len(manifest["gradient_indices"])
        (target/"backward.fx.txt").write_text(gm.code)
        with reference_compilation(selected_cache, code, choices, root/(kind+"-reference-decisions.json")):
            # Preserve real saved-view offsets and aliasing. Fresh aligned
            # empty tensors silently specialize a different backward contract.
            with FakeTensorMode() as fake_mode:
                examples = [fake_mode.from_tensor(v) for v in concrete]
                from torch._inductor.compile_fx import compile_fx_inner, get_cpp_wrapper_config
                from torch._inductor.virtualized import V
                options = {**get_cpp_wrapper_config(), "cpp_wrapper": True, "compile_threads": 1,
                           "aot_inductor.output_path": str(target/"backward.so")}
                with torch._inductor.config.patch(options), V.set_aot_compilation(True), torch._guards.compile_context(torch._guards.CompileContext(None)):
                    result = compile_fx_inner(gm, examples, cpp_wrapper=True, is_backward=True, is_inference=False)
                assert Path(result.filename).name=="backward.so"
        wrappers=list(target.glob("*.wrapper.cpp"))
        assert len(wrappers)==1 and "{4096L, 136L}" in wrappers[0].read_text(), "padding route was not emitted"
        (target/"saved-layouts.json").write_text(json.dumps([dict(shape=list(v.shape),stride=list(v.stride()),storage_offset=v.storage_offset(),dtype=str(v.dtype)) for v in concrete],indent=2))
        args[:6]=list(predictions[:6])
        args[6]=predictions[7]
        args[7]=args[7]+4096
        args[10]=probe.goals[4096:8192]
        pair.values=[]
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in unchanged.items())
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (root/"result.json").write_text(json.dumps(dict(exported=True,diagnostic_only=True,
        original_smc_unchanged=True, preserved_forward_and_manifest=unchanged,
        scope="native backward only; original padding decisions, no kernel-configuration transfer; full numeric acceptance pending"),indent=2))


if __name__ == "__main__": main()
