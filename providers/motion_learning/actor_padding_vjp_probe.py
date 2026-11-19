"""Isolate native actor backward padding using verified ORIGINAL cotangents.

Each backward has a fresh forward because generated backward may reuse saved
buffers. No SMC recompilation, observer or optimizer runs in this probe.
"""
import hashlib
import json
import os
from pathlib import Path
import numpy as np
import torch
from compiled_world_detail_d import Pair
from shared_smc_probe_bf16_original import SharedProbe, unflatten_state, normalize_xi

def compare(name,a,b):
    a,b=a.detach().float().cpu(),b.detach().float().cpu()
    assert a.shape==b.shape and torch.isfinite(a).all() and torch.isfinite(b).all()
    d=(a-b).abs()
    return dict(name=name,unequal=int((a!=b).sum()),violations=int((d>2e-6+2e-4*b.abs()).sum()),
                max_abs=float(d.max()),error2=float(d.double().square().sum()),reference2=float(b.double().square().sum()))

def main():
    out=Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    runs=Path("/workspace/moonrobo/runs")
    source=runs/"hotspot-shared-actor-adjoints-c/original-adjoints.pt"
    captured=torch.load(source,map_location="cpu",weights_only=True,mmap=True)
    assert captured["upstream_source"]=="original node prehook" and captured["order"]==list(range(31,-1,-1))
    reference=runs/"hotspot-shared-actor-boundary-smc-b"
    records={r["name"]:r["blob"] for r in json.loads((reference/"boundaries.json").read_text())["records"]}
    def read(name,device="cuda"):
        blob=records[name]; path=reference/blob["file"]
        assert path.parent==reference and path.stat().st_size==int(blob["count"])*8
        with path.open("rb") as f: assert hashlib.file_digest(f,"sha256").hexdigest()==blob["sha256"]
        return torch.from_numpy(np.array(np.memmap(path,mode="r",dtype="<f8"))).float().reshape(blob["shape"]).to(device)
    verified=[compare(k,v,read("raw-"+k,"cpu")) for k,v in captured["raw_gradients"].items()]
    assert all(r["unequal"]==0 for r in verified)
    probe=SharedProbe(Path(os.environ["MOONROBO_SHARED_INPUT"]),compiled=False)
    probe.prepare_actor()
    for p in probe.wm.parameters(): p.requires_grad_(False)
    motion=probe.ctx["motion"]
    live=[*probe.pi.parameters(),*probe.wm.parameters(),probe.pi.obs_norm.mean,probe.pi.obs_norm.var,
          probe.pi.goal_norm.mean,probe.pi.goal_norm.var,probe.wm.in_norm.mean,probe.wm.in_norm.var,
          probe.wm.out_norm.mean,probe.wm.out_norm.var,motion.root_R,probe.goals,probe.noise,probe.ctx["mdp"].default_q]
    paths=dict(baseline=runs/"hotspot-mlp-actor-step-export-b",padding=runs/"hotspot-mlp-actor-backward-padding-g")
    pairs={route:{kind:Pair(path/kind) for kind in ("initial","recurrent")} for route,path in paths.items()}
    names=("p","r","v","w","q","qd","history")
    history=torch.cat([probe.history,torch.stack([read(f"step-{t}-observation") for t in range(32)],1)],1)
    totals={route:{} for route in paths}
    sections=dict(original_capture_verified=verified)
    for t in captured["order"]:
        state=unflatten_state(probe.state) if t==0 else tuple(read(f"step-{t-1}-{k}") for k in names[:6])
        upstream=[v.cuda() for v in captured["steps"][t]["upstream"]]
        expected=[read(f"step-{t}-{k}") for k in names[:6]]+[read(f"step-{t}-action"),history[:,t+1:t+11]]
        for route in paths:
            pair=pairs[route]["initial" if t==0 else "recurrent"]
            args=[*state,history[:,t:t+10],torch.arange(4096*t,4096*(t+1),device="cuda"),probe.xi,
                  normalize_xi(probe.xi),probe.goals[4096*t:4096*(t+1)],*live]
            for i,s in enumerate(pair.manifest["graphs"]["forward"]["inputs"]):
                if list(args[i].stride())!=s["stride"]:
                    args[i]=torch.empty_strided(s["shape"],s["stride"],dtype=args[i].dtype,device="cuda").copy_(args[i])
            pred=pair.forward(args)
            assert all(torch.equal(a,b) for a,b in zip(pred,expected)), (route,t,"forward")
            grads=pair.backward([v.clone() for v in upstream])
            labels={**{i:k for i,k in enumerate(names)},**{11+i:f"policy-{i}" for i in range(20)}}
            rows=[]
            for i,g in zip(pair.manifest["gradient_indices"],grads):
                k=labels[i]; value=g.detach().cpu()
                if k.startswith("policy-"):
                    if k not in totals[route]: totals[route][k]=value.clone()
                    else: totals[route][k].add_(value)
                if captured["steps"][t]["detail"]: rows.append(compare(k,value,captured["steps"][t]["detail"][k]))
            if rows: sections[f"{route}-step-{t}"]=rows
            pair.values=[]
            del pred,grads
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
        (out/"progress.json").write_text(json.dumps(dict(sections=sections,completed_step=t),indent=2))
    for route in paths:
        sections[route+"-parameter-join"]=[compare(k,v,captured["raw_gradients"][k]) for k,v in totals[route].items()]
    (out/"result.json").write_text(json.dumps(dict(diagnostic_only=True,scope="same original output cotangents at all32 steps; original forward reproduced bitwise; no performance claim",sections=sections,peak_reserved=torch.cuda.max_memory_reserved()),indent=2))

if __name__=="__main__":main()
