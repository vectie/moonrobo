"""Export original SMC reward/soft-termination forward and VJP dataflow.

Every physical state, action, reference and robot constant is a live explicit
input. This diagnostic preserves the original FP32 head and its gradient
joins; no native training route is enabled by an export result.
"""
import hashlib
import json
import os
from contextlib import nullcontext
from pathlib import Path

import numpy as np
import torch
from torch._subclasses.fake_tensor import FakeTensorMode
from reference_fx_graph_a import read_graph
from compiler_reference_contract_f import reference_compilation
from shared_smc_probe_bf16_original import SharedProbe


def main():
    torch._inductor.config.compile_threads=1
    torch._inductor.config.fx_graph_cache=False
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT']);base=Path('/workspace/moonrobo/runs')
    align_reductions=os.environ.get('MOONROBO_REWARD_ORIGINAL_REDUCTIONS')=='1'
    actual_code=base/'hotspot-shared-training-smc-gate-t/inductor-cache/mq/cmq64x7qx66gqo33g572gbd2unisrz6w4xwoosllqro36z3nfs5h.py'
    original_launches={}
    if align_reductions:
        from compiler_reward_reductions_c import original_dynamic_body_sum
        digest=hashlib.sha256(actual_code.read_bytes()).hexdigest()
        original_launches={row['kernel']:row['configs'][0] for row in json.loads((base/'hotspot-shared-training-smc-gate-t/result.json').read_text())['launched'] if row['module_sha256']==digest}
        assert len(original_launches)==48
    ref=base/'hotspot-shared-actor-frozen-reference-c'
    sources=base/'hotspot-shared-original-actor-fx-b/compile-debug/torchinductor'
    loaded=json.loads((base/'hotspot-shared-actor-loaded-a/loaded-code.json').read_text())
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False);probe.prepare_actor()
    records={r['name']:r['blob'] for r in json.loads((ref/'boundaries.json').read_text())['records']}
    def read(name):
        b=records[name];path=ref/b['file']
        assert path.parent==ref and path.stat().st_size==int(b['count'])*8
        with path.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==b['sha256']
        return torch.from_numpy(np.array(np.memmap(path,mode='r',dtype='<f8'))).float().reshape(b['shape']).cuda()
    state=[torch.cat([read(f'step-{t}-{n}') for t in range(32)]) for n in ('p','r','v','w','q','qd')]
    actions=torch.cat([read(f'step-{t}-action') for t in range(32)])
    previous=torch.cat([probe.previous,actions[:-4096]])
    p,r,v,w,q,qd=state;kin=probe.ctx['mdp'].kin;motion=probe.ctx['motion'];mdp=probe.ctx['mdp']
    arguments=[kin.off_p,r,p,kin.off_R,kin.axes,q,qd,w,v,motion.root_p,
               torch.arange(4096,33*4096,device='cuda'),motion.root_R,motion.body_p,motion.body_R,motion.body_v,motion.body_w,
               actions,previous,mdp.soft_hi,mdp.soft_lo]
    expected_indices=[1,2,5,6,7,8,16,17]
    for i in expected_indices:arguments[i].requires_grad_()
    target=root/'reward';target.mkdir()
    cache=root/'empty-padding-cache.json';cache.write_text(json.dumps(dict(cache={})))
    manifest=dict(schema=2,torch=torch.__version__,input_count=len(arguments),output_count=2,first_order_only=True,
                  parameter_constants=False,gradient_indices=expected_indices,graphs={},numerical_acceptance='separate full update gate required')
    manifest['model_contract']=dict(names=kin.body_names,parents=kin.parent,joints=kin.joint_idx,tracked=kin.tracked_idx,
        reward=[getattr(mdp.cfg,k) for k in ('body_pos_std','body_ori_std','body_linvel_std','body_angvel_std','root_pos_std','root_ori_std','w_action_rate','w_joint_limit','soft_limit_factor','term_height','term_tilt')])
    models={};modules={};all_outputs=None
    def spec(t):return dict(shape=list(t.shape),stride=list(t.stride()),dtype=str(t.dtype))
    for kind,folder in [('forward','model__2_forward_7.2'),('backward','model__2_backward_9.3')]:
        source=sources/folder;code=source/'output_code.py'
        gm,names,indices=read_graph((source/'fx_graph_readable.py').read_text(),filter_none=kind=='backward')
        if kind=='backward':assert indices==expected_indices
        concrete=arguments if kind=='forward' else list(all_outputs[2:])+[torch.ones_like(t) for t in all_outputs[:2]]
        assert len(names)==len(concrete)
        digest=hashlib.sha256(code.read_bytes()).hexdigest()
        matches=[r for r in loaded.values() if r['sha256']==digest];assert len(matches)==1
        selected=json.loads(json.dumps(matches[0]))
        if align_reductions and kind=='backward':
            name='triton_per_fused_sum_view_19'
            selected['smc_loaded_kernels'][name]['configs']=[original_launches[name]]
        choices=root/(kind+'-choices.json');choices.write_text(json.dumps(selected))
        (target/(kind+'.fx.txt')).write_text(gm.code)
        dynamic=(original_dynamic_body_sum(code,actual_code,original_launches['triton_per_fused_div_expand_mul_neg_sum_unsqueeze_0'],root/'dynamic-reduction-decisions.json') if align_reductions and kind=='backward' else nullcontext())
        with reference_compilation(cache,code,choices,root/(kind+'-decisions.json')),dynamic:
            with FakeTensorMode() as fake:
                examples=[fake.from_tensor(t) for t in concrete]
                from torch._inductor.compile_fx import compile_fx_inner,get_cpp_wrapper_config
                from torch._inductor.virtualized import V
                options={**get_cpp_wrapper_config(),'cpp_wrapper':True,'compile_threads':1,'aot_inductor.output_path':str(target/(kind+'.so'))}
                with torch._inductor.config.patch(options),V.set_aot_compilation(True),torch._guards.compile_context(torch._guards.CompileContext(None)):
                    artifact=compile_fx_inner(gm,examples,cpp_wrapper=True,is_backward=kind=='backward',is_inference=False)
        model=torch._C._aoti.AOTIModelContainerRunnerCuda(str(artifact.filename),1,'cuda:0',str(target))
        models[kind]=model
        manifest['graphs'][kind]=dict(path=Path(artifact.filename).name,inputs=[spec(t) for t in concrete],output_count=len(next(n for n in gm.graph.nodes if n.op=='output').args[0]))
        if kind=='forward':
            with torch.no_grad():all_outputs=model.run(list(arguments))
            assert len(all_outputs)==manifest['graphs'][kind]['output_count']
        from torch._inductor.codecache import PyCodeCache
        dynamic=(original_dynamic_body_sum(code,actual_code,original_launches['triton_per_fused_div_expand_mul_neg_sum_unsqueeze_0'],root/'dynamic-control-decisions.json') if align_reductions and kind=='backward' else nullcontext())
        with reference_compilation(cache,code,choices,root/(kind+'-original-decisions.json')),dynamic:
            modules[kind]=PyCodeCache.load(code.read_text())
        print('EXPORTED',kind,flush=True)
    codes={'torch.float32':6,'torch.int64':4,'torch.bool':11,'torch.bfloat16':15}
    lines=['MR_AOTI_V2',torch.__version__.split('+')[0],' '.join(map(str,torch.cuda.get_device_capability())),
           f"{len(arguments)} {len(manifest['graphs']['backward']['inputs'])} 2",' '.join(map(str,[len(expected_indices),*expected_indices]))]
    for kind in ('forward','backward'):
        for s in manifest['graphs'][kind]['inputs']:lines.append(' '.join(map(str,[len(s['shape']),codes[s['dtype']],*s['shape'],*s['stride']])))
    manifest['original_reduction_replay']=align_reductions
    if align_reductions:manifest['original_dynamic_code_sha256']=hashlib.sha256(actual_code.read_bytes()).hexdigest()
    (target/'native.spec').write_text('\n'.join(lines)+'\n');(target/'manifest.json').write_text(json.dumps(manifest,indent=2))
    del all_outputs
    comparisons=[]
    def compare(name,a,b):
        d=(a-b).abs();assert torch.isfinite(a).all() and torch.isfinite(b).all()
        comparisons.append(dict(name=name,unequal=int((a!=b).sum()),violations=int((d>2e-6+2e-4*b.abs()).sum()),max_abs=float(d.max())))
    for cotangent in ('reward','failure','both'):
        with torch.no_grad():
            native=models['forward'].run(list(arguments));original=modules['forward'].call(list(arguments))
            for i in range(2):compare(cotangent+'-forward-'+str(i),native[i],original[i])
            upstream=[torch.full_like(native[i],float(cotangent=='both' or (i==0)==(cotangent=='reward'))) for i in range(2)]
            actual=models['backward'].run(list(native[2:])+[t.clone() for t in upstream])
            expected=modules['backward'].call(list(original[2:])+[t.clone() for t in upstream])
            for i,g in zip(expected_indices,actual):compare(cotangent+'-gradient-'+str(i),g,expected[i])
        del native,original,actual,expected
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    if align_reductions:
        capture=torch.load(base/'hotspot-shared-actor-reward-saved-ad/actual-reward.pt',map_location='cpu',weights_only=True,mmap=True)
        p,r,v,w,q,qd=[value.cuda() for value in capture['state']]
        live=[kin.off_p,r,p,kin.off_R,kin.axes,q,qd,w,v,motion.root_p,capture['frame'].cuda(),motion.root_R,motion.body_p,motion.body_R,motion.body_v,motion.body_w,capture['action'].cuda(),capture['previous'].cuda(),mdp.soft_hi,mdp.soft_lo]
        with torch.no_grad():
            forward=models['forward'].run(live)
            actual=models['backward'].run(list(forward[2:])+[capture[f'upstream-{i}'].cuda() for i in range(2)])
            lookup={1:1,2:0,5:4,6:5,7:3,8:2}
            for i,g in zip(expected_indices,actual):
                if i in lookup:
                    expected=capture[f'gradient-{lookup[i]}'].cuda();compare('actual-coupled-gradient-'+str(i),g,expected)
                    assert torch.equal(g,expected),'actual coupled reward VJP must be bitwise equal'
        del forward,actual,live
    (root/'result.json').write_text(json.dumps(dict(exported=True,diagnostic_only=True,numerical_pass=all(r['violations']==0 for r in comparisons),comparisons=comparisons,
                                                  peak_reserved=torch.cuda.max_memory_reserved()),indent=2))


if __name__=='__main__':main()
