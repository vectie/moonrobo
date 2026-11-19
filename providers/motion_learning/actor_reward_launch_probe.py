"""Same saved tensors/cotangents; single original-SMC launch-choice controls."""
import ast
import hashlib
import json
import os
from pathlib import Path

import torch
from torch._inductor.codecache import PyCodeCache
from compiler_reference_contract_f import reference_compilation
from frozen_training_kernels_ab import contract, sources


def stats(a, b):
    assert a.shape == b.shape
    a, b = a.detach().cpu().double(), b.detach().cpu().double()
    difference = (a-b).abs()
    return dict(unequal=int((a!=b).sum()), max_abs=float(difference.max()))


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT']); runs=Path('/workspace/moonrobo/runs')
    capture=torch.load(runs/'hotspot-shared-actor-reward-saved-ad/actual-reward.pt',map_location='cpu',weights_only=True,mmap=True)
    exported=runs/'hotspot-mlp-actor-reward-reference-b'
    source=runs/'hotspot-shared-original-actor-fx-b/compile-debug/torchinductor/model__2_backward_9.3/output_code.py'
    original_choices=json.loads((exported/'backward-choices.json').read_text())
    current=json.loads((runs/'hotspot-shared-training-smc-gate-t/result.json').read_text())
    choices={};reference_root=runs/'hotspot-shared-training-smc-gate-t'
    original_contracts={name:contract(code) for name,code in sources(source)}
    paths={hashlib.sha256(p.read_bytes()).hexdigest():p for p in (reference_root/'inductor-cache').rglob('*.py')}
    parsed={}
    for row in current['launched']:
        name=row['kernel']
        if name not in original_choices['smc_loaded_kernels']:continue
        digest=row['module_sha256']
        if digest not in parsed:parsed[digest]=dict(sources(paths[digest]))
        if contract(parsed[digest][name])!=original_contracts[name]:continue
        assert name not in choices or choices[name]==row['configs'],name
        choices[name]=row['configs']
    changed={k:v for k,v in choices.items() if v!=original_choices['smc_loaded_kernels'][k]['configs']}
    assert changed
    torch._inductor.config.compile_threads=1
    with reference_compilation(exported/'empty-padding-cache.json',source,exported/'backward-choices.json',root/'baseline-decisions.json'):
        module=PyCodeCache.load(source.read_text())
    index={1:1,2:0,5:4,6:5,7:3,8:2}
    def evaluate():
        # Preserve the actual saved layouts; the generated function mutates
        # temporary storage, so every control receives fresh tensors.
        saved=[]
        for value,layout in zip(capture['saved'],capture['saved_layouts']):
            target=torch.empty_strided(value.shape,layout,device='cuda',dtype=value.dtype)
            target.copy_(value);saved.append(target)
        saved.extend(capture[f'upstream-{i}'].cuda().clone() for i in range(2))
        with torch.no_grad():result=module.call(saved)
        report={str(i):stats(result[i],capture[f'gradient-{j}']) for i,j in index.items()}
        del saved,result
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
        return report
    rows={'baseline':evaluate()};alternatives={}
    for name,config in changed.items():
        tree=ast.parse(source.read_text());found=0
        for node in ast.walk(tree):
            if not isinstance(node,ast.Call) or ast.unparse(node.func)!='async_compile.triton':continue
            if ast.literal_eval(node.args[0])!=name:continue
            node.args[1]=ast.Constant(ast.literal_eval(node.args[1])+'\n# single-original-choice '+name+'\n');found+=1
        assert found==1
        code=root/(name+'.py');code.write_text(ast.unparse(tree)+'\n')
        selected=json.loads(json.dumps(original_choices));selected['smc_loaded_kernels'][name]['configs']=config
        record=root/(name+'.json');record.write_text(json.dumps(selected))
        with reference_compilation(exported/'empty-padding-cache.json',code,record,root/(name+'-decisions.json')):
            candidate=PyCodeCache.load(code.read_text())
        previous=getattr(module,name);replacement=getattr(candidate,name);alternatives[name]=replacement
        setattr(module,name,replacement)
        try:rows[name]=dict(config=config,comparison=evaluate())
        finally:setattr(module,name,previous)
        assert len(replacement.launchers)==1 and str(replacement.launchers[0].config)==config[0]
        print('CHOICE',name,json.dumps(rows[name]),flush=True)
    for name,kernel in alternatives.items():setattr(module,name,kernel)
    rows['all_original_choices']=evaluate()
    (root/'result.json').write_text(json.dumps(dict(diagnostic_only=True,controls=rows,original_source_changed=False,
        matched_contracts=len(choices),changed_contracts=changed),indent=2))


if __name__=='__main__':main()
