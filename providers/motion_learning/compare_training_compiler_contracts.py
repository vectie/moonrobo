"""Read-only generated-kernel comparison; never compiles or executes a kernel."""
import ast
import difflib
import hashlib
import json
import sys
from pathlib import Path

from compiler_reference_contract_f import body_key


def kernels(path):
    for node in ast.walk(ast.parse(path.read_text())):
        if not isinstance(node,ast.Call) or ast.unparse(node.func)!='async_compile.triton':continue
        name,source=map(ast.literal_eval,node.args[:2])
        fn=next(n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef))
        dec=next(n for n in fn.decorator_list if isinstance(n,ast.Call))
        meta=next(k.value for k in dec.keywords if k.arg=='triton_meta')
        sig=next(v for k,v in zip(meta.keys,meta.values) if ast.literal_eval(k)=='signature')
        hints=next((ast.dump(k.value,include_attributes=False) for k in dec.keywords if k.arg=='size_hints'),None)
        yield dict(name=name,source=source,source_hash=hashlib.sha256(source.encode()).hexdigest(),
            body=body_key(source,ast.literal_eval(sig)),hints=hints,path=str(path))


def main(runs,base,output):
    runs,base=Path(runs),Path(base)
    reference=runs/'hotspot-shared-actor-frozen-reference-h'
    actual_run=runs/'hotspot-shared-training-smc-gate-t'
    expected_choices=json.loads((reference/'frozen-choices.json').read_text())['smc_loaded_kernels']
    actor=list(kernels(reference/'frozen-kernels.py'))
    expected={}
    for row in actor:
        expected.setdefault((row['body'],row['hints']),[]).append(dict(row,configs=expected_choices[row['name']]['configs']))
    launched=json.loads((actual_run/'result.json').read_text())['launched']
    modules={r['module_sha256'] for r in launched}
    actual={};module_paths={}
    for path in (actual_run/'inductor-cache').rglob('*.py'):
        digest=hashlib.sha256(path.read_bytes()).hexdigest()
        if digest in modules:
            module_paths[digest]=str(path)
            for row in kernels(path):actual[digest,row['name']]=row
    matched=[];unmatched=[];bundled=[]
    for launched_row in launched:
        row=actual.get((launched_row['module_sha256'],launched_row['kernel']))
        if row is None:
            path=module_paths[launched_row['module_sha256']]
            bundled.append(dict(launched_row,path=path,source_prefix=Path(path).read_text()[:1800]));continue
        candidates=expected.get((row['body'],row['hints']),[])
        if not candidates:unmatched.append(dict(launched_row,body=row['body'],hints=row['hints'],path=row['path']));continue
        options={tuple(r['configs']) for r in candidates}
        matched.append(dict(launched_row,body=row['body'],hints=row['hints'],path=row['path'],original_options=sorted(options),same_choice=tuple(launched_row['configs']) in options))
    Path(output).write_text(json.dumps(dict(actor_reference_kernels=len(actor),actual_launched=len(launched),matched=len(matched),
        mismatched_configurations=[r for r in matched if not r['same_choice']],unmatched=unmatched,bundled_without_triton_source=bundled),indent=2))
    return
    old=list(kernels(runs/'hotspot-shared-actor-frozen-reference-h/frozen-kernels.py'))+list(kernels(base/'world_smc_backward_a.py'))
    current=[]
    paths=list((runs/'hotspot-shared-training-smc-gate-m/inductor-cache').rglob('*.py'))
    assert len(paths)<1000 and sum(p.stat().st_size for p in paths)<100*1024**2
    for path in paths:current.extend(kernels(path))
    exact={r['source_hash'] for r in old}; by_body={}
    for row in old:by_body.setdefault(row['body'],[]).append(row)
    changes=[];unknown=0;matched=0
    for row in current:
        if row['source_hash'] in exact:matched+=1;continue
        choices=[r for r in by_body.get(row['body'],[]) if r['hints']==row['hints']]
        if not choices:unknown+=1;continue
        ref=min(choices,key=lambda r:len(list(difflib.unified_diff(r['source'].splitlines(),row['source'].splitlines()))))
        diff=[line for line in difflib.unified_diff(ref['source'].splitlines(),row['source'].splitlines()) if line.startswith(('+','-'))]
        changes.append(dict(name=row['name'],body=row['body'],path=row['path'],old_path=ref['path'],diff=diff))
    counts={}
    for row in changes:
        for line in row['diff']:counts[line]=counts.get(line,0)+1
    caches={}
    for label,folder in [('actor','hotspot-shared-actor-frozen-reference-h'),('world','hotspot-shared-world-reference-smc-gate-f'),('coupled','hotspot-shared-training-smc-gate-m')]:
        files=list((runs/folder/'inductor-cache/cache').glob('*'));assert len(files)==1
        caches[label]={k:v for k,v in json.loads(files[0].read_text())['cache'].items() if isinstance(v,bool)}
    padding=[]
    for scope in ('world','actor'):
        for key,value in caches[scope].items():
            if key in caches['coupled'] and caches['coupled'][key]!=value:
                padding.append(dict(scope=scope,key=key,original=value,coupled=caches['coupled'][key]))
    Path(output).write_text(json.dumps(dict(padding_decision_differences=padding,padding_counts={k:len(v) for k,v in caches.items()},old_kernels=len(old),current_kernels=len(current),
        exact_source_matches=matched,body_and_size_hint_matches=len(changes),unknown_bodies_or_hints=unknown,
        changed_lines=sorted(counts.items(),key=lambda x:-x[1]),examples=changes[:12]),indent=2))


if __name__=='__main__':main(*sys.argv[1:])
