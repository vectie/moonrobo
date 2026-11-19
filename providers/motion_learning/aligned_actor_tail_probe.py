"""Same-input eager tail VJP controls after the accepted ten world updates.

The training observer never replaces an output or derivative. Diagnostic
replicas run only after training and retain the original precision policy.
"""
import json
import os
from pathlib import Path

import numpy as np
import torch
import aligned_training_reference_s as reference
from frozen_training_kernels_ab import frozen_training_kernels
from supermimic.rotations import yaw_mat, mat_to_6d


def stats(a,b):
    a,b=a.detach().cpu().double(),b.detach().cpu().double()
    d=(a-b).abs()
    return dict(unequal=int((a!=b).sum()),max_abs=float(d.max()),violations=int((d>2e-6+2e-4*b.abs()).sum()))


def heading(r):
    x,y=r.reshape(-1,9)[:,0:1],r.reshape(-1,9)[:,3:4]
    n=(x*x+y*y)*1.0+1e-9
    n=n.sqrt();c,s=x/n,y/n;zero=c.detach()*0.0+0.0
    return torch.cat((c,s*-1.0+0.0,zero,s,c,zero,zero,zero,zero*0.0+1.0),1).reshape(-1,3,3)


def native_fk(kin,S):
    p,R,v,w,q,qd=S;P=[];Rs=[];V=[];W=[]
    for i in range(kin.num_bodies):
        par=kin.parent[i]
        if par<0:P.append(p);Rs.append(R);V.append(v);W.append(w);continue
        j=kin.joint_idx[i]
        pi=P[par]+(Rs[par]@kin.off_p[i].reshape(3,1)).reshape(-1,3)
        off=Rs[par]@kin.off_R[i].reshape(3,3)
        angle=q[:,j:j+1];c=angle.cos();s=angle.sin();k=c*-1.0+1.0
        x,y,z=(float(v) for v in kin.axes[i].tolist())
        affine=lambda t,a:t*a+0.0
        rot=torch.cat((affine(k,x*x)+c,affine(k,x*y)-affine(s,z),affine(k,x*z)+affine(s,y),
                       affine(k,y*x)+affine(s,z),affine(k,y*y)+c,affine(k,y*z)-affine(s,x),
                       affine(k,z*x)-affine(s,y),affine(k,z*y)+affine(s,x),affine(k,z*z)+c),1).reshape(-1,3,3)
        ri=off@rot;jw=(off@kin.axes[i].reshape(3,1)).reshape(-1,3)*qd[:,j:j+1]
        vi=V[par]+torch.cross(W[par],pi-P[par],dim=-1)
        P.append(pi);Rs.append(ri);V.append(vi);W.append(W[par]+jw)
    return torch.stack([P[i] for i in kin.tracked_idx],1)


def native_features(probe,S,f,xi,*,original_fk=False,original_heading=False,original_order=False):
    mdp=probe.ctx['mdp'];m=probe.ctx['motion'];p,R,v,w,q,qd=S;n=p.shape[0]
    head=yaw_mat if original_heading else heading
    ht=head(R).transpose(1,2)
    bp=mdp.kin.forward(*S)[0] if original_fk else native_fk(mdp.kin,S)
    rp,rR=m.root_p[f],m.root_R[f]
    dr=head(R@rR.transpose(1,2))
    anchor=torch.cat((p[:,:2],rp[:,2:3]),1)
    target=anchor.reshape(n,1,3)+(dr.reshape(n,1,3,3)@(m.body_p[f]-rp.reshape(n,1,3)).reshape(n,-1,3,1)).reshape(n,-1,3)
    body=(ht.reshape(n,1,3,3)@(target-bp).reshape(n,-1,3,1)).reshape(n,-1)
    root=(ht@(rp-p).reshape(n,3,1)).reshape(n,3)
    rel=mat_to_6d(R.transpose(1,2)@rR)
    ih=head(R);rt=R.transpose(1,2)
    inv=torch.cat((p[:,2:3],mat_to_6d(ih.transpose(1,2)@R),(rt@v.reshape(n,3,1)).reshape(n,3),
                   (rt@w.reshape(n,3,1)).reshape(n,3),q,qd),1)
    return torch.cat((inv,m.q[f]-q,body,root,rel,xi),1)


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT']);original_class=reference.SharedProbe;instances=[]
    reference.frozen_original_compilation=lambda code,choices,receipt:frozen_training_kernels('/workspace/moonrobo/runs/hotspot-shared-training-smc-gate-t',receipt)
    captures={};handles=[]
    class Probe(original_class):
        def prepare_actor(self):
            super().prepare_actor();instances.append(self)
            original=self.ctx['_critic_input'];reward=self.ctx['reward_term']
            def critic_input(S,f,xi,g):
                value=original(S,f,xi,g)
                assert 'state' not in captures
                captures.update(state=[v.detach().cpu() for v in S],frame=f.detach().cpu(),xi=xi.detach().cpu(),goal=g.detach().cpu(),features=value.detach().cpu())
                handles.append(value.register_hook(lambda grad:captures.update(upstream=grad.detach().cpu())))
                return value
            def reward_term(S,*args):
                value=reward(S,*args)
                for i,x in enumerate(value):
                    captures[f'reward-value-{i}']=x.detach().cpu()
                    handles.append(x.register_hook(lambda grad,i=i:captures.update({f'reward-upstream-{i}':grad.detach().cpu()})))
                for i,x in enumerate(S):
                    handles.append(x.register_hook(lambda grad,i=i:captures.update({f'reward-{i}':grad[-4096:].detach().cpu()})))
                return value
            self.ctx['_critic_input']=critic_input;self.ctx['reward_term']=reward_term
            def critic_hook(module,args,value):
                if torch.is_grad_enabled() and args[0].shape[0]==4096:
                    assert 'tail-value' not in captures
                    captures['tail-value']=value.detach().cpu()
                    handles.append(value.register_hook(lambda grad:captures.update({'tail-upstream':grad.detach().cpu()})))
            handles.append(self.critic.register_forward_hook(critic_hook))
    reference.SharedProbe=Probe
    try:reference.main()
    except AssertionError as error:assert str(error)=='complete coupled training update numerical gate failed'
    finally:reference.SharedProbe=original_class
    for h in handles:h.remove()
    assert len(instances)==1 and len(captures)==18
    probe=instances[0]
    old=torch.load('/workspace/moonrobo/runs/hotspot-shared/training-smc-gate-t/original-final.pt'.replace('hotspot-shared/','hotspot-shared-'),map_location='cpu',weights_only=True,mmap=True)
    new=torch.load(root/'original-final.pt',map_location='cpu',weights_only=True,mmap=True)
    assert all(torch.equal(v,new['tensors'][k]) for k,v in old['tensors'].items()),'observer changes final update'
    torch.save(captures,root/'tail-capture.pt')
    upstream_controls={}
    for i in range(2):
        a=torch.from_numpy(np.array(np.memmap(f'/workspace/moonrobo/runs/hotspot-shared-training-actor-joins-native-y/reward-upstream-{i}.f32',mode='r',dtype='<f4')))
        upstream_controls[str(i)]=stats(a,captures[f'reward-upstream-{i}'])
    (root/'upstream-controls.json').write_text(json.dumps(upstream_controls,indent=2))
    f,xi,g=(captures[k].cuda() for k in ('frame','xi','goal'))
    upstream=captures['upstream'].cuda();names=('p','r','v','w','q','qd');rows={};grads={}
    for label,flags in [('original',None),('native',{}),('native_original_fk',dict(original_fk=True)),('native_original_heading',dict(original_heading=True)),('native_original_both',dict(original_fk=True,original_heading=True))]:
        state=tuple(v.cuda().requires_grad_() for v in captures['state'])
        value=probe.ctx['mdp'].critic_features(state,f,xi) if flags is None else native_features(probe,state,f,xi,**flags)
        value=torch.cat((value,g),-1)
        gradients=torch.autograd.grad(value,state,upstream)
        grads[label]=[v.detach().cpu() for v in gradients]
        rows[label]=dict(forward=stats(value,captures['features']))
        if label!='original':rows[label]['vjp']={k:stats(v,w) for k,v,w in zip(names,grads[label],grads['original'])}
        del gradients,state,value
    observed=torch.load('/workspace/moonrobo/runs/hotspot-shared-training-actor-joins-smc-u/original-adjoints.pt',map_location='cpu',weights_only=True,mmap=True)
    for label in ('original','native'):
        joined=[]
        for i,(name,v) in enumerate(zip(names,grads[label])):
            expected=observed['steps'][31]['upstream'][i] if label=='original' else torch.from_numpy(np.array(np.memmap(f'/workspace/moonrobo/runs/hotspot-shared-training-actor-joins-native-u/aoti-adjoint-31-{i}.f32',mode='r',dtype='<f4',shape=tuple(v.shape))))
            joined.append(dict(name=name,**stats(v+captures[f'reward-{i}'],expected)))
        rows[label]['actual_join_reproduction']=joined
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    torch.save(grads,root/'tail-gradients.pt')
    (root/'tail-controls.json').write_text(json.dumps(dict(observer_unchanged=True,controls=rows),indent=2))


if __name__=='__main__':main()
