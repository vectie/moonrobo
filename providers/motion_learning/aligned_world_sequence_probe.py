"""Numerical-only first/ten-step world control before the coupled benchmark."""
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import torch
from compiler_reference_contract_f import frozen_original_compilation
from shared_smc_probe_bf16_original import SharedProbe, Meter


def compare_world(probe, root):
    final=json.loads((root/'final.json').read_text()); rows=[]
    for record in final['records']:
        name=record['name']
        if not name.startswith('world-'):continue
        _,index,field=name.split('-');p=list(probe.wm.parameters())[int(index)]
        state=probe.opts[0].state[p]
        x={'parameter':p,'gradient':p.grad,'moment1':state['exp_avg'],'moment2':state['exp_avg_sq']}[field].detach().cpu().numpy().astype(np.float64)
        blob=record['blob'];path=root/blob['file']
        with path.open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==blob['sha256']
        y=np.memmap(path,mode='r',dtype='<f8',shape=tuple(blob['shape']))
        d=np.abs(x-y)
        rows.append(dict(name=name,unequal=int(np.count_nonzero(x!=y)),violations=int(np.count_nonzero(d>2e-6+2e-4*np.abs(y))),max_abs=float(d.max())))
    return dict(passed=all(r['violations']==0 for r in rows),rows=rows)


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT']);runs=Path('/workspace/moonrobo/runs')
    source=runs/'hotspot-shared-training-smc-gate-n'
    torch._inductor.config.compile_threads=1
    torch._inductor.config.fx_graph_cache=True
    torch._functorch.config.enable_autograd_cache=False
    probe=SharedProbe(os.environ['MOONROBO_SHARED_INPUT'],compiled=True)
    meter=Meter('off');comparisons=[]
    with frozen_original_compilation(source/'frozen-kernels.py',source/'frozen-choices.json',root/'frozen-decisions.json'):
        for step in range(1,11):
            metrics=probe.world_update(meter)
            if step in (1,10):
                name='hotspot-shared-training-native-world1-o' if step==1 else 'hotspot-shared-training-native-gate-k'
                report=compare_world(probe,runs/name)
                comparisons.append(dict(step=step,**report,metrics=metrics))
                values={}
                for i,p in enumerate(probe.wm.parameters()):
                    state=probe.opts[0].state[p]
                    for field,value in [('parameter',p),('gradient',p.grad),('moment1',state['exp_avg']),('moment2',state['exp_avg_sq'])]:values[f'world-{i}-{field}']=value.detach().cpu().clone()
                torch.save(values,root/f'world-step-{step}.pt');del values
            assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (root/'result.json').write_text(json.dumps(dict(diagnostic_only=True,comparisons=comparisons,memory=dict(peak_reserved=torch.cuda.max_memory_reserved())),indent=2))


if __name__=='__main__':main()
