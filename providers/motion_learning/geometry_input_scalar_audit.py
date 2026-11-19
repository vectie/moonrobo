"""Check inputs outside exported graphs, including centered sim context."""
import json
import os
from pathlib import Path
import torch
from shared_smc_probe_bf16_original import SharedProbe,normalize_xi


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT']);base=Path('/workspace/moonrobo/runs')
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False)
    x=probe.xi
    centered=normalize_xi(x)
    affine=torch.cat((x[:,:1]*(1/.45)+(-.75/.45),x[:,1:30]*100.,x[:,30:]*20.),1)
    difference=(affine-centered).abs()
    reference=torch.load(base/'hotspot-shared-geometry-math-reference-gate-n/original-final.pt',map_location='cpu',weights_only=True,mmap=True)
    native=json.loads((base/'hotspot-shared-geometry-math-native-gate-l/final.json').read_text())
    mean_a=torch.tensor(native['metadata']['normalizers'][4]['mean'],dtype=torch.float64)
    mean_b=torch.tensor(reference['normalizers'][4]['mean'],dtype=torch.float64)
    norm_diff=[dict(index=i,native=float(mean_a[i]),control=float(mean_b[i]),delta=float(mean_a[i]-mean_b[i])) for i in range(len(mean_a)) if mean_a[i]!=mean_b[i]]
    midpoint=torch.full((1,1),.75,device='cuda')
    result=dict(diagnostic_only=True,xi_columns=[dict(column=i,unequal=int((affine[:,i]!=centered[:,i]).sum()),max_abs=float(difference[:,i].max())) for i in range(33) if torch.any(difference[:,i])],
                critic_mean_differences=norm_diff,critic_xi_start=151,midpoint_affine=float((midpoint*(1/.45)+(-.75/.45))[0,0]),midpoint_centered=float(((midpoint-.75)/.45)[0,0]))
    (out/'result.json').write_text(json.dumps(result,indent=2))
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3


if __name__=='__main__':main()
