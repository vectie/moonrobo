"""Corrected-math actor backward and detached critic graph, fixed shapes.

The source is the natural corrected control's post-grad graph, never the old
SMC geometry. Forward step binaries are preserved. Full-update gate required.
"""
import hashlib
import json
import os
from pathlib import Path
import torch
from torch._subclasses.fake_tensor import FakeTensorMode
from compiler_reference_contract_f import reference_compilation, frozen_original_compilation
from reference_fx_graph_b import read_graph
from geometry_actor_graph_b import graph_from_original
from shared_smc_probe_bf16_original import SharedProbe, unflatten_state, normalize_xi


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    base=Path('/workspace/moonrobo/runs')
    original=base/'hotspot-geometry-math-ieee-packages-a'
    capture=base/'hotspot-shared-geometry-math-reference-gate-i'
    source=capture/'compile-debug/torchinductor'
    launched=json.loads((capture/'result.json').read_text())['launched']
    assert torch.cuda.mem_get_info()[0]>24*1024**3
    torch.backends.cuda.matmul.allow_tf32=False
    torch._inductor.config.compile_threads=1
    cache=out/'padding.json';cache.write_text('{"cache":{}}')
    dtype={'torch.float32':torch.float32,'torch.bfloat16':torch.bfloat16,'torch.int64':torch.int64,'torch.bool':torch.bool}
    receipts=[]

    def choices(kind,code):
        digest=hashlib.sha256(code.read_bytes()).hexdigest()
        records={r['kernel']:{'configs':r['configs']} for r in launched if r['module_sha256']==digest}
        assert records
        path=out/(kind+'-choices.json');path.write_text(json.dumps({'smc_loaded_kernels':records}))
        return path

    def compile_graph(gm,examples,target,backward):
        from torch._inductor.compile_fx import compile_fx_inner,get_cpp_wrapper_config
        from torch._inductor.virtualized import V
        options={**get_cpp_wrapper_config(),'cpp_wrapper':True,'compile_threads':1,'aot_inductor.output_path':str(target)}
        with torch._inductor.config.patch(options),V.set_aot_compilation(True),torch._guards.compile_context(torch._guards.CompileContext(None)):
            artifact=compile_fx_inner(gm,examples,cpp_wrapper=True,is_backward=backward,is_inference=not backward)
        assert Path(artifact.filename).name==target.name

    for kind,folder in [('initial','model__2_backward_18.9'),('recurrent','model__3_backward_17.8')]:
        target=out/kind;target.mkdir()
        for p in (original/kind).iterdir():
            if p.is_file() and not p.name.startswith('backward'):
                (target/p.name).write_bytes(p.read_bytes())
        initial_names={'primals_40':'primals_51','primals_43':'primals_34','primals_44':'primals_35',
                       'primals_47':'primals_38','primals_48':'primals_39','primals_51':'primals_42',
                       'primals_52':'primals_43','primals_55':'primals_53'}
        gm=graph_from_original((source/folder/'fx_graph_readable.py').read_text(),(original/kind/'backward.fx.txt').read_text(),renames=initial_names if kind=='initial' else None)
        (target/'backward.fx.txt').write_text(gm.code)
        manifest=json.loads((target/'manifest.json').read_text())
        code=source/folder/'output_code.py';selected=choices(kind,code)
        with reference_compilation(cache,code,selected,out/(kind+'-decisions.json')):
            with FakeTensorMode():
                examples=[torch.empty_strided(s['shape'],s['stride'],dtype=dtype[s['dtype']],device='cuda') for s in manifest['graphs']['backward']['inputs']]
                compile_graph(gm,examples,target/'backward.so',True)
        manifest['backward_source']='corrected-math natural post-grad FX; argument/output permutation only'
        (target/'manifest.json').write_text(json.dumps(manifest,indent=2))
        receipts.append(dict(branch=kind,source_sha256=hashlib.sha256(code.read_bytes()).hexdigest()))

    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False)
    torch.backends.cuda.matmul.allow_tf32=False
    probe.prepare_actor()
    p,r,v,w,q,qd=[t.repeat((33,)+(1,)*(t.ndim-1)) for t in unflatten_state(probe.state)]
    mdp=probe.ctx['mdp'];kin=mdp.kin;motion=probe.ctx['motion']
    args=[135168,r,motion.root_p,torch.arange(135168,device='cuda'),motion.root_R,kin.off_p,p,
          kin.off_R,kin.axes,q,29,qd,w,v,motion.body_p,motion.q,135168,33,normalize_xi(probe.xi).repeat(33,1),730,probe.goals]
    folder=source/'model__5_inference_19.10'
    gm,names,_=read_graph((folder/'fx_graph_readable.py').read_text(),scalar_bindings={f'arg{i}_1':args[i] for i in (0,10,16,17,19)})
    concrete=[args[int(name.split('_')[0][3:])] for name in names]
    assert len(concrete)==16
    target=out/'features';target.mkdir()
    manifest=json.loads((original/'features/manifest.json').read_text())
    specs=manifest['graphs']['forward']['inputs']
    for i,s in enumerate(specs):
        assert list(concrete[i].shape)==s['shape'] and str(concrete[i].dtype)==s['dtype']
        if list(concrete[i].stride())!=s['stride']:
            concrete[i]=torch.empty_strided(s['shape'],s['stride'],device='cuda',dtype=concrete[i].dtype).copy_(concrete[i])
    code=folder/'output_code.py';selected=choices('features',code)
    (target/'forward.fx.txt').write_text(gm.code)
    with reference_compilation(cache,code,selected,out/'features-decisions.json'):
        with FakeTensorMode() as fake:
            examples=[fake.from_tensor(t) for t in concrete]
            compile_graph(gm,examples,target/'forward.so',False)
    model=torch._C._aoti.AOTIModelContainerRunnerCuda(str(target/'forward.so'),1,'cuda:0',str(target))
    from torch._inductor.codecache import PyCodeCache
    with frozen_original_compilation(code,selected,out/'features-control-decisions.json'):
        reference=PyCodeCache.load(code.read_text())
        expected=reference.call(list(args))[0]
    actual=model.run(concrete)[0]
    d=(actual-expected).abs()
    comparison=dict(max_abs=float(d.max()),unequal=int((actual!=expected).sum()),violations=int((d>2e-6+2e-4*expected.abs()).sum()))
    manifest['input_names']=names
    manifest['forward_source']='corrected-math natural critic-input graph; fixed scalar dimensions'
    (target/'manifest.json').write_text(json.dumps(manifest,indent=2))
    (target/'native.spec').write_bytes((original/'features/native.spec').read_bytes())
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (out/'result.json').write_text(json.dumps(dict(exported=True,source_graphs=receipts,features=comparison,acceptance_not_implied=True,peak_reserved=torch.cuda.max_memory_reserved()),indent=2))
    assert comparison['unequal']==0,'detached features before BF16 normalization must match the fixed corrected control'


if __name__=='__main__':main()
