"""First-update causal audit of corrected BF16 rollout and loss boundaries."""
import json,os
from pathlib import Path
import torch
import supermimic.rotations as rotations
from shared_smc_probe_bf16_original import SharedProbe,networks,mdp_module
from geometry_math_revision import corrected_smc_geometry


class Pair:
    def __init__(self,folder):
        self.meta=json.loads((folder/'manifest.json').read_text());self.count=self.meta['output_count']
        self.fw=torch._C._aoti.AOTIModelContainerRunnerCuda(str(folder/'forward.so'),1,'cuda:0',str(folder))
        self.bw=torch._C._aoti.AOTIModelContainerRunnerCuda(str(folder/'backward.so'),1,'cuda:0',str(folder))
    def forward(self,args):
        with torch.no_grad():return self.fw.run(list(args))
    def backward(self,forward,upstream):
        saved=list(forward[self.count:])+list(upstream)
        for i,s in enumerate(self.meta['graphs']['backward']['inputs']):
            if list(saved[i].stride())!=s['stride']:
                x=torch.empty_strided(s['shape'],s['stride'],device='cuda',dtype=saved[i].dtype);x.copy_(saved[i]);saved[i]=x
        with torch.no_grad():return self.bw.run(saved)


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT']);rows=[]
    torch._inductor.config.trace.enabled=True
    torch._inductor.config.trace.debug_dir=str(out/'compile-debug')
    torch._inductor.config.fx_graph_cache=False
    def compare(name,a,b):
        a,b=a.detach().double(),b.detach().double();d=a-b
        rows.append(dict(name=name,max_abs=float(d.abs().max()),violations=int((d.abs()>2e-6+2e-4*b.abs()).sum()),
                         relative_l2=float(d.norm()/b.norm().clamp_min(1e-30)),unequal=int((a!=b).sum())))
    root=Path('/workspace/moonrobo/runs/hotspot-geometry-math-ieee-packages-a')
    with corrected_smc_geometry(networks,mdp_module,rotations):
        probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=True)
        torch.backends.cuda.matmul.allow_tf32=False
        roll,err=Pair(root/'rollout'),Pair(root/'error')
        wm=probe.wm;batch=probe.world
        args=[batch['s'],batch['actions'],batch['xi'],*wm.parameters(),wm.in_norm.mean,wm.in_norm.var,wm.out_norm.mean,wm.out_norm.var]
        native=roll.forward(args)
        control=probe.rollout(batch['s'],batch['actions'],batch['xi'])
        for name,a,b in zip(('p','r','v','w','q','qd'),native[:6],control):compare('rollout-'+name,a,b)
        # Same six native output tensors: isolate the error boundary from rollout.
        state=tuple(x.detach().requires_grad_() for x in native[:6])
        native_error=err.forward([*state,batch['s1'],batch['mask'],wm.out_norm.var,probe.ctx['ERR_FLOOR']])
        loss,last=probe.err(state,batch['s1'],batch['mask'])
        mask=batch['mask'][:,-1];metric=(last.detach()*mask).sum()/mask.sum().clamp_min(1)
        compare('same-state-loss-and-metric',native_error[0],torch.stack((loss,metric)))
        control_upstream=torch.autograd.grad(loss,state)
        native_upstream=err.backward(native_error,[torch.tensor([1.,0.],device='cuda')])
        for i,a,b in zip(err.meta['gradient_indices'],native_upstream,control_upstream):compare('error-vjp-'+str(i),a,b)
        # Same cotangents: isolate eight-step propagation and parameter joins.
        native_grads=roll.backward(native,control_upstream)
        control_grads=torch.autograd.grad(control,list(wm.parameters()),control_upstream)
        for i,a,b in zip(roll.meta['gradient_indices'],native_grads,control_grads):compare('same-upstream-parameter-vjp-'+str(i),a,b)
        torch.cuda.synchronize()
        memory=dict(allocated_peak=torch.cuda.max_memory_allocated(),reserved_peak=torch.cuda.max_memory_reserved(),free=torch.cuda.mem_get_info()[0])
        assert memory['free']>16*1024**3 and memory['reserved_peak']<32*1024**3
        from torch._inductor.codecache import PyCodeCache
        import hashlib
        launched=[]
        for module in PyCodeCache.modules:
            for name,kernel in vars(module).items():
                if getattr(kernel,'launchers',None):launched.append(dict(module_sha256=hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest(),kernel=name,configs=[str(x.config) for x in kernel.launchers]))
        (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,comparisons=rows,memory=memory,launched=launched,original_smc_unchanged=True),indent=2))


if __name__=='__main__':main()
