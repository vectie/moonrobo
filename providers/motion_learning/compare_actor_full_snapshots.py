"""CPU reuse of one verified, frozen original-SMC complete update snapshot."""
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import torch


def main(native, reference, output):
    native, reference = Path(native), Path(reference)
    report = json.loads((reference/'result.json').read_text())
    if report.get('phase')=='train':
        assert report['passed'] and len(report['launched'])>=300
    else:
        assert report['numerical_pass'] and len(report['launch_choices_verified']) >= 300
    snapshot = report['final_snapshot']; path = reference/snapshot['file']
    assert path.parent == reference and path.stat().st_size == snapshot.get('bytes',path.stat().st_size)
    with path.open('rb') as f: assert hashlib.file_digest(f,'sha256').hexdigest() == snapshot['sha256']
    original = torch.load(path, map_location='cpu', weights_only=True, mmap=True)
    final = json.loads((native/'final.json').read_text())
    result = json.loads((native/'result.json').read_text())
    assert json.loads((native/'training-guard.json').read_text())['passed']
    stdout = (native/'training.stdout.log').read_text()
    assert '"message":""' in stdout and 'FAILED' not in stdout
    comparisons=[]
    if report.get('phase')=='train':
        names=[record['name'] for record in final['records']]
        assert len(names)==len(set(names)) and set(names)==set(original['tensors']), 'complete training snapshot must include every original parameter, gradient and moment'
    def compare(name,a,b):
        a,b=np.asarray(a,dtype=np.float64),np.asarray(b,dtype=np.float64)
        assert a.shape==b.shape and np.isfinite(a).all() and np.isfinite(b).all()
        d=np.abs(a-b)
        comparisons.append(dict(name=name,unequal=int(np.count_nonzero(a!=b)),
            violations=int(np.count_nonzero(d>2e-6+2e-4*np.abs(b))),max_abs=float(d.max()),
            error2=float(np.square(d).sum()),reference2=float(np.square(b).sum())))
    for record in final['records']:
        name,b=record['name'],record['blob']; path=native/b['file']
        assert path.parent==native and path.stat().st_size==int(b['count'])*8
        with path.open('rb') as f: assert hashlib.file_digest(f,'sha256').hexdigest()==b['sha256']
        actual=np.memmap(path,mode='r',dtype='<f8',shape=b['shape'])
        compare(name,actual,original['tensors'][name].numpy())
    for i,(a,b) in enumerate(zip(final['metadata']['normalizers'],original['normalizers'])):
        assert a['count']==b['count']
        for field in ('mean','variance'):
            value=b[field].numpy() if isinstance(b[field],torch.Tensor) else b[field]
            compare(f'norm-{i}-{field}',a[field],value)
    for meta,steps in zip(final['optimizer_metadata'],original['steps']):
        assert len(meta['states'])==len(steps)
        for state,step in zip(meta['states'],steps):
            assert state['present']==(step is not None)
            if step is not None:assert int(state['step'])==step
    compare('metrics',result['rows'][-1]['metrics'],original['metrics'])
    Path(output).write_text(json.dumps(dict(numerical_pass=all(r['violations']==0 for r in comparisons),
        comparisons=comparisons,original_snapshot=snapshot,native=str(native),
        scope='complete update; all saved parameters, clipped gradients, Adam moments/steps and normalizers; no performance claim'),indent=2))


if __name__=='__main__':main(*sys.argv[1:])
