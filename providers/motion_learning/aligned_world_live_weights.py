"""Compare both compiled world boundaries at identical changing live weights."""
import json
import os
from pathlib import Path

import torch
from compiled_world_detail_d import Pair
from compiler_reference_contract_f import frozen_original_compilation
from shared_smc_probe_bf16_original import SharedProbe, Meter


def rows(xs,ys):
    result=[]
    for i,(a,b) in enumerate(zip(xs,ys)):
        assert a.shape==b.shape
        delta=(a-b).abs()
        result.append(dict(index=i,unequal=int(torch.count_nonzero(a!=b)),max_abs=float(delta.max()),violations=int(torch.count_nonzero(delta>2e-6+2e-4*b.abs()))))
    return result


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT']);runs=Path('/workspace/moonrobo/runs')
    source=runs/'hotspot-shared-training-smc-gate-n'
    torch._inductor.config.compile_threads=1
    torch._inductor.config.fx_graph_cache=True
    torch._functorch.config.enable_autograd_cache=False
    probe=SharedProbe(os.environ['MOONROBO_SHARED_INPUT'],compiled=True)
    package=runs/'hotspot-mlp-world-reference-export-k'
    fw,err=Pair(package/'rollout'),Pair(package/'error')
    params=tuple(probe.wm.parameters());wm=probe.wm;s=probe.world
    report=[]
    with frozen_original_compilation(source/'frozen-kernels.py',source/'frozen-choices.json',root/'frozen-decisions.json'):
        for step in range(1,11):
            np=fw.forward([s['s'],s['actions'],s['xi'],*params,wm.in_norm.mean,wm.in_norm.var,wm.out_norm.mean,wm.out_norm.var])
            sp=probe.rollout(s['s'],s['actions'],s['xi'])
            forward=rows(np,sp)
            loss,_=probe.err(sp,s['s1'],s['mask'])
            sg=torch.autograd.grad(loss,sp,retain_graph=True)
            nl=err.forward([*sp,s['s1'],s['mask'],wm.out_norm.var,probe.ctx['ERR_FLOOR']])[0]
            ng=err.backward([torch.tensor([1.,0.],device='cuda')])
            errors=rows(ng,sg)
            native=fw.backward(sg)
            original=torch.autograd.grad(sp,params,sg)
            backward=rows(native,original)
            per_norm=torch.stack([g.norm(2.) for g in original]).norm(2.)
            foreach_norm=torch.stack(torch._foreach_norm(original,2.)).norm(2.)
            per_clip=[g*(1./(per_norm+1e-6)).clamp(max=1.) for g in original]
            foreach_clip=torch._foreach_mul(original,(1./(foreach_norm+1e-6)).clamp(max=1.))
            clipping=rows(per_clip,foreach_clip)
            entry=dict(step=step,forward=forward,error_same_input=errors,backward_same_cotangent=backward,clipping=clipping,
                       norms=dict(per_tensor=float(per_norm),foreach=float(foreach_norm)),loss=rows([nl[0]],[loss]))
            report.append(entry)
            (root/'progress.json').write_text(json.dumps(report,indent=2))
            print('LIVE_WEIGHT_POINT',step,'unequal',[sum(r['unequal'] for r in x) for x in (forward,errors,backward,clipping)],flush=True)
            if any(r['unequal'] for group in (forward,errors,backward,clipping) for r in group):
                torch.save({f'world-{i}-parameter':p.detach().cpu().clone() for i,p in enumerate(params)},root/'first-divergent-weights.pt')
                break
            probe.world_update(Meter('off'))
            del sp,np,sg,ng,native,original,loss,nl
            torch.cuda.synchronize()
            assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    torch.cuda.synchronize()
    (root/'result.json').write_text(json.dumps(dict(diagnostic_only=True,points=report,memory=dict(peak_reserved=torch.cuda.max_memory_reserved())),indent=2))


if __name__=='__main__':main()
