"""Same-input, step-by-step audit after the fixed ten world updates.

No optimizer update and no timing: each native forward receives the control's
actual input. Detach between steps to bound graph memory; this is explicitly
a forward diagnostic, not a cross-step gradient acceptance test.
"""
import json
import os
from pathlib import Path
import torch
import supermimic.rotations as rotations
from shared_smc_probe_bf16_original import SharedProbe,networks,mdp_module,unflatten_state,normalize_xi
from geometry_math_revision import corrected_smc_geometry
from geometry_reference_constants_b import fp64_robot_constants,captured_padding
from frozen_training_kernels_am import frozen_training_kernels


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT']);base=Path('/workspace/moonrobo/runs')
    torch._inductor.config.compile_threads=1
    rows=[]
    def compare(name,a,b):
        assert a.shape==b.shape and torch.isfinite(a).all() and torch.isfinite(b).all()
        d=(a-b).abs();rows.append(dict(name=name,unequal=int((a!=b).sum()),max_abs=float(d.max()),violations=int((d>2e-6+2e-4*b.abs()).sum())))
    root=base/'hotspot-mlp-geometry-world-actor-graphs-export-b'
    models={k:torch._C._aoti.AOTIModelContainerRunnerCuda(str(root/k/'forward.so'),1,'cuda:0',str(root/k)) for k in ('initial','recurrent','features')}
    manifests={k:json.loads((root/k/'manifest.json').read_text()) for k in models}
    with corrected_smc_geometry(networks,mdp_module,rotations),fp64_robot_constants(),frozen_training_kernels(base/'hotspot-shared-geometry-math-reference-gate-i',out/'kernel-decisions.json'):
        probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=True)
        torch.backends.cuda.matmul.allow_tf32=False;probe.prepare_actor()
        snapshot=torch.load(base/'hotspot-shared-geometry-math-reference-gate-n/original-final.pt',map_location='cpu',weights_only=True,mmap=True)
        with torch.no_grad():
            for i,p in enumerate(probe.wm.parameters()):p.copy_(snapshot['tensors'][f'world-{i}-parameter']);p.requires_grad_(False)
            for norm,saved in zip((probe.wm.in_norm,probe.wm.out_norm),snapshot['normalizers'][:2]):
                norm.mean.copy_(torch.tensor(saved['mean'],device='cuda'));norm.var.copy_(torch.tensor(saved['variance'],device='cuda'))
        del snapshot
        ctx=probe.ctx;motion=ctx['motion'];mdp=ctx['mdp'];kin=mdp.kin
        live=[*probe.pi.parameters(),*probe.wm.parameters(),probe.pi.obs_norm.mean,probe.pi.obs_norm.var,probe.pi.goal_norm.mean,probe.pi.goal_norm.var,
              probe.wm.in_norm.mean,probe.wm.in_norm.var,probe.wm.out_norm.mean,probe.wm.out_norm.var,motion.root_R,probe.goals,probe.noise,mdp.default_q]
        S=unflatten_state(probe.state);history=probe.history;xi_n=normalize_xi(probe.xi)
        all_states=[tuple(t.detach() for t in S)]
        def run(kind,args):
            specs=manifests[kind]['graphs']['forward']['inputs'];assert len(args)==len(specs)
            adjusted=[]
            for a,s in zip(args,specs):
                assert list(a.shape)==s['shape'] and str(a.dtype)==s['dtype']
                adjusted.append(a if list(a.stride())==s['stride'] else torch.empty_strided(s['shape'],s['stride'],dtype=a.dtype,device='cuda').copy_(a))
            with torch.no_grad():return models[kind].run(adjusted)
        for t in range(32):
            frame=torch.arange(t*4096,(t+1)*4096,device='cuda');goal=probe.goals[t*4096:(t+1)*4096]
            expected=ctx['imag_step'](S,history,probe.previous,frame,probe.xi,xi_n,goal)
            actual=run('initial' if t==0 else 'recurrent',list(S)+[history,frame,probe.xi,xi_n,goal]+live)
            for key,a,b in zip(('p','r','v','w','q','qd','action','history'),actual[:8],[*expected[0],expected[1],expected[2]]):compare(f'step-{t}-{key}',a,b)
            S=tuple(v.detach().requires_grad_() for v in expected[0]);history=expected[2].detach().requires_grad_()
            all_states.append(tuple(v.detach() for v in S));del actual,expected
        state=tuple(torch.cat([s[i] for s in all_states]) for i in range(6));p,r,v,w,q,qd=state
        frames=torch.arange(33*4096,device='cuda');xis=xi_n.repeat(33,1)
        with torch.no_grad():expected=ctx['critic_input_c'](state,frames,xis,probe.goals)
        actual=run('features',[r,motion.root_p,frames,motion.root_R,kin.off_p,p,kin.off_R,kin.axes,q,qd,w,v,motion.body_p,motion.q,xis,probe.goals])[0]
        compare('critic-features',actual,expected)
        torch.cuda.synchronize();memory=dict(peak_reserved=torch.cuda.max_memory_reserved(),free=torch.cuda.mem_get_info()[0])
        assert memory['free']>16*1024**3 and memory['peak_reserved']<32*1024**3
        (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,comparisons=rows,memory=memory),indent=2))


if __name__=='__main__':main()
