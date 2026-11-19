"""Export corrected geometry reward's natural forward/backward graph.

Specialize only batch dimensions; every state/action/reference remains a live
input. Compare against the fixed corrected control, not the old SMC geometry.
This does not admit a training route until its full-update gate passes.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import torch
from torch._subclasses.fake_tensor import FakeTensorMode
from compiler_reference_contract_f import reference_compilation, frozen_original_compilation
from reference_fx_graph_b import read_graph
from shared_smc_probe_bf16_original import SharedProbe


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    base=Path('/workspace/moonrobo/runs')
    capture=base/'hotspot-shared-geometry-math-reference-gate-i'
    sources=capture/'compile-debug/torchinductor'
    launched=json.loads((capture/'result.json').read_text())['launched']
    assert torch.cuda.mem_get_info()[0]>24*1024**3
    torch._inductor.config.compile_threads=1
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False)
    torch.backends.cuda.matmul.allow_tf32=False
    probe.prepare_actor()
    mdp=probe.ctx['mdp'];kin=mdp.kin;m=mdp.motion
    p,r,v,w,q,qd=[torch.cat([probe.read(f'reference-{i}-{key}') for i in range(1,33)]) for key in ('p','r','v','w','q','qd')]
    action=probe.previous.repeat(32,1);previous=action.clone();n=32*4096
    args=[kin.off_p,n,r,p,kin.off_R,kin.axes,q,29,qd,w,v,m.root_p,
          torch.arange(4096,33*4096,device='cuda'),m.root_R,m.body_p,m.body_R,m.body_v,m.body_w,n,29,action,previous,mdp.soft_hi,mdp.soft_lo]
    scalars={f'primals_{i+1}':a for i,a in enumerate(args) if type(a) is int}
    scalars.update(mul_2=3*n,mul_4324=14*n)
    target=out/'reward';target.mkdir()
    manifest=json.loads((base/'hotspot-geometry-math-ieee-packages-a/reward/manifest.json').read_text())
    manifest['gradient_indices']=[1,2,5,6,7,8,16,17]
    cache=out/'padding.json';cache.write_text('{"cache":{}}')
    models={};controls={};forward=None;reference_forward=None;rows=[]
    def compare(name,a,b):
        assert torch.isfinite(a).all() and torch.isfinite(b).all()
        d=(a-b).abs();rows.append(dict(name=name,unequal=int((a!=b).sum()),max_abs=float(d.max()),violations=int((d>2e-6+2e-4*b.abs()).sum())))
    def spec(t):return dict(shape=list(t.shape),stride=list(t.stride()),dtype=str(t.dtype))
    forward_scalar_outputs=None
    for kind,folder in [('forward','model__4_forward_15.6'),('backward','model__4_backward_16.7')]:
        source=sources/folder;code=source/'output_code.py';listing=(source/'fx_graph_readable.py').read_text()
        bindings={k:v for k,v in scalars.items() if k in listing.split('\n')[1]}
        gm,names,indices=read_graph(listing,filter_none=kind=='backward',scalar_bindings=bindings)
        output=next(node for node in gm.graph.nodes if node.op=='output')
        if kind=='forward':
            values=output.args[0]
            forward_scalar_outputs=[i for i,x in enumerate(values) if type(x) is int]
            returned=next(x for x in ast.walk(ast.parse(listing)) if isinstance(x,ast.Return))
            returned_names=[x.id for x in returned.value.elts]
            saved_names=[name for i,name in enumerate(returned_names) if i>=2 and i not in forward_scalar_outputs]
            output.args=(tuple(x for x in values if type(x) is not int),)
            concrete=[args[int(name.split('_')[1])-1] for name in names]
        else:
            assert indices==[2,3,6,8,9,10,20,21]
            assert names==saved_names+['tangents_1','tangents_2'],(names,saved_names)
            concrete=list(forward[2:])+[torch.ones_like(x) for x in forward[:2]]
        gm.recompile();gm.graph.lint()
        (target/(kind+'.fx.txt')).write_text(gm.code)
        digest=hashlib.sha256(code.read_bytes()).hexdigest()
        records={r['kernel']:{'configs':r['configs']} for r in launched if r['module_sha256']==digest}
        assert records
        choices=out/(kind+'-choices.json');choices.write_text(json.dumps({'smc_loaded_kernels':records}))
        with reference_compilation(cache,code,choices,out/(kind+'-decisions.json')):
            with FakeTensorMode() as fake:
                examples=[fake.from_tensor(t) for t in concrete]
                from torch._inductor.compile_fx import compile_fx_inner,get_cpp_wrapper_config
                from torch._inductor.virtualized import V
                options={**get_cpp_wrapper_config(),'cpp_wrapper':True,'compile_threads':1,'aot_inductor.output_path':str(target/(kind+'.so'))}
                with torch._inductor.config.patch(options),V.set_aot_compilation(True),torch._guards.compile_context(torch._guards.CompileContext(None)):
                    artifact=compile_fx_inner(gm,examples,cpp_wrapper=True,is_backward=kind=='backward',is_inference=False)
        models[kind]=torch._C._aoti.AOTIModelContainerRunnerCuda(str(artifact.filename),1,'cuda:0',str(target))
        manifest['graphs'][kind]=dict(path=kind+'.so',inputs=[spec(t) for t in concrete],output_count=len(output.args[0]))
        from torch._inductor.codecache import PyCodeCache
        with frozen_original_compilation(code,choices,out/(kind+'-control-decisions.json')):
            controls[kind]=PyCodeCache.load(code.read_text())
        if kind=='forward':
            with torch.no_grad():
                forward=models[kind].run(concrete)
                reference_forward=controls[kind].call(list(args))
            tensor_reference=[v for v in reference_forward if isinstance(v,torch.Tensor)]
            assert len(tensor_reference)==len(forward)
            for i in range(2):compare('forward-'+str(i),forward[i],tensor_reference[i])
        else:
            for name,tangents in [('reward',(1.,0.)),('failure',(0.,1.)),('both',(1.,1.))]:
                upstream=[torch.full_like(x,v) for x,v in zip(forward[:2],tangents)]
                with torch.no_grad():
                    actual=models[kind].run(list(forward[2:])+[t.clone() for t in upstream])
                    saved=dict(zip(returned_names,reference_forward))
                    saved.update(tangents_1=upstream[0].clone(),tangents_2=upstream[1].clone())
                    fn=next(x for x in ast.walk(ast.parse(listing)) if isinstance(x,ast.FunctionDef))
                    expected=controls[kind].call([saved[x.arg] for x in fn.args.args if x.arg!='self'])
                expected=[v for v in expected if v is not None]
                assert len(actual)==len(expected)==8
                for i,a,b in zip(manifest['gradient_indices'],actual,expected):compare(name+'-vjp-'+str(i),a,b)
        print('EXPORTED',kind,flush=True)
    codes={'torch.float32':6,'torch.int64':4,'torch.bool':11,'torch.bfloat16':15}
    lines=['MR_AOTI_V4',torch.__version__.split('+')[0],' '.join(map(str,torch.cuda.get_device_capability())),
           f"20 {len(manifest['graphs']['backward']['inputs'])} 2",'8 1 2 5 6 7 8 16 17','ieee']
    for kind in ('forward','backward'):
        for s in manifest['graphs'][kind]['inputs']:lines.append(' '.join(map(str,[len(s['shape']),codes[s['dtype']],*s['shape'],*s['stride']])))
    manifest['source']='corrected natural post-grad reward; fixed scalar dimensions; unchanged tensor dataflow'
    (target/'manifest.json').write_text(json.dumps(manifest,indent=2));(target/'native.spec').write_text('\n'.join(lines)+'\n')
    torch.cuda.synchronize()
    memory=dict(peak_reserved=torch.cuda.max_memory_reserved(),free=torch.cuda.mem_get_info()[0])
    assert memory['free']>16*1024**3 and memory['peak_reserved']<32*1024**3
    result=dict(exported=True,numerical_pass=all(r['violations']==0 for r in rows),comparisons=rows,memory=memory,full_update_gate_required=True)
    (out/'result.json').write_text(json.dumps(result,indent=2))
    assert result['numerical_pass']


if __name__=='__main__':main()
