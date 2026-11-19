"""Original SMC complete training-compute cycle; immutable-input paired harness.

Ten world updates precede one full4096 actor / twenty critic updates. Physics,
sampling, upload and checkpoint restore are outside this numerical/timing scope.
"""
import ast
import hashlib
import json
import os
import time
from pathlib import Path

import torch
from frozen_training_kernels import frozen_training_kernels
from shared_smc_probe_bf16_original import SharedProbe, Meter


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def cache_artifacts(root):
    return {str(p.relative_to(root)):digest(p) for name in ('inductor-cache','triton-cache')
            for p in (root/name).rglob('*') if p.is_file() and
            (p.suffix in ('.py','.so','.cubin','.ptx','.json','.c','.cpp') or '.best_config' in p.name)}


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    runs=Path('/workspace/moonrobo/runs')
    base=Path('/workspace/moonrobo/private/shared-compute-20261026-a')
    actor=runs/'hotspot-shared-actor-frozen-reference-h'
    code=(actor/'frozen-kernels.py').read_text()
    choices=json.loads((actor/'frozen-choices.json').read_text())['smc_loaded_kernels']
    world_code=base/'world_smc_backward_a.py'
    world_choices=json.loads((runs/'hotspot-mlp-world-boundary-f/result.json').read_text())['smc_loaded_kernels']
    for i,node in enumerate(ast.walk(ast.parse(world_code.read_text()))):
        if not isinstance(node,ast.Call) or ast.unparse(node.func)!='async_compile.triton':continue
        name,source=map(ast.literal_eval,node.args[:2])
        if name not in world_choices or not world_choices[name]['configs']:continue
        key=f'world_reference_{i}'
        code+=f'\n{key}=async_compile.triton({key!r},{source!r})\n'
        choices[key]=world_choices[name]
    code_file=root/'frozen-kernels.py';code_file.write_text(code)
    choice_file=root/'frozen-choices.json';choice_file.write_text(json.dumps(dict(smc_loaded_kernels=choices)))
    torch._inductor.config.compile_threads=1
    torch._inductor.config.fx_graph_cache=True
    torch._functorch.config.enable_autograd_cache=False
    repeats=int(os.environ['MOONROBO_SHARED_REPETITIONS']);assert repeats in (1,13)
    assert os.environ['MOONROBO_SHARED_MODE']=='train' and os.environ['MOONROBO_SHARED_OBSERVER']=='off'
    probe=SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=True)
    probe.prepare_actor()
    # The existing phase-only fixture replaces args in prepare_actor. Original
    # train.py has both fields in the same argparse namespace for coupled use.
    probe.ctx['args'].wm_window=8
    meter=Meter('off');rows=[];steady_artifacts=None
    with frozen_training_kernels(runs/'hotspot-shared-training-smc-gate-t',root/'frozen-decisions.json'):
        # Establish the previously accepted single world update before coupling
        # phases. This diagnostic is outside the measured interval.
        probe.reset()
        first_world=probe.world_update(meter)
        first_comparison=probe.compare(str(runs/'hotspot-shared-world-reference-native-gate-f'),first_world)
        (root/'first-world-comparison.json').write_text(json.dumps(first_comparison,indent=2))
        assert first_comparison['passed'],'first world update differs from accepted reference'
        for iteration in range(repeats):
            probe.reset();torch.cuda.synchronize()
            if iteration==3:steady_artifacts=cache_artifacts(root)
            begin=time.perf_counter_ns()
            for _ in range(10):world=probe.world_update(meter)
            metrics=[*world,*probe.actor_update(meter)]
            submitted=time.perf_counter_ns();torch.cuda.synchronize();end=time.perf_counter_ns()
            rows.append(dict(iteration=iteration,steady=iteration>=3,
                host_call_ms=(submitted-begin)/1e6,drain_ms=(end-submitted)/1e6,
                wall_ms=(end-begin)/1e6,metrics=metrics))
            assert torch.cuda.mem_get_info()[0]>16*1024**3
            assert torch.cuda.max_memory_reserved()<32*1024**3
            print('TRAINING_ROW',iteration,rows[-1]['wall_ms'],flush=True)
    comparison=probe.compare(os.environ['ALIGNED_TRAINING_NATIVE'],metrics)
    # Retain the actual post-update reference for independent CPU comparison;
    # this export is outside every measured interval.
    snapshot={}
    for name,model,opt in zip(('world','policy','critic'),probe.models,probe.opts):
        for i,p in enumerate(model.parameters()):
            state=opt.state.get(p,{})
            for field,value in [('parameter',p),('gradient',p.grad),('moment1',state.get('exp_avg')),('moment2',state.get('exp_avg_sq'))]:
                if value is not None:snapshot[f'{name}-{i}-{field}']=value.detach().cpu().clone()
    norms=[dict(mean=n.mean.cpu().tolist(),variance=n.var.cpu().tolist(),count=float(n.count))
           for n in (probe.wm.in_norm,probe.wm.out_norm,probe.pi.obs_norm,probe.pi.goal_norm,probe.critic.norm)]
    frozen=torch.load(runs/'hotspot-shared-training-smc-gate-t/original-final.pt',map_location='cpu',weights_only=True,mmap=True)
    assert snapshot.keys()==frozen['tensors'].keys()
    assert all(torch.equal(value,frozen['tensors'][key]) for key,value in snapshot.items()),'original reference update changed'
    assert norms==frozen['normalizers'] and metrics==frozen['metrics'],'original reference statistics changed'
    decisions=json.loads((root/'frozen-decisions.json').read_text())
    assert not decisions['unknown'],'unfrozen original compilation decision'
    torch.save(dict(tensors=snapshot,normalizers=norms,metrics=metrics,
                    steps=[[int(opt.state[p]['step']) if p in opt.state else None for p in model.parameters()]
                           for model,opt in zip(probe.models,probe.opts)]),root/'original-final.pt')
    from torch._inductor.codecache import PyCodeCache
    launched=[]
    for module in PyCodeCache.modules:
        for name,kernel in vars(module).items():
            if not hasattr(kernel,'launchers') or not kernel.launchers:continue
            launched.append(dict(module_sha256=digest(Path(module.__file__)),kernel=name,
                configs=[str(l.config) for l in kernel.launchers]))
    assert len(launched)>=300
    if steady_artifacts is not None:
        assert cache_artifacts(root)==steady_artifacts,'compiled artifacts changed during steady updates'
    (root/'result.json').write_text(json.dumps(dict(schema='moonrobo.aligned-training-compute.v1',
        implementation='smc',phase='train',amp='bf16',actor_chunk=4096,rows=rows,
        numerical_comparison=comparison,passed=comparison['passed'],launched=launched,
        final_snapshot=dict(file='original-final.pt',sha256=digest(root/'original-final.pt')),
        original_reference_update_bitwise_unchanged=True,
        steady_artifact_count=len(steady_artifacts or {}),artifacts_fixed_during_steady=True,
        scope='10 complete world updates + one full4096 actor update + 20 critic updates; excludes physics, replay preparation, upload and checkpoint restore',
        memory=dict(torch_allocated_peak_bytes=torch.cuda.max_memory_allocated(),torch_reserved_peak_bytes=torch.cuda.max_memory_reserved())),indent=2))
    assert comparison['passed'],'complete coupled training update numerical gate failed'


if __name__=='__main__':main()
