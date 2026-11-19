"""Single-factor reward VJP control for source versus FP64-derived FK constants."""
import hashlib
import json
import os
from pathlib import Path
import numpy as np
import torch
from shared_smc_probe_bf16_original import SharedProbe
from compiled_world_detail_d import Pair
from compiler_reference_contract_f import reference_compilation
from torch._inductor.codecache import PyCodeCache
from frozen_training_kernels_ab import frozen_training_kernels


def stats(a,b):
    a,b=a.detach().cpu().double(),b.detach().cpu().double();d=(a-b).abs()
    return dict(unequal=int((a!=b).sum()),max_abs=float(d.max()),violations=int((d>2e-6+2e-4*b.abs()).sum()))


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT']);runs=Path('/workspace/moonrobo/runs')
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False);probe.prepare_actor()
    captured=torch.load(runs/'hotspot-shared-training-actor-tail-x/tail-capture.pt',map_location='cpu',weights_only=True,mmap=True)
    native=runs/'hotspot-shared-training-actor-joins-native-y'
    oldroot=runs/'hotspot-shared-actor-reference-inputs-b'
    oldrecords={r['name']:r['blob'] for r in json.loads((oldroot/'inputs.json').read_text())['records']}
    b=oldrecords['constant-1'];path=oldroot/b['file']
    with path.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==b['sha256']
    old_R=torch.from_numpy(np.array(np.memmap(path,mode='r',dtype='<f8'))).reshape(b['shape']).float().cuda()
    p,r,v,w,q,qd=[x.repeat(32,*([1]*(x.ndim-1))).cuda() for x in captured['state']]
    kin=probe.ctx['mdp'].kin;m=probe.ctx['motion'];mdp=probe.ctx['mdp']
    action=torch.zeros((32*4096,29),device='cuda')
    args=[kin.off_p,r,p,old_R,kin.axes,q,qd,w,v,m.root_p,torch.arange(4096,33*4096,device='cuda'),m.root_R,m.body_p,m.body_R,m.body_v,m.body_w,action,action.clone(),mdp.soft_hi,mdp.soft_lo]
    upstream=[torch.from_numpy(np.array(np.memmap(native/f'reward-upstream-{i}.f32',mode='r',dtype='<f4'))).cuda() for i in range(2)]
    pair=Pair(runs/'hotspot-mlp-actor-reward-reference-b/reward');rows={};grads={}
    names={2:'p',1:'r',8:'v',7:'w',5:'q',6:'qd'}
    reference_grad={i:captured[f'reward-{k}'] for k,i in enumerate((2,1,8,7,5,6))}
    for label,value in [('native_constant',old_R),('original_constant',kin.off_R)]:
        args[3]=value
        with torch.no_grad():
            outputs=pair.forward(args);actual=pair.backward(upstream)
            last={i:g[-4096:].cpu() for i,g in zip(pair.manifest['gradient_indices'],actual) if i in names}
        rows[label]={names[i]:stats(g,reference_grad[i]) for i,g in last.items()};grads[label]=last
        if label=='native_constant':
            controls={}
            for i,g in last.items():
                baseline=torch.from_numpy(np.array(np.memmap(native/f'reward-gradient-{i}.f32',mode='r',dtype='<f4',shape=tuple(g.shape))))
                controls[names[i]]=stats(g,baseline)
            rows['actual_native_reproduction']=controls
            assert all(r['unequal']==0 for r in controls.values()),'last-step replay must reproduce actual native VJP'
        del outputs,actual;pair.values=None
        torch.cuda.synchronize();assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    # Compare the exact original generated modules used for the AOT export,
    # including saved tensors. Real cotangents test joins that ones can hide.
    torch._inductor.config.compile_threads=1
    exported=runs/'hotspot-mlp-actor-reward-reference-b'
    modules={}
    source=runs/'hotspot-shared-original-actor-fx-b/compile-debug/torchinductor'
    for kind,folder in [('forward','model__2_forward_7.2'),('backward','model__2_backward_9.3')]:
        code=source/folder/'output_code.py'
        with reference_compilation(exported/'empty-padding-cache.json',code,exported/(kind+'-choices.json'),out/(kind+'-decisions.json')):
            modules[kind]=PyCodeCache.load(code.read_text())
    args[3]=kin.off_R
    with torch.no_grad():
        nf=pair.forward(args);of=modules['forward'].call(list(args))
        saved=[dict(index=i,**stats(a,b)) for i,(a,b) in enumerate(zip(pair.values,of))]
        nb=pair.backward(upstream);ob=modules['backward'].call(list(of[2:])+[g.clone() for g in upstream])
        rows['native_vs_original_exported_vjp']={names[i]:stats(a[-4096:],ob[i][-4096:]) for i,a in zip(pair.manifest['gradient_indices'],nb) if i in names}
        rows['original_exported_vs_actual_smc_vjp']={names[i]:stats(ob[i][-4096:],reference_grad[i]) for i in names}
        rows['forward_and_saved_differences']=[r for r in saved if r['unequal']]
        rows['forward_and_saved_count']=len(saved)
    actual_root=runs/'hotspot-shared-training-smc-gate-t'
    dynamic={}
    for label,path in [('8','ga/cgai43xzzj5gkemn7ubz2gmpw4yieaxcwqfmgnlu6nbvglvwrodx.py'),('16','ab/cabt346cj24nmky76bhyzaa5ghefud6w56r7ic5xop4urs4cvj2a.py')]:
        code=(actual_root/'inductor-cache'/path).read_text()
        with frozen_training_kernels(actual_root,out/('dynamic-'+label+'-decisions.json')):
            module=PyCodeCache.load(code)
            name=next(k for k in vars(module) if k.startswith('triton_') and k.endswith('_'+label))
            dynamic[label]=(name,getattr(module,name))
    class Replay:
        def __init__(self,label,kernel):self.label,self.kernel=label,kernel
        def run(self,*args,**kwargs):
            if self.label=='8':
                # in_ptr6 is the joint-velocity matrix. ks0 is its row
                # stride, not the number of rows; derive it from that tensor.
                joint=args[13]
                assert tuple(joint.shape)==(131072,29) and joint.stride()==(29,1)
                assert args[-1]==3*joint.shape[0]
                return self.kernel.run(*args[:-1],joint.stride(0),args[-1],**kwargs)
            return self.kernel.run(*args,**kwargs)
    static_source=(exported/'inductor-cache/pq/cpq7ux3u6tzn22kmfmv2lakyvhjmxabq7dv2rmdp7av5xmybbh56.py').read_text()
    dynamic_source=(actual_root/'inductor-cache/ga/cgai43xzzj5gkemn7ubz2gmpw4yieaxcwqfmgnlu6nbvglvwrodx.py').read_text()
    address_lines=[line for line in dynamic_source.splitlines() if 'tl.load' in line and 'ks0' in line]
    assert len(address_lines)==11
    assert all(line.replace('ks0','29').replace('xmask','None') in static_source for line in address_lines),'dynamic pointer offsets must match the static kernel'
    old={name:getattr(modules['backward'],name) for name,_ in dynamic.values()}
    for label,changed in [('dynamic8',['8']),('dynamic16',['16']),('dynamic_both',['8','16'])]:
        for name,value in old.items():setattr(modules['backward'],name,value)
        for k in changed:
            name,kernel=dynamic[k];setattr(modules['backward'],name,Replay(k,kernel))
        with torch.no_grad():
            forward=modules['forward'].call(list(args))
            result=modules['backward'].call(list(forward[2:])+[g.clone() for g in upstream])
            rows[label]={names[i]:stats(result[i][-4096:],reference_grad[i]) for i in names}
        del forward,result
    for name,value in old.items():setattr(modules['backward'],name,value)
    bins={}
    for label,(name,kernel) in dynamic.items():
        assert len(kernel.compile_results)==1
        k=kernel.compile_results[0].kernel
        if hasattr(k,'asm'):
            binary=k.asm['cubin'];assert len(binary)<16*1024**2
            path=out/('original-dynamic-'+label+'.cubin');path.write_bytes(binary)
            bins[label]=dict(file=path.name,sha256=hashlib.sha256(binary).hexdigest(),name=k.name,config=str(kernel.launchers[0].config))
        else:bins[label]=dict(type=type(k).__name__,fields=sorted(vars(k)))
    (out/'original-kernels.json').write_text(json.dumps(bins,indent=2))
    tail=torch.load(runs/'hotspot-shared-training-actor-tail-x/tail-gradients.pt',map_location='cpu',weights_only=True,mmap=True)['original']
    joined=[]
    for k,i in enumerate((2,1,8,7,5,6)):
        a=grads['native_constant'][i]+tail[k]
        b=torch.from_numpy(np.array(np.memmap(native/f'aoti-adjoint-31-{k}.f32',mode='r',dtype='<f4',shape=tuple(a.shape))))
        joined.append(dict(name=names[i],**stats(a,b)))
    (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True,constant_difference=stats(old_R,kin.off_R),comparisons=rows,actual_native_join_reproduction=joined),indent=2))


if __name__=='__main__':main()
