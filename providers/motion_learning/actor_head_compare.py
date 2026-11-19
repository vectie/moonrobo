"""Compare native actor-head VJPs against original SMC on identical states.

Each output independently receives an all-ones cotangent. No rollout,
optimizer, gradients, or numerical settings in original SMC are modified.
"""
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import torch
from shared_smc_probe_bf16_original import SharedProbe, normalize_xi


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    base=Path('/workspace/moonrobo/runs')
    reference=base/'hotspot-shared-actor-boundary-smc-b'
    native=base/'hotspot-shared-actor-head-native-d'
    prior=base/'hotspot-shared-actor-head-native-c'
    indices={reference:{r['name']:r['blob'] for r in json.loads((reference/'boundaries.json').read_text())['records']},
             native:{r['name']:r['blob'] for r in json.loads((native/'head.json').read_text())['records']},
             prior:{r['name']:r['blob'] for r in json.loads((prior/'head.json').read_text())['records']}}
    def read(root,name,device='cuda'):
        b=indices[root][name];p=root/b['file']
        assert p.parent==root and p.stat().st_size==int(b['count'])*8
        with p.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==b['sha256']
        return torch.from_numpy(np.array(np.memmap(p,mode='r',dtype='<f8'))).float().reshape(b['shape']).to(device)
    rows=[]
    def compare(name,value):
        expected=value.detach().float().cpu()
        actual=read(native,'head-'+name,'cpu')
        before=read(prior,'head-'+name,'cpu')
        assert actual.shape==expected.shape and torch.isfinite(actual).all() and torch.isfinite(expected).all()
        d=(actual-expected).abs()
        rows.append(dict(name=name,shape=list(actual.shape),unequal=int((actual!=expected).sum()),
                         max_abs=float(d.max()),violations=int((d>2e-6+2e-4*expected.abs()).sum()),
                         relative_l2=float(torch.linalg.vector_norm(d.double())/torch.linalg.vector_norm(expected.double()).clamp_min(1e-30)),
                         previous_violations=int(((before-expected).abs()>2e-6+2e-4*expected.abs()).sum()),
                         changed_by_soft_limits=int((before!=actual).sum()),
                         soft_limit_max_change=float((before-actual).abs().max())))
        (out/'progress.json').write_text(json.dumps(dict(diagnostic_only=True,comparisons=rows),indent=2))
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=True)
    probe.prepare_actor()
    for p in probe.critic.parameters():p.requires_grad_(False)
    names=('p','r','v','w','q','qd')
    state=tuple(torch.cat([read(reference,f'step-{t}-{n}') for t in range(32)]).requires_grad_() for n in names)
    action=torch.cat([read(reference,f'step-{t}-action') for t in range(32)]).requires_grad_()
    previous=torch.cat([probe.previous,action[:-4096].detach()]).requires_grad_()
    frames=torch.arange(4096,33*4096,device='cuda')
    r,d=probe.ctx['reward_term'](state,frames,action,previous)
    assert torch.equal(r,read(reference,'rewards').flatten())
    assert torch.equal(d,read(reference,'failures').flatten())
    compare('reward',r)
    compare('failure',d)
    gradients=torch.autograd.grad(r.sum(),(*state,action,previous),retain_graph=True)
    for n,g in zip((*names,'action','previous'),gradients):compare('reward-'+n,g)
    gradients=torch.autograd.grad(d.sum(),state[:2])
    for n,g in zip(names[:2],gradients):compare('failure-'+n,g)
    last=tuple(t[-4096:] for t in state)
    x=probe.ctx['_critic_input'](last,frames[-4096:],normalize_xi(probe.xi),probe.goals[-4096:])
    width=indices[native]['head-tail-features']['shape'][1]
    compare('tail-features',x[:,:width])
    tail=probe.critic(x)
    compare('tail',tail)
    for n,g in zip(names,torch.autograd.grad(tail.sum(),last)):compare('tail-'+n,g)
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,numerical_pass=all(r['violations']==0 for r in rows),
        comparisons=rows,peak_reserved=torch.cuda.max_memory_reserved()),indent=2))


if __name__=='__main__':main()
