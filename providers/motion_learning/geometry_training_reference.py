"""Corrected-math Python control, separate from the untouched SMC benchmark.

Independent CPU SO(3) tests establish the mathematics. This control checks
complete update wiring, GAE, gradient flow and optimizer state across runtimes.
"""
import json
import os
import hashlib
from contextlib import ExitStack
from pathlib import Path
import torch
import supermimic.rotations as rotations
from shared_smc_probe_bf16_original import SharedProbe,Meter,networks,mdp_module
from geometry_math_revision import corrected_smc_geometry


def main():
    out=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    torch._inductor.config.compile_threads=1
    if os.environ.get('GEOMETRY_CAPTURE_CODE') == '1':
        torch._inductor.config.trace.enabled=True
        torch._inductor.config.trace.debug_dir=str(out/'compile-debug')
        torch._inductor.config.fx_graph_cache=False
    with ExitStack() as stack:
        stack.enter_context(corrected_smc_geometry(networks,mdp_module,rotations))
        if os.environ.get('GEOMETRY_SHARED_REWARD_CONTROL'):
            from geometry_shared_reward_control_a import fixed_reward_control
            stack.enter_context(fixed_reward_control(SharedProbe,os.environ['GEOMETRY_SHARED_REWARD_CONTROL']))
        if os.environ.get('GEOMETRY_FP64_ROBOT_CONSTANTS')=='1':
            from geometry_reference_constants_b import fp64_robot_constants
            stack.enter_context(fp64_robot_constants())
        if os.environ.get('GEOMETRY_FROZEN_ALL'):
            from frozen_training_kernels_am import frozen_training_kernels
            from geometry_reference_constants_b import captured_padding
            stack.enter_context(frozen_training_kernels(os.environ['GEOMETRY_FROZEN_ALL'],out/'all-kernel-decisions.json'))
            cache='/workspace/moonrobo/runs/hotspot-mlp-geometry-world-boundary-capture-a/inductor-cache/cache/f92a497d48fc1e801d19741fe9400d6fec3acb29f7fe6611804a20fa1dda1c24'
            stack.enter_context(captured_padding(cache,out/'world-padding-decisions.json'))
        elif os.environ.get('GEOMETRY_FROZEN_WORLD'):
            from compiler_reference_contract_f import reference_compilation
            root=Path(os.environ['GEOMETRY_FROZEN_WORLD'])
            code=Path('/workspace/moonrobo/runs/hotspot-mlp-geometry-world-boundary-capture-a/compile-debug/torchinductor/model__0_backward_7.3/output_code.py')
            cache=code.parents[3]/'inductor-cache/cache/f92a497d48fc1e801d19741fe9400d6fec3acb29f7fe6611804a20fa1dda1c24'
            stack.enter_context(reference_compilation(cache,code,root/'choices.json',out/'world-replay-decisions.json'))
        probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=True)
        torch.backends.cuda.matmul.allow_tf32=False
        probe.prepare_actor();probe.ctx['args'].wm_window=8
        probe.reset();meter=Meter('off')
        for _ in range(10):world=probe.world_update(meter)
        metrics=[*world,*probe.actor_update(meter)]
        torch.cuda.synchronize()
        memory_before_io=dict(free=torch.cuda.mem_get_info()[0],allocated=torch.cuda.memory_allocated(),reserved=torch.cuda.memory_reserved())
        launched=[]
        if os.environ.get('GEOMETRY_CAPTURE_CODE') == '1':
            from torch._inductor.codecache import PyCodeCache
            launched=[dict(module_sha256=hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest(),kernel=name,configs=[str(x.config) for x in kernel.launchers])
                for module in PyCodeCache.modules for name,kernel in vars(module).items() if getattr(kernel,'launchers',None)]
        (out/'compute-completed.json').write_text(json.dumps(dict(memory=memory_before_io,launched=launched,metrics=metrics,acceptance_not_implied=True),indent=2))
        assert memory_before_io['free']>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
        # Validation only: return unused allocator pages before CPU snapshots.
        # No compute/timing region includes this, and no live tensor is freed.
        torch.cuda.empty_cache()
        comparison=probe.compare(os.environ['ALIGNED_TRAINING_NATIVE'],metrics)
        snapshot={}
        for name,model,opt in zip(('world','policy','critic'),probe.models,probe.opts):
            for i,p in enumerate(model.parameters()):
                state=opt.state.get(p,{})
                for field,value in [('parameter',p),('gradient',p.grad),('moment1',state.get('exp_avg')),('moment2',state.get('exp_avg_sq'))]:
                    if value is not None:snapshot[f'{name}-{i}-{field}']=value.detach().cpu().clone()
        norms=[dict(mean=n.mean.cpu().tolist(),variance=n.var.cpu().tolist(),count=float(n.count)) for n in (probe.wm.in_norm,probe.wm.out_norm,probe.pi.obs_norm,probe.pi.goal_norm,probe.critic.norm)]
        torch.save(dict(tensors=snapshot,normalizers=norms,metrics=metrics),out/'original-final.pt')
        result=dict(schema='moonrobo.corrected-geometry-training-gate.v1',geometry_revision='orthonormal-atlas-geodesic-squared-v1',
            passed=comparison['passed'],comparison=comparison,metrics=metrics,original_smc_source_unchanged=True,
            peak_allocated=torch.cuda.max_memory_allocated(),peak_reserved=torch.cuda.max_memory_reserved(),memory_before_io=memory_before_io)
        result['shared_reward_artifact_control']=os.environ.get('GEOMETRY_SHARED_REWARD_CONTROL')
        result['independent_reward_accuracy_gate']=not bool(os.environ.get('GEOMETRY_SHARED_REWARD_CONTROL'))
        if os.environ.get('GEOMETRY_CAPTURE_CODE') == '1':
            result['launched']=launched
        (out/'result.json').write_text(json.dumps(result,indent=2))
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
        assert comparison['passed'],'corrected full update differs; no promotion'


if __name__=='__main__':main()
