"""Opt-in native-export compiler decisions taken from a frozen SMC run.

Only native compilation is patched. Original SMC source/runtime is untouched.
Padding-cost flags are not numerical input properties: the AOT path can mark
the same weight transpose as an unfused padding input. Match the actual tensor
shape, stride, dtype, operation and TF32 flag instead, rejecting ambiguity.
Triton configurations are transferred only for identical function bodies and
tensor signatures. This is not a general floating-point equivalence claim.
"""
import ast
import hashlib
import inspect
import json
import re
from contextlib import contextmanager
from pathlib import Path


def normalized_padding_key(key):
    return re.sub(r"exclude_pad:(?:True|False)", "exclude_pad:*", key)


def body_key(source, signature):
    functions = [n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef)]
    assert len(functions) == 1
    function = functions[0]
    function.name = "reference_kernel"
    function.decorator_list = []
    payload = ast.dump(function, include_attributes=False) + json.dumps(signature, sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()


def kernel_contract(code, choices):
    result = {}
    for node in ast.walk(ast.parse(code)):
        if not isinstance(node,ast.Assign) or not isinstance(node.value,ast.Call): continue
        call=node.value
        if ast.unparse(call.func) != "async_compile.triton": continue
        name, source = (ast.literal_eval(a) for a in call.args[:2])
        if name not in choices: continue
        configs=choices[name]["configs"]
        assert len(configs)==1
        function=next(n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef))
        decorator=next(n for n in function.decorator_list if isinstance(n,ast.Call))
        meta=next(k.value for k in decorator.keywords if k.arg=="triton_meta")
        signature=next(v for k,v in zip(meta.keys,meta.values) if ast.literal_eval(k)=="signature")
        key=body_key(source,ast.literal_eval(signature))
        settings={k:int(v) if v!="None" else None for k,v in re.findall(r"(\w+): (\d+|None)",configs[0])}
        assert settings and "num_warps" in settings
        record=dict(name=name,settings=settings)
        assert key not in result or result[key]["settings"] == settings, "ambiguous identical kernel configuration"
        result[key]=record
    return result


@contextmanager
def reference_compilation(cache_file, code_file, choices_file, receipt):
    from torch._inductor.fx_passes import pad_mm
    from torch._inductor.runtime.triton_heuristics import CachingAutotuner as CachedAutotuner
    import triton
    paths=[Path(p) for p in (cache_file,code_file,choices_file)]
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    choices=json.loads(paths[2].read_text())["smc_loaded_kernels"]
    kernels=kernel_contract(paths[1].read_text(),choices)
    decisions={}
    for key,value in json.loads(paths[0].read_text())["cache"].items():
        if not isinstance(value,bool): continue
        normalized=normalized_padding_key(key)
        assert normalized not in decisions or decisions[normalized]["value"] == value, "ambiguous SMC padding decisions"
        decisions[normalized]=dict(key=key,value=value)
    original_pad=pad_mm.get_cached_should_pad
    original_init=CachedAutotuner.__init__
    signature=inspect.signature(original_init)
    assert "fn" in signature.parameters and "configs" in signature.parameters and "triton_meta" in signature.parameters
    seen_pad, seen_kernel, unknown=[],[],[]
    def frozen_pad(key):
        record=decisions.get(normalized_padding_key(key))
        if record is None:
            unknown.append(key)
            return original_pad(key)
        seen_pad.append(dict(native_key=key,reference_key=record["key"],value=record["value"]))
        return record["value"]
    def frozen_init(self,*args,**kwargs):
        bound=signature.bind(self,*args,**kwargs)
        fn=bound.arguments["fn"]
        meta=bound.arguments["triton_meta"]
        key=body_key(fn.src,meta["signature"])
        record=kernels.get(key)
        if record is not None:
            options=dict(record["settings"])
            extras={k:options.pop(k) for k in ("num_warps","num_stages","num_ctas","maxnreg") if k in options}
            config=triton.Config(options,**extras)
            bound.arguments["configs"]=[config]
            # PyTorch 2.11 can add another reduction configuration *after*
            # __init__, even when configs contains only one item. That changes
            # reduction order and can cross a BF16 rounding boundary. A frozen
            # reference contract must prevent this second tuning stage too.
            assert "inductor_meta" in signature.parameters
            frozen_meta=dict(bound.arguments.get("inductor_meta") or {})
            frozen_meta["dynamic_scale_rblock"]=False
            frozen_meta["coordinate_descent_tuning"]=False
            bound.arguments["inductor_meta"]=frozen_meta
            seen_kernel.append(dict(native_name=fn.__name__,reference_name=record["name"],body_sha256=key,
                                    config=str(config),dynamic_scale_rblock=False,coordinate_descent_tuning=False))
        result=original_init(*bound.args,**bound.kwargs)
        if record is not None:
            # The constructor can prefer a registered lookup_autotune_config
            # over its configs argument. Apply the contract after that lookup,
            # before precompile creates any launchers.
            assert not getattr(self,'compile_results',[]) and not getattr(self,'launchers',[])
            self.configs=[config]
        return result
    pad_mm.get_cached_should_pad=frozen_pad
    CachedAutotuner.__init__=frozen_init
    try:
        yield
    finally:
        pad_mm.get_cached_should_pad=original_pad
        CachedAutotuner.__init__=original_init
        Path(receipt).write_text(json.dumps(dict(source_hashes=hashes,padding=seen_pad,kernels=seen_kernel,
            unmatched_padding=sorted(set(unknown)),scope="native export only; original SMC decisions; exact-body kernel matching"),indent=2))
        assert all(hashlib.sha256(p.read_bytes()).hexdigest()==hashes[str(p)] for p in paths)


@contextmanager
def frozen_original_compilation(code_file, choices_file, receipt):
    """Replay original SMC choices by exact generated Triton source.

    Two original graphs can use the same body/type signature with different
    size hints and launch choices. A global body-only lookup is ambiguous in
    that case. This original-only replay keys the entire source and scopes the
    constructor override to its synchronous AsyncCompile.triton call. It does
    not transfer one graph's choice to another or change any generated code.
    """
    import triton
    from torch._inductor.async_compile import AsyncCompile
    from torch._inductor.runtime.triton_heuristics import CachingAutotuner
    from torch._inductor import config as compiler_config
    assert compiler_config.compile_threads == 1, 'source-scoped replay must be synchronous'
    code_path,choices_path=Path(code_file),Path(choices_file)
    choices=json.loads(choices_path.read_text())['smc_loaded_kernels']
    contracts={}
    for node in ast.walk(ast.parse(code_path.read_text())):
        if not isinstance(node,ast.Call) or ast.unparse(node.func)!='async_compile.triton':continue
        name,source=map(ast.literal_eval,node.args[:2])
        if name not in choices:continue
        one=kernel_contract(f'{name}=async_compile.triton({name!r},{source!r})',{name:choices[name]})
        assert len(one)==1
        body,record=next(iter(one.items()))
        key=hashlib.sha256(source.encode()).hexdigest()
        assert key not in contracts or contracts[key]['settings']==record['settings'], 'same exact source selected two configurations'
        contracts[key]=dict(record,body_sha256=body)
    original_compile,original_init=AsyncCompile.triton,CachingAutotuner.__init__
    signature=inspect.signature(original_init)
    active=[];seen=[];unmatched=set()
    def compile_one(self,kernel_name,source_code,*args,**kwargs):
        key=hashlib.sha256(source_code.encode()).hexdigest()
        record=contracts.get(key)
        if record is None:unmatched.add(key)
        active.append((key,record))
        try:return original_compile(self,kernel_name,source_code,*args,**kwargs)
        finally:active.pop()
    def initialize(self,*args,**kwargs):
        bound=signature.bind(self,*args,**kwargs)
        selected=None
        if active and active[-1][1] is not None:
            key,record=active[-1]
            fn=bound.arguments['fn']
            assert body_key(fn.src,bound.arguments['triton_meta']['signature'])==record['body_sha256']
            options=dict(record['settings'])
            extras={k:options.pop(k) for k in ('num_warps','num_stages','num_ctas','maxnreg') if k in options}
            selected=triton.Config(options,**extras)
            bound.arguments['configs']=[selected]
            metadata=dict(bound.arguments.get('inductor_meta') or {})
            metadata.update(dynamic_scale_rblock=False,coordinate_descent_tuning=False)
            bound.arguments['inductor_meta']=metadata
            seen.append(dict(source_sha256=key,body_sha256=record['body_sha256'],name=fn.__name__,config=str(selected)))
        result=original_init(*bound.args,**bound.kwargs)
        if selected is not None:
            assert not getattr(self,'compile_results',[]) and not getattr(self,'launchers',[])
            self.configs=[selected]
        return result
    AsyncCompile.triton,CachingAutotuner.__init__=compile_one,initialize
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (code_path,choices_path)}
    try:yield
    finally:
        AsyncCompile.triton,CachingAutotuner.__init__=original_compile,original_init
        Path(receipt).write_text(json.dumps(dict(source_hashes=hashes,kernels=seen,unmatched_sources=sorted(unmatched),
            exact_source_contracts=len(contracts),scope='original SMC replay of its own selected configurations; generated source unchanged'),indent=2))
        assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==digest for p,digest in hashes.items())
