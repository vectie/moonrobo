"""Same original critic feature tensor; isolate running-statistic arithmetic."""
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import torch
from compiler_reference_contract_f import frozen_original_compilation
from shared_smc_probe_bf16_original import SharedProbe, unflatten_state, normalize_xi


def main():
    out = Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    runs = Path('/workspace/moonrobo/runs')
    ref = runs/'hotspot-shared-actor-frozen-reference-c'
    records = {r['name']: r['blob'] for r in json.loads((ref/'boundaries.json').read_text())['records']}
    def read(name):
        b = records[name]; p = ref/b['file']
        assert p.parent == ref and p.stat().st_size == int(b['count'])*8
        with p.open('rb') as f: assert hashlib.file_digest(f, 'sha256').hexdigest() == b['sha256']
        return torch.from_numpy(np.array(np.memmap(p, mode='r', dtype='<f8'))).float().reshape(b['shape']).cuda()
    probe = SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']), compiled=False)
    probe.prepare_actor()
    initial = unflatten_state(probe.state)
    states = [torch.cat([initial[i]] + [read(f'step-{t}-{name}') for t in range(32)]) for i, name in enumerate(('p','r','v','w','q','qd'))]
    p,r,v,w,q,qd = states; kin = probe.ctx['mdp'].kin; motion = probe.ctx['motion']
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
    norm = probe.critic.norm
    m0, v0, count = norm.mean.clone(), norm.var.clone(), norm.count.clone()
    with torch.no_grad(): norm.update(x)
    expected = (x-norm.mean)/torch.sqrt(norm.var+norm.eps**2)
    records = []
    for mode in ('native','variance-only','order-only','both'):
        n = x.shape[0]; total = count+n; delta = x.mean(0)-m0
        variance = x.var(0,unbiased=False) if mode in ('variance-only','both') else (x-x.mean(0)).square().mean(0)
        if mode in ('order-only','both'):
            mean = m0+delta*n/total
            var = (v0*count+variance*n+delta.square()*count*n/total)/total
        else:
            c = float(count); t = c+n
            mean = m0+delta*(n/t)
            var = (v0*c+variance*n+delta.square()*(c*n/t))*(1/t)
        normalized = (x-mean)/torch.sqrt(var+norm.eps**2)
        for name,a,b in [('mean',mean,norm.mean),('variance',var,norm.var),('normalized',normalized,expected),('bf16',normalized.bfloat16(),expected.bfloat16())]:
            d = (a.float()-b.float()).abs()
            records.append(dict(route=mode,name=name,unequal=int((a!=b).sum()),violations=int((d>2e-6+2e-4*b.abs()).sum()),max_abs=float(d.max())))
        del normalized
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,comparisons=records,
        scope='identical original compiled critic features; normalizer algorithms only, no optimizer update',
        peak_reserved=torch.cuda.max_memory_reserved()),indent=2))


if __name__ == '__main__': main()
