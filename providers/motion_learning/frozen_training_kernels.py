"""Replay actual original-SMC kernel choices, including late reduction tuning.

Contracts include the original kernel name, executable body, tensor signature
and size hints. Module
paths/debug metadata may differ; ambiguous executable contracts are rejected.
This never derives a reference choice from the native implementation.
"""
import ast
import hashlib
import inspect
import json
import re
from contextlib import contextmanager
from pathlib import Path

from compiler_reference_contract_f import body_key


def contract(source):
    functions=[n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef)]
    assert len(functions)==1
    dec=next(n for n in functions[0].decorator_list if isinstance(n,ast.Call))
    keywords={n.arg:n.value for n in dec.keywords}
    meta=keywords['triton_meta']
    signature=next(v for k,v in zip(meta.keys,meta.values) if ast.literal_eval(k)=='signature')
    hints=ast.literal_eval(keywords['size_hints'])
    return functions[0].name,body_key(source,ast.literal_eval(signature)),json.dumps(hints,sort_keys=True)


def sources(path):
    tree=ast.parse(path.read_text());wrapped=[]
    for node in ast.walk(tree):
        if isinstance(node,ast.Call) and ast.unparse(node.func)=='async_compile.triton':
            name,source=map(ast.literal_eval,node.args[:2]);wrapped.append((name,source))
    if wrapped:return wrapped
    return [(node.name,ast.unparse(node)) for node in tree.body if isinstance(node,ast.FunctionDef) and
            any(isinstance(d,ast.Call) and any(k.arg=='triton_meta' for k in d.keywords) for d in node.decorator_list)]


@contextmanager
def frozen_training_kernels(root,receipt):
    import triton
    from torch._inductor.runtime.triton_heuristics import CachingAutotuner
    root=Path(root);report=json.loads((root/'result.json').read_text());modules={}
    for path in (root/'inductor-cache').rglob('*.py'):
        digest=hashlib.sha256(path.read_bytes()).hexdigest()
        modules[digest]=path
    parsed={};contracts={};source_hashes={}
    for row in report['launched']:
        digest=row['module_sha256'];path=modules[digest];source_hashes[str(path)]=digest
        if digest not in parsed:parsed[digest]=dict(sources(path))
        assert row['kernel'] in parsed[digest],(row['kernel'],str(path))
        key=contract(parsed[digest][row['kernel']]);assert len(row['configs'])==1
        config=row['configs'][0]
        if key in contracts:assert contracts[key]['config']==config,('ambiguous original launch',key,contracts[key],row)
        contracts[key]=dict(config=config,source=str(path),kernel=row['kernel'])
    original=CachingAutotuner.__init__;precompile=CachingAutotuner.precompile
    signature=inspect.signature(original);seen=[];unknown=[];replayed=[]
    assert 'size_hints' in signature.parameters and 'inductor_meta' in signature.parameters
    def initialize(self,*args,**kwargs):
        bound=signature.bind(self,*args,**kwargs);a=bound.arguments
        key=(a['fn'].__name__,body_key(a['fn'].src,a['triton_meta']['signature']),json.dumps(a['size_hints'],sort_keys=True))
        record=contracts.get(key)
        if record is None:unknown.append(dict(body=key[1],hints=key[2],name=key[0]))
        else:
            settings={k:int(v) if v!='None' else None for k,v in re.findall(r'(\w+): (\d+|None)',record['config'])}
            extras={k:settings.pop(k) for k in ('num_warps','num_stages','num_ctas','maxnreg') if k in settings}
            config=triton.Config(settings,**extras);a['configs']=[config]
            meta=dict(a.get('inductor_meta') or {});meta.update(dynamic_scale_rblock=False,coordinate_descent_tuning=False);a['inductor_meta']=meta
            seen.append(dict(body=key[1],hints=key[2],name=key[0],reference=record,config=str(config)))
        result=original(*bound.args,**bound.kwargs)
        if record is not None:
            assert not getattr(self,'compile_results',[]) and not getattr(self,'launchers',[])
            self.configs=[config]
        return result
    def frozen_precompile(self,*args,**kwargs):
        key=(self.fn.__name__,body_key(self.fn.src,self.triton_meta['signature']),json.dumps(self.size_hints,sort_keys=True))
        record=contracts.get(key)
        if record is None:
            unknown.append(dict(body=key[1],hints=key[2],name=key[0],stage='precompile'))
        else:
            # A cached StaticAutotuner bypasses __init__. Its stored variants
            # still undergo runtime tuning unless replay is enforced here.
            settings={k:int(v) if v!='None' else None for k,v in re.findall(r'(\w+): (\d+|None)',record['config'])}
            extras={k:settings.pop(k) for k in ('num_warps','num_stages','num_ctas','maxnreg') if k in settings}
            config=triton.Config(settings,**extras)
            matches=[r for r in self.compile_results if str(r.config)==str(config)]
            if not matches and self.fn.fn is None:
                reload_kernel=kwargs.get('reload_kernel') or getattr(self,'_reload_kernel',None)
                assert callable(reload_kernel),('original selected variant absent from serialized cache',key)
                self.fn=reload_kernel().fn
            self.compile_results=matches[:1];self.launchers=[];self.configs=[config]
            self.inductor_meta.update(dynamic_scale_rblock=False,coordinate_descent_tuning=False)
            replayed.append(dict(name=key[0],body=key[1],hints=key[2],config=str(config),cached_variant=bool(matches)))
        result=precompile(self,*args,**kwargs)
        if record is not None and not kwargs.get('warm_cache_only',False):
            assert len(self.launchers)==1 and str(self.launchers[0].config)==str(config)
        return result
    CachingAutotuner.__init__=initialize
    CachingAutotuner.precompile=frozen_precompile
    try:yield
    finally:
        CachingAutotuner.__init__=original
        CachingAutotuner.precompile=precompile
        Path(receipt).write_text(json.dumps(dict(original_run=str(root),contracts=len(contracts),kernels=seen,replayed=replayed,unknown=unknown,source_hashes=source_hashes),indent=2))
        assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in source_hashes.items())
