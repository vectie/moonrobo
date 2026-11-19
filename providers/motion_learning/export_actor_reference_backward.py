"""Native candidate from original SMC post-grad FX and its kernel choices.

Only argument/output permutations change. All original saved forward libraries
remain immutable. This export is not an acceptance or performance result.
"""
import ast
import hashlib
import json
import os
from pathlib import Path

import torch
from torch._subclasses.fake_tensor import FakeTensorMode
from compiler_reference_contract_d import reference_compilation
from compiled_world_detail_d import Pair
from shared_smc_probe_bf16_original import SharedProbe,unflatten_state,normalize_xi


RENAMES={'primals_16':'primals_47','primals_27':'primals_2','primals_35':'primals_51',
         'primals_38':'primals_34','primals_39':'primals_35','primals_42':'primals_38',
         'primals_43':'primals_39','primals_46':'primals_42','primals_47':'primals_43',
         'primals_50':'primals_53'}


def graph_from_original(original,native):
    fn=next(n for n in ast.walk(ast.parse(original)) if isinstance(n,ast.FunctionDef) and n.name=='forward')
    nfn=next(n for n in ast.walk(ast.parse(native)) if isinstance(n,ast.FunctionDef) and n.name=='forward')
    names=[a.arg for a in nfn.args.args if a.arg!='self']
    graph=torch.fx.Graph()
    placeholders={name:graph.placeholder(name) for name in names}
    env={a.arg:placeholders[RENAMES.get(a.arg,a.arg)] for a in fn.args.args if a.arg!='self'}
    assert set(env.values())==set(placeholders.values())
    def value(n):
        if isinstance(n,ast.Name):return env[n.id] if n.id in env else {'torch':torch,'inf':float('inf')}[n.id]
        if isinstance(n,ast.Constant):return n.value
        if isinstance(n,ast.Attribute):return getattr(value(n.value),n.attr)
        if isinstance(n,ast.List):return [value(x) for x in n.elts]
        if isinstance(n,ast.Tuple):return tuple(value(x) for x in n.elts)
        if isinstance(n,ast.UnaryOp) and isinstance(n.op,ast.USub):return -value(n.operand)
        if isinstance(n,ast.Call) and ast.unparse(n.func)=='device':return torch.device(*[value(a) for a in n.args],**{k.arg:value(k.value) for k in n.keywords})
        raise AssertionError(ast.dump(n))
    for n in fn.body:
        if isinstance(n,ast.AnnAssign):
            assert isinstance(n.value,ast.Call) and n.target.id not in env
            env[n.target.id]=graph.call_function(value(n.value.func),tuple(value(a) for a in n.value.args),{k.arg:value(k.value) for k in n.value.keywords})
        elif isinstance(n,ast.Return):
            original_outputs=[x.id for x in n.value.elts if isinstance(x,ast.Name)]
        else:assert isinstance(n,ast.Assign) and isinstance(n.value,ast.Constant) and n.value.value is None
    returned=next(n for n in nfn.body if isinstance(n,ast.Return))
    native_outputs=[x.id for x in returned.value.elts if isinstance(x,ast.Name)]
    assert set(native_outputs)==set(original_outputs) and len(native_outputs)==len(original_outputs)
    graph.output(tuple(env[name] for name in native_outputs))
    return torch.fx.GraphModule(torch.nn.Module(),graph)


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    base=Path('/workspace/moonrobo/runs')
    original=base/'hotspot-mlp-actor-step-export-b'
    source=base/'hotspot-shared-original-actor-fx-b/compile-debug/torchinductor'
    loaded=json.loads((base/'hotspot-shared-actor-loaded-a/loaded-code.json').read_text())
    assert torch.cuda.mem_get_info()[0]>24*1024**3
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False)
    probe.prepare_actor()
    for p in probe.wm.parameters():p.requires_grad_(False)
    live=[*probe.pi.parameters(),*probe.wm.parameters(),probe.pi.obs_norm.mean,probe.pi.obs_norm.var,
          probe.pi.goal_norm.mean,probe.pi.goal_norm.var,probe.wm.in_norm.mean,probe.wm.in_norm.var,
          probe.wm.out_norm.mean,probe.wm.out_norm.var,probe.ctx['motion'].root_R,probe.goals,probe.noise,probe.ctx['mdp'].default_q]
    args=[*unflatten_state(probe.state),probe.history,torch.arange(4096,device='cuda'),probe.xi,normalize_xi(probe.xi),probe.goals[:4096],*live]
    unchanged={}
    receipts=[]
    cache=root/'empty-padding-cache.json'
    cache.write_text(json.dumps(dict(cache={})))
    for kind,folder in [('initial','model__0_backward_11.5'),('recurrent','model__1_backward_10.4')]:
        target=root/kind;target.mkdir()
        for p in (original/kind).iterdir():
            if p.name=='backward.so':continue
            if p.suffix in ('.so','.cubin') or p.name in ('manifest.json','native.spec'):
                dest=target/p.name;dest.write_bytes(p.read_bytes())
                unchanged[str(dest)]=hashlib.sha256(dest.read_bytes()).hexdigest()
        manifest=json.loads((target/'manifest.json').read_text())
        pair=Pair(original/kind)
        for i,s in enumerate(manifest['graphs']['forward']['inputs']):
            if list(args[i].stride())!=s['stride']:args[i]=torch.empty_strided(s['shape'],s['stride'],device='cuda',dtype=args[i].dtype).copy_(args[i])
        predicted=pair.forward(args)
        concrete=pair.values[manifest['output_count']:]+[torch.ones_like(v) for v in predicted]
        for i,s in enumerate(manifest['graphs']['backward']['inputs']):
            if list(concrete[i].stride())!=s['stride']:concrete[i]=torch.empty_strided(s['shape'],s['stride'],device='cuda',dtype=concrete[i].dtype).copy_(concrete[i])
        gm=graph_from_original((source/folder/'fx_graph_readable.py').read_text(),(original/kind/'backward.fx.txt').read_text())
        (target/'backward.fx.txt').write_text(gm.code)
        code=source/folder/'output_code.py'
        digest=hashlib.sha256(code.read_bytes()).hexdigest()
        records=[r for r in loaded.values() if r['sha256']==digest]
        assert len(records)==1
        choices=root/(kind+'-choices.json');choices.write_text(json.dumps(records[0]))
        with reference_compilation(cache,code,choices,root/(kind+'-reference-decisions.json')):
            with FakeTensorMode() as fake:
                examples=[fake.from_tensor(v) for v in concrete]
                from torch._inductor.compile_fx import compile_fx_inner,get_cpp_wrapper_config
                from torch._inductor.virtualized import V
                options={**get_cpp_wrapper_config(),'cpp_wrapper':True,'compile_threads':1,'aot_inductor.output_path':str(target/'backward.so')}
                with torch._inductor.config.patch(options),V.set_aot_compilation(True),torch._guards.compile_context(torch._guards.CompileContext(None)):
                    artifact=compile_fx_inner(gm,examples,cpp_wrapper=True,is_backward=True,is_inference=False)
                assert Path(artifact.filename).name=='backward.so'
        receipts.append(dict(branch=kind,original_code_sha256=digest,original_graph_sha256=hashlib.sha256((source/folder/'fx_graph_readable.py').read_bytes()).hexdigest()))
        args[:6]=list(predicted[:6]);args[6]=predicted[7];args[7]=args[7]+4096;args[10]=probe.goals[4096:8192]
        pair.values=[]
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in unchanged.items())
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (root/'result.json').write_text(json.dumps(dict(exported=True,diagnostic_only=True,acceptance_not_implied=True,
        original_smc_unchanged=True,source_graphs=receipts,preserved_artifacts=unchanged),indent=2))


if __name__=='__main__':main()
