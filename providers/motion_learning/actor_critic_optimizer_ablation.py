"""Same BF16 critic data/targets; isolate the Python versus C++ Adam arithmetic.

The explicit branch follows PyTorch v2.11.0 torch/csrc/api/src/optim/adam.cpp;
the reference uses the unchanged torch.optim.Adam selected by original SMC.
"""
import copy
import json
import math
import os
from pathlib import Path

import torch
from actor_gae_ablation_b import load_original_case


@torch.no_grad()
def cpp_step(opt, lerp):
    for group in opt.param_groups:
        assert not group['amsgrad'] and group['weight_decay']==0
        b1,b2=group['betas']
        for p in group['params']:
            state=opt.state[p]
            if not state:
                state.update(step=torch.tensor(0.),exp_avg=torch.zeros_like(p),exp_avg_sq=torch.zeros_like(p))
            state['step'].add_(1)
            step=int(state['step'])
            m,v=state['exp_avg'],state['exp_avg_sq']
            if lerp:m.lerp_(p.grad,1-b1)
            else:m.mul_(b1).add_(p.grad,alpha=1-b1)
            v.mul_(b2).addcmul_(p.grad,p.grad,value=1-b2)
            denominator=(v.sqrt()/math.sqrt(1-b2**step)).add_(group['eps'])
            p.addcdiv_(m,denominator,value=-group['lr']/(1-b1**step))


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    probe,x,rewards,failures=load_original_case(out)
    with torch.no_grad():
        probe.critic.norm.update(x)
        values=probe.critic(x).reshape(33,4096)
        carry=values[-1]; targets=[]
        for t in range(31,-1,-1):
            carry=rewards[t]+.99*(1-failures[t])*((1-.95)*values[t+1]+.95*carry)
            targets.append(carry)
        targets=torch.stack(targets[::-1]).flatten()
    model_state=copy.deepcopy(probe.critic.state_dict())
    opt=probe.opts[2]; opt_state=copy.deepcopy(opt.state_dict())
    comparisons=[]; baseline=[]
    for route in ('original','cpp','cpp-lerp','original-repeat'):
        probe.critic.load_state_dict(model_state); opt.load_state_dict(copy.deepcopy(opt_state))
        index=0
        for order in probe.orders:
            for start in range(0,131072,32768):
                ids=order[start:start+32768]
                opt.zero_grad(set_to_none=True)
                loss=(probe.critic(x[:131072][ids])-targets[ids]).square().mean()
                loss.backward()
                torch.nn.utils.clip_grad_norm_(probe.critic.parameters(),1.)
                if route.startswith('original'):opt.step()
                else:cpp_step(opt,route=='cpp-lerp')
                actual={}
                for i,p in enumerate(probe.critic.parameters()):
                    for field,value in [('parameter',p),('gradient',p.grad),('moment1',opt.state[p]['exp_avg']),('moment2',opt.state[p]['exp_avg_sq'])]:
                        actual[f'{i}-{field}']=value.detach().cpu().clone()
                if route=='original':baseline.append(actual)
                else:
                    rows=[]
                    for name,value in actual.items():
                        expected=baseline[index][name];d=(value-expected).abs()
                        rows.append(dict(name=name,unequal=int((value!=expected).sum()),
                            violations=int((d>2e-6+2e-4*expected.abs()).sum()),max_abs=float(d.max())))
                    comparisons.append(dict(route=route,step=index,rows=rows))
                index+=1
                torch.cuda.synchronize()
                assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
        (out/'progress.json').write_text(json.dumps(comparisons,indent=2))
    assert all(r['unequal']==0 for c in comparisons if c['route']=='original-repeat' for r in c['rows'])
    (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,comparisons=comparisons,
        scope='identical original compiled critic inputs, normalizer, targets and update orders; original Python Adam versus explicit C++ arithmetic; no timing claim',
        peak_reserved=torch.cuda.max_memory_reserved()),indent=2))


if __name__=='__main__':main()
