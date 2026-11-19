"""Compare actual autograd-engine joins, with no GPU execution or substitution."""
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import torch


def main(native, original, output):
    native, original = Path(native), Path(original)
    source = original/'original-adjoints.pt'
    with source.open('rb') as f:
        source_hash = hashlib.file_digest(f, 'sha256').hexdigest()
    saved = torch.load(source, map_location='cpu', weights_only=True, mmap=True)
    assert saved['order'] == list(range(31, -1, -1)) and saved['upstream_source'] == 'original node prehook'
    rows = []
    for t in saved['order']:
        for i, (name, expected) in enumerate(zip(('p','r','v','w','q','qd','action','history'), saved['steps'][t]['upstream'])):
            assert expected.dtype == torch.float32
            path = native/f'aoti-adjoint-{t}-{i}.f32'
            size = expected.numel()*4
            assert size <= 4096*990*4 and path.stat().st_size == size
            with path.open('rb') as f: digest = hashlib.file_digest(f, 'sha256').hexdigest()
            actual = np.memmap(path, mode='r', dtype='<f4', shape=tuple(expected.shape))
            a, b = actual.astype(np.float64), expected.numpy().astype(np.float64)
            d = np.abs(a-b)
            rows.append(dict(step=t, name=name, unequal=int(np.count_nonzero(a!=b)),
                violations=int(np.count_nonzero(d>2e-6+2e-4*np.abs(b))), max_abs=float(d.max()),
                error2=float(np.square(d).sum()), reference2=float(np.square(b).sum()),
                path=path.name, sha256=digest))
            if name=='r':
                rows[-1].update(unequal_by_coordinate=np.count_nonzero(a!=b,axis=0).tolist(),max_abs_by_coordinate=d.max(axis=0).tolist())
    Path(output).write_text(json.dumps(dict(diagnostic_only=True, original_sha256=source_hash,
        scope='actual engine-joined output cotangents before all 32 native/original step VJPs',
        rows=rows), indent=2))


if __name__ == '__main__': main(*sys.argv[1:])
