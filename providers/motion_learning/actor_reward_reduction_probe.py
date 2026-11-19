"""Concrete-shape controls for original dynamic versus exported static sums."""
import ast
import json
import os
from pathlib import Path

import torch
from torch._inductor.codecache import PyCodeCache
from compiler_reference_contract_f import reference_compilation
from frozen_training_kernels_ab import frozen_training_kernels
from actor_reward_launch_af import stats


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT']);runs=Path('/workspace/moonrobo/runs')
    # Original train.py sets these before constructing the learner. The saved
    # graph also contains FP32 bmm, outside BF16 MLP autocast.
    torch.backends.cuda.matmul.allow_tf32=True
    torch.backends.cudnn.allow_tf32=True
    capture=torch.load(runs/'hotspot-shared-actor-reward-saved-ad/actual-reward.pt',map_location='cpu',weights_only=True,mmap=True)
    exported=runs/'hotspot-mlp-actor-reward-reference-b'
    source=runs/'hotspot-shared-original-actor-fx-b/compile-debug/torchinductor/model__2_backward_9.3/output_code.py'
    actual=runs/'hotspot-shared-training-smc-gate-t/inductor-cache/mq/cmq64x7qx66gqo33g572gbd2unisrz6w4xwoosllqro36z3nfs5h.py'
    torch._inductor.config.compile_threads=1
    with reference_compilation(exported/'empty-padding-cache.json',source,exported/'backward-choices.json',root/'baseline-decisions.json'):
        module=PyCodeCache.load(source.read_text())
    names=['triton_per_fused_div_expand_mul_neg_sum_unsqueeze_0','triton_per_fused_sum_view_19']
    old={name:getattr(module,name) for name in names};dynamic={}
    for name in names:
        call=next(n for n in ast.walk(ast.parse(actual.read_text())) if isinstance(n,ast.Call) and ast.unparse(n.func)=='async_compile.triton' and ast.literal_eval(n.args[0])==name)
        code='from torch._inductor.async_compile import AsyncCompile\nasync_compile=AsyncCompile()\n'+name+'='+ast.unparse(call)+'\nasync_compile.wait(globals())\n'
        with frozen_training_kernels(runs/'hotspot-shared-training-smc-gate-t',root/(name+'-decisions.json')):
            dynamic[name]=getattr(PyCodeCache.load(code),name)
    index={1:1,2:0,5:4,6:5,7:3,8:2}
    def evaluate():
        saved=[]
        for value,layout in zip(capture['saved'],capture['saved_layouts']):
            tensor=torch.empty_strided(value.shape,layout,device='cuda',dtype=value.dtype);tensor.copy_(value);saved.append(tensor)
        saved.extend(capture[f'upstream-{i}'].cuda().clone() for i in range(2))
        with torch.no_grad():result=module.call(saved)
        report={str(i):stats(result[i],capture[f'gradient-{j}']) for i,j in index.items()}
        del result,saved;torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.max_memory_reserved()<32*1024**3
        return report
    rows={}
    for label,selected in [('baseline',[]),('dynamic0',[names[0]]),('dynamic19',[names[1]]),('dynamic_both',names)]:
        for name in names:setattr(module,name,dynamic[name] if name in selected else old[name])
        rows[label]=evaluate();print('REDUCTION',label,json.dumps(rows[label]),flush=True)
        if label=='baseline':
            assert rows[label]['1']['unequal']==80714 and rows[label]['2']['unequal']==19230
            assert all(rows[label][str(i)]['unequal']==0 for i in (5,6,7,8)),'baseline must reproduce the actual native boundary'
    # Configuration-only control: retain the exact old static body.
    for name in names:setattr(module,name,old[name])
    choices=json.loads((exported/'backward-choices.json').read_text())
    config=str(dynamic[names[1]].launchers[0].config)
    choices['smc_loaded_kernels'][names[1]]['configs']=[config]
    choices_path=root/'static19-choices.json';choices_path.write_text(json.dumps(choices))
    tree=ast.parse(source.read_text())
    for node in ast.walk(tree):
        if isinstance(node,ast.Call) and ast.unparse(node.func)=='async_compile.triton' and ast.literal_eval(node.args[0])==names[1]:
            node.args[1]=ast.Constant(ast.literal_eval(node.args[1])+'\n# original actual reduction launch control\n')
    code_path=root/'static19-code.py';code_path.write_text(ast.unparse(tree))
    with reference_compilation(exported/'empty-padding-cache.json',code_path,choices_path,root/'static19-decisions.json'):
        candidate=PyCodeCache.load(code_path.read_text())
    setattr(module,names[1],getattr(candidate,names[1]));rows['static19_actual_config']=evaluate()
    (root/'result.json').write_text(json.dumps(dict(diagnostic_only=True,controls=rows,
        dynamic_configurations={name:[str(x.config) for x in kernel.launchers] for name,kernel in dynamic.items()}),indent=2))


if __name__=='__main__':main()
