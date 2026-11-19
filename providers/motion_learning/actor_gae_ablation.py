"""Isolate GAE's FP32 multiplication order with original compiled critic inputs."""
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import torch
from compiler_reference_contract_f import frozen_original_compilation
from shared_smc_probe_bf16_original import SharedProbe, unflatten_state, normalize_xi


def load_original_case(out):
    runs = Path('/workspace/moonrobo/runs')
    ref = runs/'hotspot-shared-actor-frozen-reference-c'
    records = {r['name']: r['blob'] for r in json.loads((ref/'boundaries.json').read_text())['records']}
    def read(name):
        b = records[name]; path = ref/b['file']
        assert path.parent == ref and path.stat().st_size == int(b['count'])*8
        with path.open('rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == b['sha256']
        return torch.from_numpy(np.array(np.memmap(path, mode='r', dtype='<f8'))).float().reshape(b['shape']).cuda()
    probe = SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']), compiled=False)
    probe.prepare_actor()
    initial = unflatten_state(probe.state)
    p,r,v,w,q,qd = [torch.cat([initial[i]]+[read(f'step-{t}-{name}') for t in range(32)])
                    for i,name in enumerate(('p','r','v','w','q','qd'))]
    kin, motion = probe.ctx['mdp'].kin, probe.ctx['motion']
    source = runs/'hotspot-shared-original-actor-fx-b/compile-debug/torchinductor/model__3_inference_12.6/output_code.py'
    torch._inductor.config.compile_threads = 1
    torch._inductor.config.fx_graph_cache = False
    torch._functorch.config.enable_autograd_cache = False
    from torch._inductor.codecache import PyCodeCache
    with frozen_original_compilation(ref/'frozen-kernels.py', ref/'frozen-choices.json', out/'decisions.json'):
        mod = PyCodeCache.load(source.read_text())
        x = mod.call([135168,r,motion.root_p,torch.arange(135168,device='cuda'),motion.root_R,
            kin.off_p,p,kin.off_R,kin.axes,q,qd,w,v,motion.body_p,motion.q,135168,33,
            normalize_xi(probe.xi).repeat(33,1),730,probe.goals])[0]
    return probe, x, read('rewards'), read('failures')


def main():
    out = Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    probe, x, rewards, failures = load_original_case(out)
    with torch.no_grad():
        probe.critic.norm.update(x)
        values = probe.critic(x).view(33,4096)
        targets = []
        for original_order in (True,False):
            carry = values[-1]; rows=[]
            for t in range(31,-1,-1):
                boot = .05*values[t+1]+.95*carry
                carry = rewards[t]+(.99*(1-failures[t])*boot if original_order else ((1-failures[t])*boot)*.99)
                rows.append(carry)
            targets.append(torch.stack(rows[::-1]).flatten())
    result=[]
    def compare(name,a,b):
        d=(a-b).abs()
        result.append(dict(name=name,unequal=int((a!=b).sum()),
            violations=int((d>2e-6+2e-4*b.abs()).sum()),max_abs=float(d.max())))
    compare('targets',targets[1],targets[0])
    order=probe.orders[0][:32768]
    gradients=[]
    for target in targets:
        probe.critic.zero_grad(set_to_none=True)
        prediction=probe.critic(x[:131072][order])
        (prediction-target[order]).square().mean().backward()
        gradients.append([p.grad.detach().clone() for p in probe.critic.parameters()])
    for i,(actual,expected) in enumerate(zip(gradients[1],gradients[0])):
        compare(f'gradient-{i}',actual,expected)
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,comparisons=result,
        scope='same original compiled critic input and BF16 critic; only GAE FP32 multiplication order changes; no optimizer update',
        peak_reserved=torch.cuda.max_memory_reserved()),indent=2))


if __name__ == '__main__': main()
