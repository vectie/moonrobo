"""CPU-only comparison of two already completed original-SMC captures."""
import json
import os
from pathlib import Path
import torch

torch.set_num_threads(2)
root = Path("/workspace/moonrobo/runs")
left = torch.load(root/"hotspot-shared-actor-adjoints-e/original-adjoints.pt", map_location="cpu", weights_only=True, mmap=True)
right = torch.load(root/"hotspot-shared-actor-adjoints-c/original-adjoints.pt", map_location="cpu", weights_only=True, mmap=True)
def compare(a, b):
    assert a.shape == b.shape and torch.isfinite(a).all() and torch.isfinite(b).all()
    d = (a-b).abs()
    return dict(shape=list(a.shape), unequal=int((a!=b).sum()), violations=int((d>2e-6+2e-4*b.abs()).sum()),
                max_abs=float(d.max()), relative_l2=float(torch.linalg.vector_norm(d.double()) / torch.linalg.vector_norm(b.double()).clamp_min(1e-30)))
report = dict(raw_gradients={k: compare(v, right["raw_gradients"][k]) for k,v in left["raw_gradients"].items()},
              cotangents={str(t): [compare(a,b) for a,b in zip(left["steps"][t]["upstream"],right["steps"][t]["upstream"])] for t in (31,15,1,0)},
              saved_specs=[dict(shape=list(v.shape),dtype=str(v.dtype),stride=list(s)) for v,s in left["selected_saved"][31]],
              input_specs=[dict(shape=list(v.shape),dtype=str(v.dtype),stride=list(s)) for v,s in left["selected_inputs"][31]])
Path(os.environ["ACTOR_COMPARE_OUTPUT"]).write_text(json.dumps(report,indent=2))
