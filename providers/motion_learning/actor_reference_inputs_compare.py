"""Same-state comparison of original FK and native reference-data preparation."""
import hashlib
import json
import os
from pathlib import Path
import numpy as np
import torch
from shared_smc_probe_bf16_original import SharedProbe


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    root=Path('/workspace/moonrobo/runs/hotspot-shared-actor-reference-inputs-a')
    records={r['name']:r['blob'] for r in json.loads((root/'inputs.json').read_text())['records']}
    def read(name):
        b=records[name];p=root/b['file']
        assert p.parent==root and p.stat().st_size==int(b['count'])*8
        with p.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==b['sha256']
        return torch.from_numpy(np.array(np.memmap(p,mode='r',dtype='<f8'))).float().reshape(b['shape'])
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False);probe.prepare_actor()
    mdp=probe.ctx['mdp'];kin=mdp.kin;motion=probe.ctx['motion']
    expected_constants=[kin.off_p,kin.off_R,kin.axes,mdp.soft_hi,mdp.soft_lo]
    comparisons=[]
    def compare(name,a,b):
        a,b=a.detach().cpu(),b.detach().cpu();assert a.shape==b.shape
        delta=(a-b).abs();assert torch.isfinite(delta).all()
        comparisons.append(dict(name=name,unequal=int((a!=b).sum()),violations=int((delta>2e-6+2e-4*b.abs()).sum()),max_abs=float(delta.max())))
    for i,t in enumerate(expected_constants):compare('constant-'+str(i),read('constant-'+str(i)),t)
    # Original preparation computes all 33 frames in one FK call. Keep that
    # result and compare each component against both native batching choices.
    original=torch.cat([torch.cat([motion.body_p[:,i],motion.body_R[:,i].flatten(-2),motion.body_v[:,i],motion.body_w[:,i]],-1) for i in range(14)],-1).cpu().reshape(33,4096,14,18)
    for route in ('frame','whole'):
        for t in range(33):
            actual=read(f'{route}-{t}').reshape(4096,14,18)
            for name,a,b in [('p',0,3),('r',3,12),('v',12,15),('w',15,18)]:
                compare(f'{route}-{t}-{name}',actual[:,:,a:b],original[t,:,:,a:b])
    (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,numerical_pass=all(r['violations']==0 for r in comparisons),
        comparisons=comparisons,scope='same reference states; constants and per-frame versus all-frame native FK against original SMC',
        peak_reserved=torch.cuda.max_memory_reserved()),indent=2))
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3


if __name__=='__main__':main()
