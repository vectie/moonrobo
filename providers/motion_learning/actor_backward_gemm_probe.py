"""Same-process original SMC backward replay, observing external GEMMs only.

No numerical settings or gradients are replaced. CPU snapshots are bounded;
this diagnostic cannot be used for performance measurements.
"""
import hashlib
import inspect
import json
import os
from pathlib import Path

import torch
from shared_smc_probe_bf16_original import SharedProbe


def stats(a, b):
    assert a.shape == b.shape and a.dtype == b.dtype
    a, b = a.detach().float().cpu(), b.float()
    d = (a-b).abs()
    return dict(unequal=int((a != b).sum()), max_abs=float(d.max()),
                violations=int((d > 2e-6+2e-4*b.abs()).sum()))


def layout(t):
    return dict(shape=list(t.shape), stride=list(t.stride()), dtype=str(t.dtype),
                offset=t.storage_offset(), alignment=t.data_ptr() % 4096)


def restore(cpu, spec):
    # Preserve both strides and storage offset, including original views.
    extent=spec['offset']+1+sum((n-1)*s for n,s in zip(spec['shape'],spec['stride']))
    storage=torch.empty(extent, device='cuda', dtype=cpu.dtype)
    return storage.as_strided(spec['shape'],spec['stride'],spec['offset']).copy_(cpu)


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=True)
    probe.prepare_actor()
    from torch._inductor.select_algorithm import extern_kernels
    from torch._inductor.codecache import PyCodeCache
    originals={n:getattr(extern_kernels,n) for n in ('mm','bmm','addmm')}
    active=False
    replay=False
    counter=0
    cursor=0
    used=0
    records=[]
    comparisons=[]
    tensors=[]
    saved=[]
    incoming=[]
    expected=[]
    module_path=None
    handles=[]

    def snapshot(t):
        nonlocal used
        used += t.numel()*t.element_size()
        assert used < 1536*1024**2, 'bounded diagnostic snapshot admission'
        return t.detach().cpu().clone()

    def external(name):
        def call(*args,**kwargs):
            nonlocal cursor,module_path
            result=originals[name](*args,**kwargs)
            if active:
                frame=inspect.currentframe().f_back
                while frame and '/inductor-cache/' not in frame.f_code.co_filename:
                    frame=frame.f_back
                assert frame is not None
                where=dict(file=Path(frame.f_code.co_filename).name,line=frame.f_lineno)
                module_path=frame.f_code.co_filename
                del frame
                value=kwargs.get('out',result)
                row=dict(op=name,where=where,inputs=[layout(a) for a in args if isinstance(a,torch.Tensor)],output=layout(value))
                if replay:
                    old=records[cursor]
                    assert old['op']==name and old['where']==where
                    comparisons.append(dict(index=cursor,**row,expected_layout=old,
                                            difference=stats(value,tensors[cursor])))
                    cursor+=1
                else:
                    records.append(row)
                    tensors.append(snapshot(value))
            return result
        return call

    original=probe.ctx['imag_step']
    def imag(*args):
        nonlocal counter
        value=original(*args)
        t=counter
        counter+=1
        if t==31:
            node=value[1].grad_fn
            outputs=(*value[0],value[1],value[2])
            specs={v.output_nr:(tuple(v.shape),v.dtype) for v in outputs}
            saved.extend((snapshot(v),layout(v)) for v in node.saved_tensors)
            def pre(gs):
                nonlocal active
                for i in sorted(specs):
                    v=gs[i]
                    if v is None:
                        shape,dtype=specs[i]
                        v=torch.zeros(shape,dtype=dtype,device='cuda')
                    incoming.append((snapshot(v),layout(v)))
                active=True
            def post(gs,unused):
                nonlocal active
                expected.extend(snapshot(v) if v is not None else None for v in gs)
                active=False
            handles.append(node.register_prehook(pre))
            handles.append(node.register_hook(post))
        return value

    for n in originals:setattr(extern_kernels,n,external(n))
    probe.ctx['imag_step']=imag
    try:
        metrics=[float(v.detach().cpu()) for v in probe.actor()]
        assert counter==32 and records and incoming and expected
        module=next(m for m in PyCodeCache.modules if m.__file__==module_path)
        path=Path(module_path)
        (root/path.name).write_bytes(path.read_bytes())
        choices={n:[str(l.config) for l in k.launchers] for n,k in vars(module).items()
                 if n.startswith('triton_') and hasattr(k,'launchers')}
        results=[]
        for trial in range(2):
            # Fresh buffers every replay: generated backward reuses activations.
            xs=[restore(v,s) for v,s in saved]
            assert all(v is not None for v in incoming)
            xs += [restore(v,s) for v,s in incoming]
            replay,active,cursor=True,True,0
            actual=module.call(xs)
            active=False
            assert cursor==len(records) and len(actual)==len(expected)
            rows=[dict(index=i,**stats(a,b)) for i,(a,b) in enumerate(zip(actual,expected)) if b is not None]
            results.append(dict(trial=trial,gradients=rows,gemms=list(comparisons)))
            comparisons.clear()
            del actual,xs
            (root/'progress.json').write_text(json.dumps(dict(diagnostic_only=True,metrics=metrics,
                original_module_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                kernels=choices,snapshot_bytes=used,trials=results),indent=2))
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
        (root/'result.json').write_bytes((root/'progress.json').read_bytes())
    finally:
        probe.ctx['imag_step']=original
        for n,f in originals.items():setattr(extern_kernels,n,f)
        for h in handles:h.remove()


if __name__=='__main__':main()
