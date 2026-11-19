"""Observe the actual original compiled backward call, including its wrapper."""
import hashlib
import inspect
import json
import os
from pathlib import Path

import torch
import torch._dynamo
import torch._functorch._aot_autograd.runtime_wrappers as runtime
import aligned_training_reference_s as reference
from frozen_training_kernels_ab import frozen_training_kernels


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT']);runs=Path('/workspace/moonrobo/runs')
    original_probe=reference.SharedProbe;original_call=runtime.call_func_at_runtime_with_args
    target=[];data={};handles=[];callables=[]
    reference.frozen_original_compilation=lambda code,choices,receipt:frozen_training_kernels(runs/'hotspot-shared-training-smc-gate-t',receipt)
    def capture(values):
        assert sum(x.numel()*x.element_size() for x in values if isinstance(x,torch.Tensor))<2*1024**3
        return [x.detach().cpu() if isinstance(x,torch.Tensor) else x for x in values]
    def observed(function,args,*positional,**keywords):
        if target and function is target[0].compiled_bw and 'inputs' not in data:
            data['inputs']=capture(args)
            data['layouts']=[list(x.stride()) if isinstance(x,torch.Tensor) else None for x in args]
            callables.append(function)
            output=original_call(function,args,*positional,**keywords)
            data['outputs']=capture(output)
            return output
        return original_call(function,args,*positional,**keywords)
    class Probe(original_probe):
        def prepare_actor(self):
            super().prepare_actor();original=self.ctx['reward_term']
            def reward(*args):
                result=original(*args);node=result[0].grad_fn
                assert not target
                target.append(node._forward_cls)
                handles.append(node.register_hook(lambda gi,go:data.update(node_outputs=capture(gi))))
                return result
            self.ctx['reward_term']=reward
    runtime.call_func_at_runtime_with_args=observed;reference.SharedProbe=Probe
    try:reference.main()
    except AssertionError as error:assert str(error)=='complete coupled training update numerical gate failed'
    finally:
        runtime.call_func_at_runtime_with_args=original_call;reference.SharedProbe=original_probe
        for h in handles:h.remove()
    expected=torch.load(runs/'hotspot-shared-training-smc-gate-t/original-final.pt',map_location='cpu',weights_only=True,mmap=True)
    actual=torch.load(root/'original-final.pt',map_location='cpu',weights_only=True,mmap=True)
    assert all(torch.equal(v,actual['tensors'][k]) for k,v in expected['tensors'].items())
    assert len(callables)==1
    torch.save(data,root/'actual-call.pt')
    report=[];seen=set();files={}
    def visit(value,path,depth):
        if depth>10 or id(value) in seen or len(seen)>100:return
        seen.add(id(value));row=dict(path=path,type=str(type(value)))
        if inspect.isfunction(value):
            row.update(name=value.__qualname__,file=value.__code__.co_filename)
            source=Path(value.__code__.co_filename)
            if source.is_file() and ('inductor-cache' in str(source) or 'torchinductor_' in str(source)):
                body=source.read_bytes();digest=hashlib.sha256(body).hexdigest()
                (root/(digest+'.py')).write_bytes(body);files[str(source)]=digest+'.py'
            report.append(row)
            for name,cell in zip(value.__code__.co_freevars,value.__closure__ or ()):
                content=cell.cell_contents
                if callable(content) and not isinstance(content,type):visit(content,path+'.'+name,depth+1)
        elif callable(value):
            attributes=vars(value) if hasattr(value,'__dict__') else {}
            row['fields']=list(attributes);report.append(row)
            for name,content in attributes.items():
                if callable(content) and not isinstance(content,type):visit(content,path+'.'+name,depth+1)
    visit(callables[0],'compiled_bw',0)
    describe=lambda x:dict(shape=list(x.shape),stride=list(x.stride()),dtype=str(x.dtype)) if isinstance(x,torch.Tensor) else x
    (root/'call-controls.json').write_text(json.dumps(dict(observer_unchanged=True,inputs=[describe(x) for x in data['inputs']],
        outputs=[describe(x) for x in data['outputs']],node_outputs=[describe(x) for x in data['node_outputs']],callables=report,files=files),indent=2))


if __name__=='__main__':main()
