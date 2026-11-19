"""Causal control: share only the fixed reward executable across runtimes.

This is not an independent reward accuracy oracle. The mathematical and VJP
gates remain separate. It isolates compilation/reduction choices from training
wiring without importing native gradients, targets, or optimizer outputs.
"""
from contextlib import contextmanager
import json
from pathlib import Path
import torch


@contextmanager
def fixed_reward_control(probe_type, directory):
    root=Path(directory)
    meta=json.loads((root/'manifest.json').read_text())
    fw=torch._C._aoti.AOTIModelContainerRunnerCuda(str(root/'forward.so'),1,'cuda:0',str(root))
    bw=torch._C._aoti.AOTIModelContainerRunnerCuda(str(root/'backward.so'),1,'cuda:0',str(root))
    def layout(values,kind):
        specs=meta['graphs'][kind]['inputs'];assert len(values)==len(specs)
        result=[]
        for t,s in zip(values,specs):
            assert list(t.shape)==s['shape'] and str(t.dtype)==s['dtype']
            if list(t.stride())!=s['stride']:
                fixed=torch.empty_strided(s['shape'],s['stride'],device=t.device,dtype=t.dtype);fixed.copy_(t);t=fixed
            result.append(t)
        return result
    class Reward(torch.autograd.Function):
        @staticmethod
        def forward(ctx,*inputs):
            values=fw.run(layout(inputs,'forward'))
            ctx.save_for_backward(*values[2:])
            return tuple(values[:2])
        @staticmethod
        def backward(ctx,*upstream):
            result=bw.run(layout([*ctx.saved_tensors,*upstream],'backward'))
            gradients=[None]*20
            for i,g in zip(meta['gradient_indices'],result):gradients[i]=g
            return tuple(gradients)
    original=probe_type.prepare_actor
    def prepare(self):
        original(self);mdp=self.ctx['mdp'];kin=mdp.kin;m=mdp.motion
        def reward(S,f,a,previous):
            p,r,v,w,q,qd=S
            return Reward.apply(kin.off_p,r,p,kin.off_R,kin.axes,q,qd,w,v,m.root_p,f,m.root_R,m.body_p,m.body_R,m.body_v,m.body_w,a,previous,mdp.soft_hi,mdp.soft_lo)
        self.ctx['reward_term']=reward
    probe_type.prepare_actor=prepare
    try:yield
    finally:probe_type.prepare_actor=original
