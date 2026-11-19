"""Same compiled world programs: bounded value snapshots, never timing.

Native AOTI is intercepted at its actual C ABI; SMC's original generated code
is intercepted by Python dispatch. Execution orders may differ, so match the
source FX node name, never just the position in a list. All tensor captures
are CPU snapshots; no training formula or tolerance is modified.
"""
import ast
import hashlib
import inspect
import json
import os
import re
from pathlib import Path
from types import SimpleNamespace

import torch
from torch.utils._python_dispatch import TorchDispatchMode
from precision_mlp_probe_a import read_tensor, compare
from shared_smc_probe_bf16_original import networks, WorldModel, unflatten_state, normalize_xi
from compiled_world_detail_d import Pair


class Matrices(TorchDispatchMode):
    def __init__(self):
        super().__init__()
        self.values, self.metadata, self.bytes = [], [], 0
        self.code_paths = set()
        self.kernels = {}
        self.functions = {}

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        output = func(*args, **(kwargs or {}))
        if func in (torch.ops.aten.mm.default, torch.ops.aten.mm.out,
                    torch.ops.aten.bmm.default, torch.ops.aten.bmm.out):
            frame = inspect.currentframe().f_back
            while frame:
                if "/inductor-cache/" in frame.f_code.co_filename:
                    self.code_paths.add(frame.f_code.co_filename)
                    for key,value in frame.f_globals.items():
                        if key.startswith("triton_") and hasattr(value,"launchers"):
                            self.functions[key] = value
                            self.kernels[key] = dict(configs=[str(getattr(l,"config",None)) for l in value.launchers],
                                n_launchers=len(value.launchers), cache_key=str(getattr(value,"cache_key",None)),
                                cached_best=str(getattr(value,"best_config",None)))
                    break
                frame = frame.f_back
            assert frame is not None, "generated SMC callsite not found"
            del frame
            assert len(self.metadata) < 512
            row = dict(kind="bmm" if "bmm" in str(func) else "mm", tensors=[])
            for tensor in (args[0], args[1], output):
                assert tensor.is_cuda and tensor.numel() <= 4194304
                self.bytes += tensor.numel() * tensor.element_size()
                assert self.bytes <= 3 * 1024**3
                row["tensors"].append(dict(shape=list(tensor.shape), stride=list(tensor.stride()), dtype=str(tensor.dtype)))
                self.values.append(tensor.detach().cpu().contiguous())
            self.metadata.append(row)
        return output


def labels(path, native):
    result, last = [], None
    for line in path.read_text().splitlines():
        if "Topologically Sorted Source Nodes:" in line:
            last = line.split("Source Nodes: [", 1)[1].split("]", 1)[0]
        call = re.search(r"aoti_torch_cuda_(b?mm)_out\(" if native else r"extern_kernels\.(b?mm)\(", line)
        if call:
            nodes = [n.strip() for n in last.split(",") if re.fullmatch(r"b?mm(?:_default)?(?:_\d+)?", n.strip())]
            assert len(nodes) == 1, (line, last)
            result.append((nodes[0], call[1]))
    assert len(result) == len(set(name for name, _ in result))
    return result


def padded_node_mapping(native_path, smc_path):
    """Match padding replacements through their unpadded FX operands.

    This is a source alignment aid, not a graph-equivalence assertion. Runtime
    comparisons below separately validate shapes, dtypes and zero padding.
    """
    def graph(path):
        result = {}
        for n in ast.walk(ast.parse(path.read_text())):
            if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
                key, value = n.targets[0].id, n.value
            elif isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name):
                key, value = n.target.id, n.value
            else: continue
            if isinstance(value, ast.Call): result[key] = value
        return result
    ng, sg = graph(native_path), graph(smc_path)
    def operand(n, g):
        assert isinstance(n, ast.Name)
        name = n.id
        if name in g and any(x in ast.unparse(g[name].func) for x in
                            ("aten.view.", "aten._unsafe_view.", "aten.expand.", "aten.constant_pad_nd.")):
            return operand(g[name].args[0], g)
        return name
    candidates = {}
    for name, expr in ng.items():
        if re.fullmatch(r"b?mm(?:_\d+)?", name):
            key = tuple(operand(a, ng) for a in expr.args[:2])
            assert key not in candidates
            candidates[key] = name
    result = {}
    for name, expr in sg.items():
        if re.fullmatch(r"b?mm_default(?:_\d+)?", name):
            key = tuple(operand(a, sg) for a in expr.args[:2])
            assert key in candidates, (name, key)
            result[name] = candidates[key]
    return result


def weight_join_check(path, matrix_values, gradients):
    """Replay the four explicit FP32 weight-gradient addition chains on CPU.

    Inputs are actual captured per-step GEMM results. Only the permitted
    additions, casts and permutation/view operations are interpreted.
    """
    nodes = {}
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0], ast.Name) and isinstance(node.value, ast.Call):
            nodes[node.targets[0].id] = node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target,ast.Name) and isinstance(node.value,ast.Call):
            nodes[node.target.id] = node.value
    def evaluate(name, leaves):
        if name in matrix_values:
            leaves.append(name)
            return matrix_values[name][-1]
        expr = nodes[name]; op = ast.unparse(expr.func)
        args = [a.id if isinstance(a,ast.Name) else a for a in expr.args]
        value = evaluate(args[0],leaves)
        if op.endswith("aten.add.Tensor"): return value + evaluate(args[1],leaves)
        if "convert_element_type" in op or "aten._to_copy" in op:
            assert "float32" in ast.unparse(expr)
            return value.float()
        if "aten.permute" in op: return value.permute(ast.literal_eval(args[1]))
        if "aten.view" in op: return value.reshape(ast.literal_eval(args[1]))
        raise AssertionError((name,op))
    result = []
    for index, root in ((0,"add_685"),(4,"add_679"),(8,"add_673"),(12,"add_667")):
        leaves = []; value = evaluate(root,leaves)
        assert len(leaves) == 8 and value.dtype == torch.float32
        row = compare(str(index),value,gradients[index].detach().cpu())
        row.update(root=root, partial_nodes=leaves, unequal=int(torch.count_nonzero(value != gradients[index].detach().cpu())))
        result.append(row)
    return result


def main():
    out, source = Path(os.environ["MOONROBO_SHARED_OUTPUT"]), Path(os.environ["MOONROBO_SHARED_INPUT"])
    assert torch.cuda.mem_get_info()[0] > 24 * 1024**3
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    networks.AMP_DTYPE = torch.bfloat16
    # Same configuration as the preserved original-SMC world reference.
    torch._inductor.config.trace.enabled = True
    torch._inductor.config.trace.debug_dir = str(out / "compile-debug")
    fixture = json.loads((source / "fixture.json").read_text())
    initial = json.loads((source / "initial.json").read_text())
    records = {r["name"]: r for r in fixture["records"] + initial["records"]}
    load = lambda name: read_tensor(source, records[name])
    wm = WorldModel().cuda()
    with torch.no_grad():
        for i, p in enumerate(wm.parameters()): p.copy_(load(f"world-{i}-parameter"))
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
    native = Pair(Path("/workspace/moonrobo/runs/hotspot-mlp-aoti-window-export-bf16-g/rollout"))
    pred = native.forward([s, a, xi, *params, wm.in_norm.mean, wm.in_norm.var, wm.out_norm.mean, wm.out_norm.var])
    ref = rollout(s, a, xi)
    assert all(torch.equal(n, r) for n, r in zip(pred, ref))
    common = tuple(p.detach().requires_grad_() for p in pred)
    loss, _ = error(common, target, mask)
    cotangent = torch.autograd.grad(loss, common)
    expected = torch.autograd.grad(ref, params, cotangent, retain_graph=True)
    baseline = native.backward(cotangent)
    torch.ops.moonrobo_boundary.begin()
    captured = native.backward(cotangent)
    native_values, native_metadata = torch.ops.moonrobo_boundary.take()
    native_metadata = json.loads(native_metadata)
    smc = Matrices()
    with smc:
        observed = torch.autograd.grad(ref, params, cotangent, retain_graph=True)
    assert all(torch.equal(x, y) for x, y in zip(captured, baseline)), "native instrumentation changed values"
    assert all(torch.equal(x, y) for x, y in zip(observed, expected)), "SMC instrumentation changed values"
    code = Path(os.environ["WORLD_NATIVE_WRAPPER"])
    assert len(smc.code_paths) == 1, smc.code_paths
    reference = Path(next(iter(smc.code_paths)))
    preserved = Path(os.environ["WORLD_SMC_WRAPPER"])
    assert reference.read_bytes() == preserved.read_bytes(), "actual compiled SMC code differs from frozen reference"
    nl, sl = labels(code, True), labels(reference, False)
    replacement = padded_node_mapping(Path(os.environ["WORLD_NATIVE_FX"]), Path(os.environ["WORLD_SMC_FX"]))
    sl = [(replacement.get(name, name), kind) for name, kind in sl]
    assert len(native_metadata) == len(nl) and len(smc.metadata) == len(sl), (len(native_metadata), len(nl), len(smc.metadata), len(sl))
    assert len(native_values) == 3*len(nl) and len(smc.values) == 3*len(sl)
    def capture_index(keys, metadata, values):
        rows = {}
        for i, ((name, kind), meta) in enumerate(zip(keys, metadata)):
            assert meta["kind"] == kind
            rows[name] = (meta, values[i*3:i*3+3])
        return rows
    nrows, srows = capture_index(nl, native_metadata, native_values), capture_index(sl, smc.metadata, smc.values)
    assert nrows.keys() == srows.keys(), (nrows.keys()-srows.keys(), srows.keys()-nrows.keys())
    comparisons = []
    for name, kind in nl:
        nm, nv = nrows[name]; rm, rv = srows[name]
        row = dict(node=name, kind=kind, native=nm, smc=rm, tensors=[])
        for tag, n, r in zip(("a", "b", "out"), nv, rv):
            assert n.dtype == r.dtype and n.ndim == r.ndim, (name, tag)
            cropped = False
            if n.shape != r.shape:
                # Compare logical values of an explicit compiler padding only.
                assert name in replacement.values() and all(a <= b for a,b in zip(n.shape,r.shape)), (name, tag, n.shape, r.shape)
                for dim, (a,b) in enumerate(zip(n.shape,r.shape)):
                    if a < b: assert torch.count_nonzero(r.narrow(dim,a,b-a)) == 0, (name, tag, "nonzero padding")
                r = r[tuple(slice(0, size) for size in n.shape)]
                cropped = True
            result = compare(tag, n.float(), r.float())
            result["explicit_zero_padding_cropped"] = cropped
            result["unequal"] = int(torch.count_nonzero(n != r))
            row["tensors"].append(result)
        comparisons.append(row)
        if any(t["unequal"] for t in row["tensors"]):
            print(name, [(t["name"], t["unequal"], t["max_abs"]) for t in row["tensors"]], flush=True)
    result = dict(diagnostic_only=True, acceptance_not_implied=True,
                  paired_capture_complete=True, instrumentation_bitwise_unchanged=True,
                  native_count=len(nl), smc_count=len(sl), rows=comparisons,
                  padding_node_map=replacement,
                  gradients=[compare(str(i), n, r.detach()) for i, (n, r) in enumerate(zip(baseline, expected))],
                  code_hashes={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (code, reference)},
                  reserved_peak=torch.cuda.max_memory_reserved())
    result["smc_loaded_kernels"] = smc.kernels
    def names(path):
        functions=[n for n in ast.walk(ast.parse(path.read_text())) if isinstance(n,ast.FunctionDef) and n.name=="forward"]
        assert len(functions)==1
        return [a.arg for a in functions[0].args.args if a.arg!="self"]
    native_names = names(Path(os.environ["WORLD_NATIVE_FX"]))[:-6]
    smc_names = names(Path(os.environ["WORLD_SMC_FX"]))[:-6]
    rename={"primals_6":"primals_8","primals_7":"primals_9","primals_10":"primals_12","primals_11":"primals_13",
            "primals_14":"primals_16","primals_15":"primals_17","primals_19":"primals_5","primals_21":"primals_20"}
    nsaved=dict(zip([rename.get(n,n) for n in native_names],native.values[6:],strict=True))
    rsaved=dict(zip(smc_names,ref[0].grad_fn.saved_tensors,strict=True))
    result["saved_forward"] = dict(native_only=sorted(nsaved.keys()-rsaved.keys()),smc_only=sorted(rsaved.keys()-nsaved.keys()),rows=[])
    for key,n in nsaved.items():
        if key not in rsaved: continue
        r=rsaved[key];assert n.shape==r.shape and n.dtype==r.dtype,(key,n.shape,r.shape)
        row=compare(key,n,r.detach());row["unequal"]=int(torch.count_nonzero(n!=r));result["saved_forward"]["rows"].append(row)
    result["weight_joins"] = dict(
        native=weight_join_check(Path(os.environ["WORLD_NATIVE_FX"]),{k:v for k,(_,v) in nrows.items()},baseline),
        smc=weight_join_check(Path(os.environ["WORLD_SMC_FX"]),{k:v for k,(_,v) in srows.items()},expected))
    (out / "result.json").write_text(json.dumps(result, indent=2))
    if os.environ.get("WORLD_PADDING_INTERVENTION") == "1":
        # Numerical causal ablation only: recreate exactly the shapes/strides
        # observed in ORIGINAL SMC, in the native backward shim. No SMC change.
        def clip(gs):
            norm = torch.linalg.vector_norm(torch.stack([torch.linalg.vector_norm(g,2) for g in gs]),2)
            return [g*(1./(norm+1.e-6)).clamp(max=1.) for g in gs]
        result["interventions"] = {}
        for variant in ("mm", "bmm", "both"):
            specs = []
            for index, (name, kind) in enumerate(nl):
                if name not in replacement.values() or (variant != "both" and kind != variant): continue
                rm, _ = srows[name]
                spec = [index, len(rm["tensors"][0]["shape"])]
                for tensor in rm["tensors"]: spec.extend(tensor["shape"] + tensor["stride"])
                specs.append(spec)
            torch.ops.moonrobo_boundary.configure(specs)
            if variant == "mm":
                # Release the baseline native CPU capture before another one.
                native_values.clear(); nrows.clear()
                torch.ops.moonrobo_boundary.begin()
            patched = native.backward(cotangent)
            calls, changed = torch.ops.moonrobo_boundary.finish()
            assert calls == len(nl) and changed == len(specs)
            rows = [compare(str(i), n, r.detach()) for i,(n,r) in enumerate(zip(patched,expected))]
            clipped = [compare(str(i), n, r.detach()) for i,(n,r) in enumerate(zip(clip(patched),clip(expected)))]
            result["interventions"][variant] = dict(calls=calls, changed=changed, gradients=rows, clipped=clipped,
                bitwise_unequal=sum(int(torch.count_nonzero(n != r)) for n,r in zip(patched,expected)))
            if variant == "mm":
                pv, pm = torch.ops.moonrobo_boundary.take()
                pmap = capture_index(nl,json.loads(pm),pv)
                detail = []
                for name, kind in nl:
                    _, pvals = pmap[name]; _, rvals = srows[name]
                    row = dict(node=name,kind=kind,tensors=[])
                    for tag,n,r in zip(("a","b","out"),pvals,rvals):
                        if n.shape != r.shape:
                            assert name in replacement.values()
                            r=r[tuple(slice(0,size) for size in n.shape)]
                        item=compare(tag,n.float(),r.float())
                        unequal=torch.nonzero(n != r,as_tuple=False)
                        item["unequal"]=int(unequal.shape[0])
                        item["unequal_examples"]=[dict(index=idx.tolist(),native=float(n[tuple(idx)]),smc=float(r[tuple(idx)])) for idx in unequal[:8]]
                        row["tensors"].append(item)
                    detail.append(row)
                result["interventions"][variant]["matrices"] = detail
                result["interventions"][variant]["weight_joins"] = weight_join_check(Path(os.environ["WORLD_NATIVE_FX"]),{k:v for k,(_,v) in pmap.items()},patched)
                if os.environ.get("WORLD_JOINT_CONTROL") == "1":
                    from world_joint_boundary_control_b import joint_control
                    result["joint_control"] = joint_control(out,code.read_text(),smc.functions["triton_poi_fused__to_copy_add_cat_div_expand_mm_mul_select_slice_sqrt_squeeze_sum_18"],srows,pmap,cotangent,wm)
                del pmap, pv
            print("INTERVENTION",variant,"changed",changed,"violations",sum(r["violations"] for r in rows), flush=True)
            (out / "result.json").write_text(json.dumps(result, indent=2))
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16 * 1024**3 and torch.cuda.memory_reserved() < 32 * 1024**3


if __name__ == "__main__": main()
