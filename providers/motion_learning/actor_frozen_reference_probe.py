"""Repeat unchanged SMC actor with its own recorded, fully frozen launch choices.

The original loaded-a run selects every configuration. Native settings never
influence this reference. Late reduction/coordinate retuning is disabled only
to replay those already-selected compiled artifacts reproducibly.
"""
import ast
import hashlib
import json
import os
from pathlib import Path

import torch
import actor_boundary_probe_a as boundary
from compiler_reference_contract_f import frozen_original_compilation


def observe_adjoints(probe):
    """Observe the original nodes without replacing tensors or derivatives."""
    original=probe.ctx['imag_step'];params={id(p):f'policy-{i}' for i,p in enumerate(probe.pi.parameters())}
    steps={};totals={};order=[];handles=[];incoming={};counter=0
    def step(*args):
        nonlocal counter
        t=counter;counter+=1
        result=original(*args);outputs=(*result[0],result[1],result[2]);node=result[1].grad_fn
        assert all(v.grad_fn is node for v in outputs)
        indices=[v.output_nr for v in outputs];specs=[(tuple(v.shape),v.dtype) for v in outputs]
        names=('p','r','v','w','q','qd','history')
        edges={(v.grad_fn,v.output_nr):name for name,v in zip(names,(*args[0],args[1])) if v.requires_grad}
        labels={}
        for i,edge in enumerate(node.next_functions):
            parent,_=edge
            if parent is None:continue
            p=getattr(parent,'variable',None)
            if p is not None and id(p) in params:labels[i]=params[id(p)]
            elif edge in edges:labels[i]=edges[edge]
            else:raise AssertionError((t,i,parent.name()))
        assert set(labels.values())==set(params.values())|(set(names) if t else set())
        def prehook(grads):
            incoming[t]=tuple(grads[i].detach().cpu().contiguous() if grads[i] is not None else torch.zeros(shape,dtype=dtype)
                              for i,(shape,dtype) in zip(indices,specs))
        def hook(inputs,outputs):
            order.append(t);detail={}
            for i,name in labels.items():
                value=inputs[i].detach().cpu().contiguous()
                if name.startswith('policy-'):
                    if name not in totals:totals[name]=value.clone()
                    else:totals[name].add_(value)
                if t in (0,1,15,31):detail[name]=value
            steps[t]=dict(upstream=incoming.pop(t),detail=detail)
        handles.extend((node.register_prehook(prehook),node.register_hook(hook)))
        return result
    probe.ctx['imag_step']=step
    return dict(steps=steps,order=order,parameter_join=totals,handles=handles)


def run():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    reference=Path('/workspace/moonrobo/runs/hotspot-shared-actor-loaded-a')
    loaded=json.loads((reference/'loaded-code.json').read_text())
    bundle=[];choices={};sources={}
    for i,(name,record) in enumerate(loaded.items()):
        path=reference/record['copy']
        code=path.read_text()
        assert hashlib.sha256(path.read_bytes()).hexdigest()==record['sha256']
        sources[str(path)]=record['sha256']
        for j,node in enumerate(ast.walk(ast.parse(code))):
            if not isinstance(node,ast.Call) or ast.unparse(node.func)!='async_compile.triton':continue
            symbol,source=map(ast.literal_eval,node.args[:2])
            configs=record['smc_loaded_kernels'].get(symbol,{}).get('configs',[])
            if not configs:continue  # module loaded only for autotuning, never launched
            assert len(configs)==1
            label=f'reference_{i}_{j}'
            bundle.append(f'{label} = async_compile.triton({label!r}, {source!r})')
            choices[label]=dict(configs=configs)
    code_path=root/'frozen-kernels.py';code_path.write_text('\n'.join(bundle))
    choices_path=root/'frozen-choices.json';choices_path.write_text(json.dumps(dict(smc_loaded_kernels=choices)))
    (root/'frozen-source-hashes.json').write_text(json.dumps(sources,indent=2))
    torch._inductor.config.compile_threads=1
    # A serialized static Triton bundle bypasses __init__ and can contain
    # multiple previously compiled reduction variants. Recompile the original
    # graph once under its exact-source contracts, then audit every launched
    # configuration. Generated source and all training operations stay fixed.
    torch._inductor.config.fx_graph_cache=False
    torch._functorch.config.enable_autograd_cache=False
    os.environ['ACTOR_NATIVE_BOUNDARIES']=str(reference)
    probes=[]
    original_probe=boundary.SharedProbe
    class CapturedProbe(original_probe):
        def __init__(self,*args,**kwargs):
            super().__init__(*args,**kwargs)
            probes.append(self)
        def prepare_actor(self):
            super().prepare_actor()
            if os.environ.get('ACTOR_CAPTURE_ADJOINTS')=='1':
                assert not hasattr(self,'adjoint_capture')
                self.adjoint_capture=observe_adjoints(self)
    boundary.SharedProbe=CapturedProbe
    try:
        with frozen_original_compilation(code_path,choices_path,root/'frozen-decisions.json'):
            boundary.main()
    finally:
        boundary.SharedProbe=original_probe
    assert len(probes)==1
    if hasattr(probes[0],'adjoint_capture'):
        import numpy as np
        captured=probes[0].adjoint_capture
        for handle in captured.pop('handles'):handle.remove()
        assert captured['order']==list(range(31,-1,-1)) and len(captured['steps'])==32
        records={r['name']:r['blob'] for r in json.loads((root/'boundaries.json').read_text())['records']}
        raw={}
        for name,joined in captured['parameter_join'].items():
            b=records['raw-'+name];p=root/b['file']
            with p.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==b['sha256']
            value=torch.from_numpy(np.array(np.memmap(p,mode='r',dtype='<f8'))).float().reshape(b['shape'])
            assert torch.equal(value,joined),(name,'observed backward join')
            raw[name]=value
        captured.update(raw_gradients=raw,upstream_source='original node prehook')
        torch.save(captured,root/'original-adjoints.pt')
        assert (root/'original-adjoints.pt').stat().st_size<2*1024**3
    from torch._inductor.codecache import PyCodeCache
    # Some identical modules were loaded only for autotuning. Their empty
    # launcher lists are not a choice and must not shadow a launched copy.
    by_hash={}
    for record in loaded.values():
        expected=by_hash.setdefault(record['sha256'],{})
        for name,choice in record['smc_loaded_kernels'].items():
            if not choice['configs']:continue
            assert name not in expected or expected[name]==choice
            expected[name]=choice
    actual=[]
    for module in PyCodeCache.modules:
        path=Path(module.__file__)
        digest=hashlib.sha256(path.read_bytes()).hexdigest()
        if digest not in by_hash:continue
        expected=by_hash[digest]
        for name,kernel in vars(module).items():
            if name not in expected or not hasattr(kernel,'launchers') or not kernel.launchers:continue
            configs=[str(l.config) for l in kernel.launchers]
            assert configs==expected[name]['configs'],(name,configs,expected[name])
            actual.append(dict(module_sha256=digest,kernel=name,configs=configs))
    assert len(actual)>=300,len(actual)
    report=json.loads((root/'result.json').read_text())
    report.update(reference='original SMC loaded-a choices; original source, BF16 scope and update schedule unchanged',
                  launch_choices_verified=actual,exact_source_contracts=json.loads((root/'frozen-decisions.json').read_text())['exact_source_contracts'])
    native=os.environ.get('ACTOR_NATIVE_FINAL')
    if native:
        # Runs after the original update. Reads the actual live parameters,
        # clipped gradients, Adam moments/steps and all normalizers, without
        # replacing any original inputs or derivatives.
        report['full_update_comparison']=probes[0].compare(native,report['metrics'])
    if os.environ.get('ACTOR_CAPTURE_FINAL')=='1':
        probe=probes[0]
        tensors={}
        for name,model,opt in zip(('world','policy','critic'),probe.models,probe.opts):
            for i,p in enumerate(model.parameters()):
                state=opt.state.get(p,{})
                for field,value in [('parameter',p),('gradient',p.grad),('moment1',state.get('exp_avg')),('moment2',state.get('exp_avg_sq'))]:
                    if value is not None:tensors[f'{name}-{i}-{field}']=value.detach().cpu().clone()
        norms=[]
        for norm in (probe.wm.in_norm,probe.wm.out_norm,probe.pi.obs_norm,probe.pi.goal_norm,probe.critic.norm):
            norms.append(dict(mean=norm.mean.cpu().clone(),variance=norm.var.cpu().clone(),count=float(norm.count)))
        snapshot=dict(tensors=tensors,normalizers=norms,metrics=report['metrics'],
                      steps=[[int(opt.state[p]['step']) if opt.state.get(p) else None for p in model.parameters()] for model,opt in zip(probe.models,probe.opts)])
        assert sum(t.numel()*t.element_size() for t in tensors.values())<1024**3
        torch.save(snapshot,root/'original-final.pt')
        with (root/'original-final.pt').open('rb') as f:digest=hashlib.file_digest(f,'sha256').hexdigest()
        report['final_snapshot']=dict(file='original-final.pt',sha256=digest,bytes=(root/'original-final.pt').stat().st_size)
    (root/'result.json').write_text(json.dumps(report,indent=2))
    assert report['numerical_pass'],'frozen original reference did not reproduce its own selected-artifact snapshot'


if __name__=='__main__':run()
