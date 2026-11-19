"""Re-export unchanged corrected actor VJPs with actual saved-view layouts.

The older geometry exporter invented zero-offset example tensors. Real saved
views have offsets into 70-wide deltas, causing AOTI to clone them at each step.
Keep the accepted forward binaries, derivative graphs and launch choices; only
the compiler's input storage/alignment evidence changes. No math is rewritten.
"""
import hashlib
import json
import os
from contextlib import ExitStack
from pathlib import Path
import torch
from torch._subclasses.fake_tensor import FakeTensorMode
import supermimic.rotations as rotations
from compiler_reference_contract_f import reference_compilation
from actor_layout_graph_parser_a import graph_from_code
from compiled_world_detail_d import Pair
from shared_smc_probe_bf16_original import SharedProbe, networks, mdp_module, unflatten_state, normalize_xi
from geometry_math_revision import corrected_smc_geometry
from geometry_reference_constants_b import fp64_robot_constants


def main():
    out = Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    runs = Path('/workspace/moonrobo/runs')
    original = runs/'hotspot-mlp-geometry-world-actor-graphs-export-b'
    capture = runs/'hotspot-shared-geometry-math-reference-gate-i'
    source = capture/'compile-debug/torchinductor'
    launched = json.loads((capture/'result.json').read_text())['launched']
    assert torch.cuda.mem_get_info()[0] > 24*1024**3
    torch._inductor.config.compile_threads = 1
    cache = out/'padding.json'; cache.write_text('{"cache":{}}')
    with ExitStack() as stack:
        stack.enter_context(corrected_smc_geometry(networks,mdp_module,rotations))
        stack.enter_context(fp64_robot_constants())
        probe = SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=False)
        torch.backends.cuda.matmul.allow_tf32 = False
        probe.prepare_actor()
        for p in probe.wm.parameters(): p.requires_grad_(False)
        motion=probe.ctx['motion']
        live=[*probe.pi.parameters(),*probe.wm.parameters(),probe.pi.obs_norm.mean,probe.pi.obs_norm.var,
              probe.pi.goal_norm.mean,probe.pi.goal_norm.var,probe.wm.in_norm.mean,probe.wm.in_norm.var,
              probe.wm.out_norm.mean,probe.wm.out_norm.var,motion.root_R,probe.goals,probe.noise,probe.ctx['mdp'].default_q]
        args=[*unflatten_state(probe.state),probe.history,torch.arange(4096,device='cuda'),probe.xi,
              normalize_xi(probe.xi),probe.goals[:4096],*live]
        receipts=[]; preserved={}
        for kind,folder in [('initial','model__2_backward_18.9'),('recurrent','model__3_backward_17.8')]:
            target=out/kind;target.mkdir()
            for path in (original/kind).iterdir():
                if path.is_file() and (path.name=='forward.so' or path.suffix=='.cubin' or path.name in ('manifest.json','native.spec')):
                    (target/path.name).write_bytes(path.read_bytes())
                    preserved[str(target/path.name)]=hashlib.sha256(path.read_bytes()).hexdigest()
            manifest=json.loads((target/'manifest.json').read_text())
            pair=Pair(original/kind)
            for i,s in enumerate(manifest['graphs']['forward']['inputs']):
                assert list(args[i].shape)==s['shape'] and str(args[i].dtype)==s['dtype']
                if list(args[i].stride())!=s['stride']:
                    args[i]=torch.empty_strided(s['shape'],s['stride'],device='cuda',dtype=args[i].dtype).copy_(args[i])
            predictions=pair.forward(args)
            generator=torch.Generator(device='cuda').manual_seed(530)
            upstream=[torch.randn(v.shape,device='cuda',dtype=v.dtype,generator=generator) for v in predictions]
            concrete=pair.values[manifest['output_count']:]+upstream
            for i,(v,s) in enumerate(zip(concrete,manifest['graphs']['backward']['inputs'],strict=True)):
                assert list(v.shape)==s['shape'] and str(v.dtype)==s['dtype']
                if list(v.stride())!=s['stride']:
                    concrete[i]=torch.empty_strided(s['shape'],s['stride'],device='cuda',dtype=v.dtype).copy_(v)
            layouts=[dict(index=i,shape=list(v.shape),stride=list(v.stride()),storage_offset=v.storage_offset(),alignment_mod16=v.data_ptr()%16,dtype=str(v.dtype)) for i,v in enumerate(concrete)]
            (target/'saved-layouts.json').write_text(json.dumps(layouts,indent=2))
            gm=graph_from_code((original/kind/'backward.fx.txt').read_text())
            assert gm.code==(original/kind/'backward.fx.txt').read_text(), 'derivative graph changed'
            (target/'backward.fx.txt').write_text(gm.code)
            code=source/folder/'output_code.py';digest=hashlib.sha256(code.read_bytes()).hexdigest()
            choices=out/(kind+'-choices.json')
            records={r['kernel']:{'configs':r['configs']} for r in launched if r['module_sha256']==digest}
            assert records
            choices.write_text(json.dumps(dict(smc_loaded_kernels=records)))
            from torch._inductor.compile_fx import compile_fx_inner,get_cpp_wrapper_config
            from torch._inductor.virtualized import V
            options={**get_cpp_wrapper_config(),'cpp_wrapper':True,'compile_threads':1,'aot_inductor.output_path':str(target/'backward.so')}
            with reference_compilation(cache,code,choices,out/(kind+'-decisions.json')):
                with FakeTensorMode() as fake:
                    examples=[fake.from_tensor(v) for v in concrete]
                    with torch._inductor.config.patch(options),V.set_aot_compilation(True),torch._guards.compile_context(torch._guards.CompileContext(None)):
                        built=compile_fx_inner(gm,examples,cpp_wrapper=True,is_backward=True,is_inference=False)
                    assert Path(built.filename).name=='backward.so'
            old=pair.bw.run(concrete)
            runner=torch._C._aoti.AOTIModelContainerRunnerCuda(str(target/'backward.so'),1,'cuda:0',str(target))
            new=runner.run(concrete)
            checks=[dict(index=i,bitwise=bool(torch.equal(a,b)),max_abs=float((a-b).abs().max())) for i,(a,b) in enumerate(zip(old,new,strict=True))]
            assert all(r['bitwise'] for r in checks), 'layout-only VJP must be bitwise'
            wrappers=list(target.glob('*.wrapper.cpp')); assert len(wrappers)==1
            wrapper=wrappers[0].read_text()
            misaligned=[row['index'] for row in layouts if row['alignment_mod16']]
            assert misaligned
            assert all(f'Input {i} was compiled as 16-bytes aligned' not in wrapper for i in misaligned), 'false alignment check remains'
            receipts.append(dict(branch=kind,misaligned_inputs=misaligned,checks=checks,derivative_graph_unchanged=True))
            args[:6]=list(predictions[:6]);args[6]=predictions[7];args[7]=args[7]+4096;args[10]=probe.goals[4096:8192]
            pair.values=[]
            del concrete,examples,old,new,runner
        assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in preserved.items())
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
        (out/'result.json').write_text(json.dumps(dict(exported=True,bitwise_vjp_gate=True,full_update_gate_pending=True,branches=receipts,preserved=preserved,peak_reserved=torch.cuda.max_memory_reserved()),indent=2))


if __name__=='__main__':main()
