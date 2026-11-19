"""CPU numerical comparison of bounded native/SMC actor snapshots."""
import hashlib
import json
import sys
from pathlib import Path
import numpy as np


def main(native, smc, output):
    roots = (Path(native),Path(smc))
    indices = [{r["name"]:r["blob"] for r in json.loads((root/"boundaries.json").read_text())["records"]} for root in roots]
    assert indices[0].keys() == indices[1].keys() and len(indices[0]) < 512
    rows=[]
    dot=norm_a=norm_b=error=0.0
    for name in indices[0]:
        values=[]
        for root,index in zip(roots,indices):
            blob=index[name];path=root/blob["file"]
            assert path.parent==root and path.stat().st_size==int(blob["count"])*8
            with path.open("rb") as file: assert hashlib.file_digest(file,"sha256").hexdigest()==blob["sha256"]
            values.append(np.memmap(path,dtype="<f8",mode="r"))
        a,b=values
        assert indices[0][name]["shape"] == indices[1][name]["shape"]
        d=a-b
        rows.append(dict(name=name,count=len(a),unequal=int(np.count_nonzero(a!=b)),
            violations=int(np.count_nonzero(np.abs(d)>2e-6+2e-4*np.abs(b))),max_abs=float(np.abs(d).max())))
        if name.startswith("raw-policy-"):
            dot+=float(np.dot(a,b));norm_a+=float(np.dot(a,a));norm_b+=float(np.dot(b,b));error+=float(np.dot(d,d))
    guards=[]
    for root in roots:
        path=root/"training-guard.json"
        guards.append(json.loads(path.read_text()) if path.exists() else None)
    result=dict(scope="same-input 32-step forward boundaries and RAW policy gradients; no performance claim",
        native=str(roots[0]),smc=str(roots[1]),atol=2e-6,rtol=2e-4,
        snapshots_hash_verified=True,numerical_pass=all(r["violations"]==0 for r in rows),
        host_cgroup_guards_passed=all(g and g["passed"] for g in guards),
        native_update_completed=(roots[0]/"result.json").exists(),
        native_stdout_reports_cuda_reserve_failure="exceeded32GiB allocator envelope or16GiB free reserve" in (roots[0]/"training.stdout.log").read_text(),
        raw_policy_gradient_cosine=dot/(norm_a*norm_b)**.5,
        raw_policy_gradient_relative_l2=(error/norm_b)**.5,rows=rows)
    with Path(output).open("x") as file: json.dump(result,file,indent=2)


if __name__=="__main__": main(*sys.argv[1:])
