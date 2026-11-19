"""Read-only actual MoonBit versus original-SMC tail/reward boundaries."""
import json
import sys
from pathlib import Path
import numpy as np
import torch


def main(native,reference,output):
    native,reference=Path(native),Path(reference)
    captured=torch.load(reference/'tail-capture.pt',map_location='cpu',weights_only=True,mmap=True)
    rows={}
    pairs=[('tail-features',captured['features']),('tail-features-vjp',captured['upstream'])]
    for i,index in enumerate((2,1,8,7,5,6)):pairs.append((f'reward-gradient-{index}',captured[f'reward-{i}']))
    for name,b in pairs:
        path=native/(name+'.f32');assert path.stat().st_size==b.numel()*4
        a=np.memmap(path,mode='r',dtype='<f4',shape=tuple(b.shape)).astype(np.float64);b=b.double().numpy();d=np.abs(a-b)
        rows[name]=dict(unequal=int(np.count_nonzero(a!=b)),max_abs=float(d.max()),violations=int(np.count_nonzero(d>2e-6+2e-4*np.abs(b))))
        if name.startswith('tail-'):
            rows[name]['columns']=[dict(index=i,unequal=int(np.count_nonzero(a[:,i]!=b[:,i])),max_abs=float(d[:,i].max())) for i in range(a.shape[1]) if np.any(a[:,i]!=b[:,i])]
    Path(output).write_text(json.dumps(dict(diagnostic_only=True,comparisons=rows),indent=2))


if __name__=='__main__':main(*sys.argv[1:])
