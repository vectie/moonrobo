"""Read-only actor boundary diagnosis with independent corrected geometry.

Restore the immutable, already verified ten-world-update parameters. Capture
values without replacing computations, and compare the native actual tensors.
No training timing or optimization acceptance is inferred from this probe.
"""
import hashlib
import json
import os
from pathlib import Path
import numpy as np
import torch
import supermimic.rotations as rotations
from shared_smc_probe_bf16_original import SharedProbe,Meter,networks,mdp_module
from geometry_math_revision import corrected_smc_geometry
from geometry_reference_constants_b import fp64_robot_constants
from frozen_training_kernels_am import frozen_training_kernels


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT']);base=Path('/workspace/moonrobo/runs')
    native=base/'hotspot-shared-geometry-boundary-native-a'
    index={r['name']:r['blob'] for r in json.loads((native/'boundaries.json').read_text())['records']}
    rows=[];captured={};used=0
    def capture(name,value):
        nonlocal used
        a=value.detach().float().cpu();used+=a.numel()*4
        assert used<=64*1024**2 and name not in captured
        captured[name]=a
        blob=index[name];path=native/blob['file']
        with path.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==blob['sha256']
        b=np.memmap(path,mode='r',dtype='<f8',shape=tuple(blob['shape']))
        x=a.numpy().reshape(b.shape);assert np.isfinite(x).all() and np.isfinite(b).all()
        d=np.abs(x-b)
        rows.append(dict(name=name,unequal=int(np.count_nonzero(x!=b)),max_abs=float(d.max()),violations=int(np.count_nonzero(d>2e-6+2e-4*np.abs(x)))))
    torch._inductor.config.compile_threads=1
    with corrected_smc_geometry(networks,mdp_module,rotations),fp64_robot_constants(),frozen_training_kernels(base/'hotspot-shared-geometry-math-reference-gate-i',out/'kernel-decisions.json'):
        probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=True)
        torch.backends.cuda.matmul.allow_tf32=False;probe.prepare_actor();probe.reset()
        snapshot=torch.load(base/'hotspot-shared-geometry-math-reference-gate-n/original-final.pt',map_location='cpu',weights_only=True,mmap=True)
        with torch.no_grad():
            for i,p in enumerate(probe.wm.parameters()):p.copy_(snapshot['tensors'][f'world-{i}-parameter'])
            for norm,saved in zip((probe.wm.in_norm,probe.wm.out_norm),snapshot['normalizers'][:2]):
                norm.mean.copy_(torch.tensor(saved['mean'],device='cuda'));norm.var.copy_(torch.tensor(saved['variance'],device='cuda'));norm.count.fill_(saved['count'])
        del snapshot
        reward=probe.ctx['reward_term']
        def capture_reward(state,*args):
            values=reward(state,*args)
            capture('rewards',values[0].reshape(32,4096));capture('failures',values[1].reshape(32,4096))
            for name,t in zip(('p','r','v','w','q','qd'),state):capture('final-'+name,t[-4096:])
            return values
        probe.ctx['reward_term']=capture_reward
        calls=0
        def critic_hook(module,args,output):
            nonlocal calls
            if calls==0:
                capture('tail-input',args[0]);capture('tail',output)
            elif calls==1:capture('bootstrap',output)
            else:capture(f'prediction-{calls-2}',output)
            calls+=1
        hook=probe.critic.register_forward_hook(critic_hook)
        clip=torch.nn.utils.clip_grad_norm_
        def capture_clip(parameters,*args,**kwargs):
            ps=list(parameters)
            if ps and ps[0] is next(probe.pi.parameters()):capture('raw-policy-18',ps[18].grad)
            return clip(ps,*args,**kwargs)
        torch.nn.utils.clip_grad_norm_=capture_clip
        try:metrics=probe.actor_update(Meter('off'))
        finally:hook.remove();torch.nn.utils.clip_grad_norm_=clip
        assert calls==22
        # Reconstruct the exact original GPU recurrence from the recorded inputs;
        # the compiled training path above was not changed by this diagnostic.
        with torch.no_grad():
            v=captured['bootstrap'].cuda().reshape(33,4096)
            r=captured['rewards'].cuda();d=captured['failures'].cuda();carry=v[-1];targets=[]
            for t in range(31,-1,-1):
                carry=r[t]+.99*(1-d[t])*((1-.95)*v[t+1]+.95*carry);targets.append(carry)
            capture('targets',torch.stack(targets[::-1]).reshape(-1))
        torch.cuda.synchronize();memory=dict(free=torch.cuda.mem_get_info()[0],peak_reserved=torch.cuda.max_memory_reserved())
        assert set(captured)==set(index)
        torch.save(captured,out/'captured.pt')
        memory_pass=memory['free']>16*1024**3 and memory['peak_reserved']<32*1024**3
        (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,comparisons=rows,metrics=metrics,memory=memory,memory_guard_passed=memory_pass),indent=2))
        assert memory_pass,'memory guard: diagnostic evidence retained, no acceptance'


if __name__=='__main__':main()
