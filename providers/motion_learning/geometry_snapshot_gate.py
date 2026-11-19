"""CPU-only comparison against the already completed corrected-math update.

Reuses an immutable reference snapshot, so a failed comparison never requires
retuning or regenerating the independent control's training graphs.
"""
import hashlib
import json
import os
from pathlib import Path
import numpy as np
import torch


def main():
    torch.set_num_threads(1)
    base=Path('/workspace/moonrobo/runs')
    reference=base/'hotspot-shared-geometry-math-reference-gate-i'
    native=base/os.environ['GEOMETRY_NATIVE_SNAPSHOT']
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    complete=json.loads((reference/'compute-completed.json').read_text())
    assert complete['memory']['free']>16*1024**3 and complete['memory']['reserved']<32*1024**3
    control=json.loads((reference/'result.json').read_text())
    assert control['peak_reserved']<32*1024**3
    path=reference/'original-final.pt'
    with path.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
    saved=torch.load(path,map_location='cpu',mmap=True,weights_only=True)
    actual=json.loads((native/'final.json').read_text())
    rows=[]
    def compare(name,a,b):
        assert a.shape==b.shape and np.isfinite(a).all() and np.isfinite(b).all()
        d=np.abs(a-b)
        rows.append(dict(name=name,elements=a.size,unequal=int(np.count_nonzero(a!=b)),max_abs=float(d.max()),violations=int(np.count_nonzero(d>2e-6+2e-4*np.abs(b)))))
    for record in actual['records']:
        name,b=record['name'],record['blob']
        p=native/b['file'];assert p.parent==native
        with p.open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==b['sha256']
        array=np.memmap(p,mode='r',dtype='<f8',shape=tuple(b['shape']))
        expected=saved['tensors'][name].numpy()
        compare(name,array,expected)
    for i,(a,b) in enumerate(zip(actual['metadata']['normalizers'],saved['normalizers'])):
        assert a['count']==b['count']
        for field in ('mean','variance'):compare(f'norm-{i}-{field}',np.asarray(a[field]),np.asarray(b[field]))
    metrics=json.loads((native/'result.json').read_text())['rows'][-1]['metrics']
    compare('metrics',np.asarray(metrics),np.asarray(saved['metrics']))
    # The completed natural control already checked all step counters against
    # this metadata. Only compiled geometry binaries change in the candidate.
    accepted_steps=json.loads((base/'hotspot-shared-geometry-math-native-gate-h/final.json').read_text())['optimizer_metadata']
    assert actual['optimizer_metadata']==accepted_steps
    result=dict(schema='moonrobo.corrected-geometry-fixed-snapshot-gate.v1',passed=not any(r['violations'] for r in rows),
                atol=2e-6,rtol=2e-4,reference_snapshot_sha256=digest,reference=str(reference),native=str(native),comparison=rows,cuda_used=False)
    result['reference_shared_reward_artifact_control']=control.get('shared_reward_artifact_control')
    result['independent_reward_accuracy_gate']=not bool(control.get('shared_reward_artifact_control'))
    (out/'result.json').write_text(json.dumps(result,indent=2))
    with path.open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==digest
    assert result['passed'],'fixed corrected-math full-update gate failed'


if __name__=='__main__':main()
