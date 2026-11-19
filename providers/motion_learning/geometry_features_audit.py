"""Locate compiled/eager geometry discrepancies without changing tolerances."""
import json,os
from pathlib import Path
import torch
import supermimic.rotations as rotations
from shared_smc_probe_bf16_original import SharedProbe,networks,mdp_module,normalize_xi
from geometry_math_revision import corrected_smc_geometry,orthonormal_heading

out=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
with corrected_smc_geometry(networks,mdp_module,rotations),torch.no_grad():
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False);probe.prepare_actor()
    mdp=probe.ctx['mdp'];kin=mdp.kin;m=mdp.motion
    S=tuple(torch.cat([probe.read(f'reference-{i}-{key}') for i in range(33)]) for key in ('p','r','v','w','q','qd'))
    p,r,v,w,q,qd=S;f=torch.arange(33*4096,device='cuda');xi=normalize_xi(probe.xi).repeat(33,1)
    args=[r,m.root_p,f,m.root_R,kin.off_p,p,kin.off_R,kin.axes,q,qd,w,v,m.body_p,m.q,xi,probe.goals]
    folder=Path('/workspace/moonrobo/runs/hotspot-mlp-geometry-math-heads-b/features')
    model=torch._C._aoti.AOTIModelContainerRunnerCuda(str(folder/'forward.so'),1,'cuda:0',str(folder))
    actual=model.run(args)[0];expected=torch.cat((mdp.critic_features(S,f,xi),probe.goals),-1)
    d=(actual-expected).abs();bad=d>2e-6+2e-4*expected.abs()
    rows,cols=bad.nonzero(as_tuple=True)
    data=dict(violations=int(bad.sum()),max_abs=float(d.max()),finite=bool(torch.isfinite(d).all()),
              columns=bad.sum(0).cpu().tolist(),examples=[])
    for i,j in zip(rows[:16].tolist(),cols[:16].tolist()):
        R=r[i];forward2=R[0,0]**2+R[1,0]**2;left2=R[0,1]**2+R[1,1]**2
        data['examples'].append(dict(row=i,column=j,actual=float(actual[i,j]),expected=float(expected[i,j]),rotation=R.cpu().tolist(),forward2=float(forward2),left2=float(left2),heading=orthonormal_heading(R).cpu().tolist()))
    data['peak_reserved']=torch.cuda.max_memory_reserved()
    # Causal precision control, same tensors and the same compiled artifact.
    torch.backends.cuda.matmul.allow_tf32=False
    ieee=model.run(args)[0]; eager_ieee=torch.cat((mdp.critic_features(S,f,xi),probe.goals),-1)
    H64=orthonormal_heading(r.double())
    reference64=(H64.transpose(-1,-2)@r.double())[...,:,:2].reshape(-1,6)
    data['precision_controls']={}
    for name,a,b in [('ieee_compiled_vs_eager',ieee,eager_ieee),('tf32_compiled_rotation_vs_float64',actual[:,1:7],reference64),('tf32_eager_rotation_vs_float64',expected[:,1:7],reference64),('ieee_compiled_rotation_vs_float64',ieee[:,1:7],reference64),('ieee_eager_rotation_vs_float64',eager_ieee[:,1:7],reference64)]:
        delta=(a.double()-b.double()).abs();data['precision_controls'][name]=dict(max_abs=float(delta.max()),violations=int((delta>2e-6+2e-4*b.abs()).sum()))
    (out/'result.json').write_text(json.dumps(data,indent=2))
