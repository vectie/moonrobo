"""Isolate one original SMC backward reduction configuration (512 vs 1024).

Original code, saved tensors and cotangents are identical. This is numerical
diagnostic replay only; it does not alter original training or enable a candidate.
"""
import ast
import hashlib
import json
import os
from pathlib import Path

import torch
from compiler_reference_contract_d import reference_compilation
from torch._inductor.codecache import PyCodeCache


def compare(a,b):
    a,b=a.float().cpu(),b.float().cpu();d=(a-b).abs()
    return dict(unequal=int((a!=b).sum()),violations=int((d>2e-6+2e-4*b.abs()).sum()),max_abs=float(d.max()))


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    base=Path('/workspace/moonrobo/runs')
    src=base/'hotspot-shared-actor-adjoints-e'
    saved=torch.load(src/'original-adjoints.pt',map_location='cpu',weights_only=True,mmap=True)
    early=torch.load(base/'hotspot-shared-actor-adjoints-c/original-adjoints.pt',map_location='cpu',weights_only=True,mmap=True)
    assert all(torch.equal(a,b) for a,b in zip(saved['steps'][31]['upstream'],early['steps'][31]['upstream']))
    artifact=next(iter(saved['generated'].values()));code=src/artifact['copy']
    assert hashlib.sha256(code.read_bytes()).hexdigest()==artifact['sha256']
    loaded=json.loads((base/'hotspot-shared-actor-loaded-a/loaded-code.json').read_text())[code.name]
    key='triton_red_fused__to_copy_native_layer_norm_native_layer_norm_backward_silu_silu_backward_10'
    assert 'R0_BLOCK: 1024,' in loaded['smc_loaded_kernels'][key]['configs'][0]
    cache=root/'empty-cache.json';cache.write_text(json.dumps(dict(cache={})))
    original_fx=ast.parse((base/'hotspot-shared-original-actor-fx-b/compile-debug/torchinductor/model__1_backward_10.4/fx_graph_readable.py').read_text())
    native_fx=ast.parse((base/'hotspot-mlp-actor-step-export-b/recurrent/backward.fx.txt').read_text())
    original_return=next(n for n in ast.walk(original_fx) if isinstance(n,ast.Return)).value.elts
    native_return=next(n for n in ast.walk(native_fx) if isinstance(n,ast.Return)).value.elts
    aliases=[n.id for n in native_return if isinstance(n,ast.Name)]
    assert len(aliases)==27
    positions=[[ast.unparse(n) for n in original_return].index(name) for name in aliases[7:]]
    torch._inductor.config.compile_threads=1
    torch.backends.cuda.matmul.allow_tf32=True
    torch.backends.cudnn.allow_tf32=True
    results=[]
    for block in (1024,512,1024):
        choices=json.loads(json.dumps(loaded))
        choices['smc_loaded_kernels'][key]['configs'][0]=choices['smc_loaded_kernels'][key]['configs'][0].replace('R0_BLOCK: 1024,',f'R0_BLOCK: {block},')
        path=root/f'choices-{len(results)}.json';path.write_text(json.dumps(choices))
        module_ast=ast.parse(code.read_text())
        changed=0
        for node in ast.walk(module_ast):
            if isinstance(node,ast.Call) and ast.unparse(node.func)=='async_compile.triton' and ast.literal_eval(node.args[0])==key:
                # Use a fresh in-memory kernel-cache key for this control.
                # Only a comment changes; function AST/operations stay exact.
                node.args[1]=ast.Constant(ast.literal_eval(node.args[1])+f'\n# replay config {block}, trial {len(results)}\n')
                changed+=1
        assert changed==1
        with reference_compilation(cache,code,path,root/f'decisions-{len(results)}.json'):
            module=PyCodeCache.load(ast.unparse(module_ast))
        inputs=[]
        for cpu,stride in saved['selected_saved'][31]:
            inputs.append(torch.empty_strided(cpu.shape,stride,dtype=cpu.dtype,device='cuda').copy_(cpu))
        for cpu,stride in zip(saved['steps'][31]['upstream'],saved['upstream_layouts'][31]):
            inputs.append(cpu.cuda() if stride is None else torch.empty_strided(cpu.shape,stride,dtype=cpu.dtype,device='cuda').copy_(cpu))
        actual=module.call(inputs)
        config=[str(l.config) for l in getattr(module,key).launchers]
        assert len(config)==1 and f'R0_BLOCK: {block},' in config[0],config
        # Preserve original output order, including its None slots. The native
        # manifest orders seven state/history gradients before 20 parameters.
        rows=[dict(name=f'policy-{i}',**compare(actual[p],saved['steps'][31]['detail'][f'policy-{i}'])) for i,p in enumerate(positions)]
        early_rows=[dict(name=f'policy-{i}',**compare(actual[p],early['steps'][31]['detail'][f'policy-{i}'])) for i,p in enumerate(positions)]
        results.append(dict(block=block,selected_config=config,policy=rows,earlier_original=early_rows))
        (root/'progress.json').write_text(json.dumps(dict(diagnostic_only=True,original_code_sha256=artifact['sha256'],trials=results),indent=2))
        del actual,inputs,module
        torch.cuda.empty_cache()
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
    (root/'result.json').write_bytes((root/'progress.json').read_bytes())


if __name__=='__main__':main()
