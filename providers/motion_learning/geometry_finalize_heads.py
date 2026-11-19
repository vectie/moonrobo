"""Validate fixed geometry packages with IEEE FP32 geometry and BF16 MLPs."""
import json,os
from pathlib import Path
import torch
import supermimic.rotations as rotations
from shared_smc_probe_bf16_original import SharedProbe,networks,mdp_module,normalize_xi
from geometry_math_revision import corrected_smc_geometry
from export_geometry_math_b import contract,REVISION


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT']);comparisons=[]
    def compare(name,a,b):
        d=(a-b).abs();row=dict(name=name,max_abs=float(d.max()),violations=int((d>2e-6+2e-4*b.abs()).sum()),finite=bool(torch.isfinite(d).all()))
        comparisons.append(row)
    with corrected_smc_geometry(networks,mdp_module,rotations):
        probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False)
        torch.backends.cuda.matmul.allow_tf32=False
        probe.prepare_actor();mdp=probe.ctx['mdp'];kin=mdp.kin;m=mdp.motion
        S=tuple(torch.cat([probe.read(f'reference-{i}-{key}') for i in range(33)]) for key in ('p','r','v','w','q','qd'))
        p,r,v,w,q,qd=S;f=torch.arange(33*4096,device='cuda');xi=normalize_xi(probe.xi).repeat(33,1)
        args=[r,m.root_p,f,m.root_R,kin.off_p,p,kin.off_R,kin.axes,q,qd,w,v,m.body_p,m.q,xi,probe.goals]
        folder=out/'features'
        model=torch._C._aoti.AOTIModelContainerRunnerCuda(str(folder/'forward.so'),1,'cuda:0',str(folder))
        with torch.no_grad():compare('features',model.run(args)[0],torch.cat((mdp.critic_features(S,f,xi),probe.goals),-1))
        specs=[dict(shape=list(t.shape),stride=list(t.stride()),dtype=str(t.dtype)) for t in args]
        manifest=dict(schema=3,inference_only=True,input_count=16,output_count=1,geometry_revision=REVISION,
            geometry_precision='ieee_fp32',model_contract=contract(probe),graphs=dict(forward=dict(inputs=specs,output_count=1)))
        lines=['MR_AOTI_V3',torch.__version__.split('+')[0],' '.join(map(str,torch.cuda.get_device_capability())),'16 0 1','0']
        for t in args:lines.append(' '.join(map(str,[t.ndim,4 if t.dtype==torch.int64 else 6,*t.shape,*t.stride()])))
        (folder/'native.spec').write_text('\n'.join(lines)+'\n');(folder/'manifest.json').write_text(json.dumps(manifest,indent=2))
        del model,args
        state=tuple(x[4096:].clone().requires_grad_() for x in S)
        p,r,v,w,q,qd=state
        actions=probe.previous.repeat(32,1).requires_grad_();previous=actions.detach().clone().requires_grad_()
        f=torch.arange(4096,33*4096,device='cuda')
        args=[kin.off_p,r,p,kin.off_R,kin.axes,q,qd,w,v,m.root_p,f,m.root_R,m.body_p,m.body_R,m.body_v,m.body_w,actions,previous,mdp.soft_hi,mdp.soft_lo]
        folder=out/'reward';manifest=json.loads((folder/'manifest.json').read_text())
        manifest.update(geometry_revision=REVISION,geometry_precision='ieee_fp32',model_contract=contract(probe))
        fw=torch._C._aoti.AOTIModelContainerRunnerCuda(str(folder/'forward.so'),1,'cuda:0',str(folder))
        bw=torch._C._aoti.AOTIModelContainerRunnerCuda(str(folder/'backward.so'),1,'cuda:0',str(folder))
        with torch.no_grad():
            native=fw.run(args)
            upstream=[torch.ones_like(native[0]),torch.full_like(native[1],.37)]
            saved=list(native[2:])+upstream
            for i,spec in enumerate(manifest['graphs']['backward']['inputs']):
                if list(saved[i].stride())!=spec['stride']:
                    value=torch.empty_strided(spec['shape'],spec['stride'],device='cuda',dtype=saved[i].dtype);value.copy_(saved[i]);saved[i]=value
            grads=bw.run(saved)
            values=[x.clone() for x in native[:2]]
            del native,saved
        eager=(mdp.reward(state,f,actions,previous),mdp.soft_termination(state,f))
        for i in range(2):compare('reward-output-'+str(i),values[i],eager[i])
        indices=manifest['gradient_indices']
        expected=torch.autograd.grad(eager,[args[i] for i in indices],upstream)
        for i,a,b in zip(indices,grads,expected):compare('reward-vjp-'+str(i),a,b)
        (folder/'manifest.json').write_text(json.dumps(manifest,indent=2))
        passed=all(r['finite'] and r['violations']==0 for r in comparisons)
        (out/'result.json').write_text(json.dumps(dict(exported=True,numerical_pass=passed,geometry_revision=REVISION,geometry_precision='ieee_fp32',
            compiled_artifacts_reused_from='geometry-math-heads-b',comparisons=comparisons,peak_reserved=torch.cuda.max_memory_reserved()),indent=2))
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
        assert passed,'FP32 geometry forward/VJP gate'


if __name__=='__main__':main()
