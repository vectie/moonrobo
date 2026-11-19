"""Export versioned corrected geometry; never mutate original SMC files.

All state, model weights and normalization buffers stay live. Original
compiled artifacts remain untouched. A completed export is not a training gate.
"""
import json
import os
from pathlib import Path
import torch
import supermimic.rotations as rotations
from shared_smc_probe_bf16_original import SharedProbe, networks, mdp_module, unflatten_state, normalize_xi
from geometry_math_revision import corrected_smc_geometry
import export_compiled_world_math as world
import export_actor_steps_math as steps

REVISION = "orthonormal-atlas-geodesic-squared-v1"


def contract(probe):
    mdp=probe.ctx['mdp']; kin=mdp.kin
    return dict(names=kin.body_names,parents=kin.parent,joints=kin.joint_idx,tracked=kin.tracked_idx,
        reward=[getattr(mdp.cfg,k) for k in ('body_pos_std','body_ori_std','body_linvel_std','body_angvel_std','root_pos_std','root_ori_std','w_action_rate','w_joint_limit','soft_limit_factor','term_height','term_tilt')])


def heads(probe, out):
    # Reuse fixed reference states as shape examples; values are runtime inputs.
    mdp=probe.ctx['mdp'];kin=mdp.kin;m=mdp.motion
    p,r,v,w,q,qd=[torch.cat([probe.read(f'reference-{i}-{key}') for i in range(1,33)]) for key in ('p','r','v','w','q','qd')]
    action=probe.previous.repeat(32,1);previous=action.clone()
    args=[kin.off_p,r,p,kin.off_R,kin.axes,q,qd,w,v,m.root_p,torch.arange(4096,33*4096,device='cuda'),m.root_R,m.body_p,m.body_R,m.body_v,m.body_w,action,previous,mdp.soft_hi,mdp.soft_lo]
    for i in (1,2,5,6,7,8,16,17):args[i].requires_grad_()
    def reward(*a):
        kin.off_p,kin.off_R,kin.axes=a[0],a[3],a[4]
        m.root_p,m.root_R,m.body_p,m.body_R,m.body_v,m.body_w=a[9],a[11],a[12],a[13],a[14],a[15]
        mdp.soft_hi,mdp.soft_lo=a[18],a[19]
        S=(a[2],a[1],a[8],a[7],a[5],a[6])
        return mdp.reward(S,a[10],a[16],a[17]),mdp.soft_termination(S,a[10])
    world.export_pair(reward,args,tuple(torch.ones(32*4096,device='cuda') for _ in range(2)),out/'reward')
    # Reinitialize to discard tracing's temporary functional tensor bindings.
    del probe,args,p,r,v,w,q,qd,action,previous
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False);probe.prepare_actor()
    mdp=probe.ctx['mdp'];kin=mdp.kin;m=mdp.motion
    states=tuple(torch.cat([probe.read(f'reference-{i}-{key}') for i in range(33)]) for key in ('p','r','v','w','q','qd'))
    p,r,v,w,q,qd=states
    args=[r,m.root_p,torch.arange(33*4096,device='cuda'),m.root_R,kin.off_p,p,kin.off_R,kin.axes,q,qd,w,v,m.body_p,m.q,normalize_xi(probe.xi).repeat(33,1),probe.goals]
    def features(*a):
        m.root_p,m.root_R,m.body_p,m.q=a[1],a[3],a[12],a[13]
        kin.off_p,kin.off_R,kin.axes=a[4],a[6],a[7]
        return (torch.cat((mdp.critic_features((a[5],a[0],a[11],a[10],a[8],a[9]),a[2],a[14]),a[15]),-1),)
    from torch.fx.experimental.proxy_tensor import make_fx
    from torch._inductor.decomposition import select_decomp_table
    target=out/'features';target.mkdir()
    with torch.no_grad():
        gm=make_fx(features,decomposition_table=select_decomp_table(),tracing_mode='fake')(*args)
        expected=features(*args)[0]
        (target/'forward.fx.txt').write_text(gm.code)
        path=torch._inductor.aot_compile(gm,tuple(args),options={'aot_inductor.output_path':str(target/'forward.so'),'compile_threads':1})
        model=torch._C._aoti.AOTIModelContainerRunnerCuda(str(path),1,'cuda:0',str(target))
        actual=model.run(args)[0]
        delta=(actual-expected).abs()
        # FP32 geometry gate; no tolerance change from existing package gates.
        violations=int((delta>2e-6+2e-4*expected.abs()).sum())
        assert torch.isfinite(delta).all() and violations==0
    specs=[dict(shape=list(t.shape),stride=list(t.stride()),dtype=str(t.dtype)) for t in args]
    manifest=dict(schema=3,inference_only=True,input_count=16,output_count=1,geometry_revision=REVISION,
        model_contract=contract(probe),graphs=dict(forward=dict(inputs=specs,output_count=1)))
    lines=['MR_AOTI_V3',torch.__version__.split('+')[0],' '.join(map(str,torch.cuda.get_device_capability())),'16 0 1','0']
    for t in args:lines.append(' '.join(map(str,[t.ndim,4 if t.dtype==torch.int64 else 6,*t.shape,*t.stride()])))
    (target/'native.spec').write_text('\n'.join(lines)+'\n');(target/'manifest.json').write_text(json.dumps(manifest,indent=2))
    path=out/'reward/manifest.json';data=json.loads(path.read_text());data['model_contract']=contract(probe);path.write_text(json.dumps(data,indent=2))
    (out/'result.json').write_text(json.dumps(dict(exported=True,geometry_revision=REVISION,features_max_abs=float(delta.max()),features_violations=violations),indent=2))


def main():
    stage=os.environ['GEOMETRY_EXPORT_STAGE'];out=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    assert stage in ('world','steps','heads')
    torch._inductor.config.compile_threads=1
    original_compile=torch._inductor.aot_compile
    def compile_graph(gm,args,*,options):
        if not options['aot_inductor.output_path'].endswith('backward.so'):
            return original_compile(gm,args,options=options)
        from torch._inductor.compile_fx import compile_fx_inner,get_cpp_wrapper_config
        from torch._inductor.virtualized import V
        with torch._inductor.config.patch({**get_cpp_wrapper_config(),**options,'cpp_wrapper':True}),V.set_aot_compilation(True),torch._guards.compile_context(torch._guards.CompileContext(None)):
            return compile_fx_inner(gm,args,cpp_wrapper=True,is_backward=True,is_inference=False).filename
    torch._inductor.aot_compile=compile_graph
    with corrected_smc_geometry(networks,mdp_module,rotations):
        if stage=='world':world.main()
        elif stage=='steps':steps.main()
        else:
            probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False);probe.prepare_actor()
            heads(probe,out)
    for path in out.glob('*/manifest.json'):
        data=json.loads(path.read_text());data['geometry_revision']=REVISION;path.write_text(json.dumps(data,indent=2))
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3


if __name__=='__main__':main()
