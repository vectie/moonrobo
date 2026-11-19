"""Capture actual original reward saved tensors, then compare the native boundary."""
import json
import os
from pathlib import Path
import torch
import aligned_training_reference_s as reference
from frozen_training_kernels_ab import frozen_training_kernels
from compiled_world_detail_d import Pair


def stats(a,b):
    assert a.shape==b.shape and a.dtype==b.dtype
    a,b=a.detach().cpu().double(),b.detach().cpu().double();d=(a-b).abs()
    return dict(unequal=int((a!=b).sum()),max_abs=float(d.max()),violations=int((d>2e-6+2e-4*b.abs()).sum()))


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT']);runs=Path('/workspace/moonrobo/runs')
    original_class=reference.SharedProbe;instances=[];data={};handles=[]
    reference.frozen_original_compilation=lambda code,choices,receipt:frozen_training_kernels(runs/'hotspot-shared-training-smc-gate-t',receipt)
    class Probe(original_class):
        def prepare_actor(self):
            super().prepare_actor();instances.append(self);original=self.ctx['reward_term']
            def reward(S,f,a,prev):
                result=original(S,f,a,prev);node=result[0].grad_fn
                assert result[1].grad_fn is node and not data
                tensors=[*S,f,a,prev,*result,*node.saved_tensors]
                assert sum(x.numel()*x.element_size() for x in tensors)<2*1024**3
                data.update(state=[x.detach().cpu() for x in S],frame=f.detach().cpu(),action=a.detach().cpu(),previous=prev.detach().cpu(),
                            outputs=[x.detach().cpu() for x in result],saved=[x.detach().cpu() for x in node.saved_tensors],
                            saved_layouts=[list(x.stride()) for x in node.saved_tensors])
                for i,x in enumerate(S):handles.append(x.register_hook(lambda g,i=i:data.update({f'gradient-{i}':g.detach().cpu()})))
                for i,x in enumerate(result):handles.append(x.register_hook(lambda g,i=i:data.update({f'upstream-{i}':g.detach().cpu()})))
                return result
            self.ctx['reward_term']=reward
    reference.SharedProbe=Probe
    try:reference.main()
    except AssertionError as error:assert str(error)=='complete coupled training update numerical gate failed'
    finally:reference.SharedProbe=original_class
    for h in handles:h.remove()
    original=torch.load(runs/'hotspot-shared-training-smc-gate-t/original-final.pt',map_location='cpu',weights_only=True,mmap=True)
    actual=torch.load(root/'original-final.pt',map_location='cpu',weights_only=True,mmap=True)
    assert all(torch.equal(v,actual['tensors'][k]) for k,v in original['tensors'].items()),'observer changed original'
    torch.save(data,root/'actual-reward.pt')
    probe=instances[0];mdp=probe.ctx['mdp'];kin=mdp.kin;m=probe.ctx['motion']
    p,r,v,w,q,qd=[x.cuda() for x in data['state']]
    args=[kin.off_p,r,p,kin.off_R,kin.axes,q,qd,w,v,m.root_p,data['frame'].cuda(),m.root_R,m.body_p,m.body_R,m.body_v,m.body_w,data['action'].cuda(),data['previous'].cuda(),mdp.soft_hi,mdp.soft_lo]
    pair=Pair(runs/'hotspot-mlp-actor-reward-reference-b/reward')
    with torch.no_grad():
        outputs=pair.forward(args)
        result=dict(observer_unchanged=True,native_saved_count=len(pair.values)-2,original_saved_count=len(data['saved']),
                    outputs=[stats(a,b) for a,b in zip(outputs,data['outputs'])])
        if len(pair.values)-2==len(data['saved']):
            differences=[]
            for i,(a,b) in enumerate(zip(pair.values[2:],data['saved'])):
                if a.shape!=b.shape or a.dtype!=b.dtype:differences.append(dict(index=i,native=list(a.shape),original=list(b.shape)));continue
                row=stats(a,b)
                if row['unequal']:differences.append(dict(index=i,shape=list(a.shape),**row))
            result['saved_differences']=differences
        gradients=pair.backward([data[f'upstream-{i}'].cuda() for i in range(2)])
        lookup={2:0,1:1,8:2,7:3,5:4,6:5}
        result['gradient_comparisons']={str(i):stats(g,data[f'gradient-{lookup[i]}']) for i,g in zip(pair.manifest['gradient_indices'],gradients) if i in lookup}
    torch.cuda.synchronize();assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (root/'saved-controls.json').write_text(json.dumps(result,indent=2))


if __name__=='__main__':main()
