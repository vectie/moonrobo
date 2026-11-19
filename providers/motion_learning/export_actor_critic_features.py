"""Export the original detached critic-input graph, specializing its row counts."""
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import torch
from torch._subclasses.fake_tensor import FakeTensorMode
from reference_fx_graph_b import read_graph
from compiler_reference_contract_f import reference_compilation, frozen_original_compilation
from shared_smc_probe_bf16_original import SharedProbe, unflatten_state, normalize_xi


def main():
    torch._inductor.config.compile_threads=1
    torch._inductor.config.fx_graph_cache=False
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT']); runs=Path('/workspace/moonrobo/runs')
    ref=runs/'hotspot-shared-actor-frozen-reference-c'
    records={r['name']:r['blob'] for r in json.loads((ref/'boundaries.json').read_text())['records']}
    def read(name):
        b=records[name];p=ref/b['file']
        assert p.parent==ref and p.stat().st_size==int(b['count'])*8
        with p.open('rb') as f: assert hashlib.file_digest(f,'sha256').hexdigest()==b['sha256']
        return torch.from_numpy(np.array(np.memmap(p,mode='r',dtype='<f8'))).float().reshape(b['shape']).cuda()
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False);probe.prepare_actor()
    initial=unflatten_state(probe.state)
    p,r,v,w,q,qd=[torch.cat([initial[i]]+[read(f'step-{t}-{name}') for t in range(32)]) for i,name in enumerate(('p','r','v','w','q','qd'))]
    mdp=probe.ctx['mdp'];kin=mdp.kin;motion=probe.ctx['motion']
    args=[135168,r,motion.root_p,torch.arange(135168,device='cuda'),motion.root_R,kin.off_p,p,
          kin.off_R,kin.axes,q,qd,w,v,motion.body_p,motion.q,135168,33,normalize_xi(probe.xi).repeat(33,1),730,probe.goals]
    folder=runs/'hotspot-shared-original-actor-fx-b/compile-debug/torchinductor/model__3_inference_12.6'
    code=folder/'output_code.py'
    gm,names,_=read_graph((folder/'fx_graph_readable.py').read_text(),scalar_bindings={f'arg{i}_1':args[i] for i in (0,15,16,18)})
    concrete=[args[int(name.split('_')[0][3:])] for name in names]
    assert len(concrete)==16 and all(isinstance(t,torch.Tensor) and not t.requires_grad for t in concrete)
    target=out/'features';target.mkdir()
    cache=out/'empty-padding-cache.json';cache.write_text(json.dumps(dict(cache={})))
    loaded=json.loads((runs/'hotspot-shared-actor-loaded-a/loaded-code.json').read_text())
    digest=hashlib.sha256(code.read_bytes()).hexdigest();match=[r for r in loaded.values() if r['sha256']==digest];assert len(match)==1
    choices=out/'choices.json';choices.write_text(json.dumps(match[0]))
    (target/'forward.fx.txt').write_text(gm.code)
    with reference_compilation(cache,code,choices,out/'decisions.json'):
        with FakeTensorMode() as fake:
            examples=[fake.from_tensor(t) for t in concrete]
            from torch._inductor.compile_fx import compile_fx_inner,get_cpp_wrapper_config
            from torch._inductor.virtualized import V
            options={**get_cpp_wrapper_config(),'cpp_wrapper':True,'compile_threads':1,'aot_inductor.output_path':str(target/'forward.so')}
            with torch._inductor.config.patch(options),V.set_aot_compilation(True),torch._guards.compile_context(torch._guards.CompileContext(None)):
                artifact=compile_fx_inner(gm,examples,cpp_wrapper=True,is_backward=False,is_inference=True)
    model=torch._C._aoti.AOTIModelContainerRunnerCuda(str(artifact.filename),1,'cuda:0',str(target))
    from torch._inductor.codecache import PyCodeCache
    with frozen_original_compilation(ref/'frozen-kernels.py',ref/'frozen-choices.json',out/'original-decisions.json'):
        original=PyCodeCache.load(code.read_text())
        expected=original.call(list(args))[0]
    actual=model.run(list(concrete))[0]
    delta=(actual-expected).abs();assert torch.isfinite(delta).all()
    comparison=dict(unequal=int((actual!=expected).sum()),violations=int((delta>2e-6+2e-4*expected.abs()).sum()),max_abs=float(delta.max()))
    specs=[dict(shape=list(t.shape),stride=list(t.stride()),dtype=str(t.dtype)) for t in concrete]
    manifest=dict(schema=3,inference_only=True,input_count=16,output_count=1,input_names=names,
        model_contract=dict(names=kin.body_names,parents=kin.parent,joints=kin.joint_idx,tracked=kin.tracked_idx,
            reward=[getattr(mdp.cfg,k) for k in ('body_pos_std','body_ori_std','body_linvel_std','body_angvel_std','root_pos_std','root_ori_std','w_action_rate','w_joint_limit','soft_limit_factor','term_height','term_tilt')]),
        graphs=dict(forward=dict(inputs=specs,output_count=1)))
    lines=['MR_AOTI_V3',torch.__version__.split('+')[0],' '.join(map(str,torch.cuda.get_device_capability())),'16 0 1','0']
    for t in concrete:lines.append(' '.join(map(str,[t.ndim,4 if t.dtype==torch.int64 else 6,*t.shape,*t.stride()])))
    (target/'native.spec').write_text('\n'.join(lines)+'\n');(target/'manifest.json').write_text(json.dumps(manifest,indent=2))
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,numerical_pass=comparison['violations']==0,
        bitwise_pass=comparison['unequal']==0,comparison=comparison,peak_reserved=torch.cuda.max_memory_reserved()),indent=2))
    assert comparison['unequal']==0,'detached critic input must reproduce original before BF16 normalization'


if __name__=='__main__':main()
