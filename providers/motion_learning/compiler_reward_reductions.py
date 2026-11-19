"""Narrow native-export replay of the original reward's dynamic body sum.

The captured original graph and source are immutable inputs. Only the exact
known static reduction is replaced; arbitrary names or approximate matches are
never accepted. The source's tensor/scalar ABI and original launch are retained.
"""
import ast
import copy
import hashlib
import inspect
import json
import re
from contextlib import contextmanager
from pathlib import Path

from compiler_reference_contract_f import body_key


def kernel_source(path, name):
    matches=[node for node in ast.walk(ast.parse(Path(path).read_text())) if isinstance(node,ast.Call)
             and ast.unparse(node.func)=='async_compile.triton' and ast.literal_eval(node.args[0])==name]
    assert len(matches)==1
    return ast.literal_eval(matches[0].args[1])


def function_and_signature(source):
    functions=[node for node in ast.parse(source).body if isinstance(node,ast.FunctionDef)]
    assert len(functions)==1
    function=functions[0]
    decorator=next(d for d in function.decorator_list if isinstance(d,ast.Call))
    meta=next(k.value for k in decorator.keywords if k.arg=='triton_meta')
    signature=next(ast.literal_eval(v) for k,v in zip(meta.keys,meta.values) if ast.literal_eval(k)=='signature')
    return function,signature


@contextmanager
def original_dynamic_body_sum(static_code, original_code, configuration, receipt):
    import triton
    from torch._inductor.async_compile import AsyncCompile
    from torch._inductor.runtime.triton_heuristics import CachingAutotuner
    name='triton_per_fused_div_expand_mul_neg_sum_unsqueeze_0'
    before=kernel_source(static_code,name);after=kernel_source(original_code,name)
    static_function,signature=function_and_signature(before)
    dynamic_function,dynamic_signature=function_and_signature(after)
    assert signature==dynamic_signature
    assert ast.dump(static_function.args)==ast.dump(dynamic_function.args)
    before_key=body_key(before,signature);after_key=body_key(after,signature)
    assert before_key!=after_key
    settings={k:int(v) if v!='None' else None for k,v in re.findall(r'(\w+): (\d+|None)',configuration)}
    extras={k:settings.pop(k) for k in ('num_warps','num_stages','num_ctas','maxnreg') if k in settings}
    selected=triton.Config(settings,**extras)
    compile_one=AsyncCompile.triton;initialize=CachingAutotuner.__init__
    initializer_signature=inspect.signature(initialize)
    if 'fn' not in initializer_signature.parameters:
        # reference_compilation intentionally scopes an outer constructor
        # wrapper. Recover its inspected ABI rather than binding *args twice.
        initializer_signature=inspect.getclosurevars(initialize).nonlocals['signature']
    assert 'fn' in initializer_signature.parameters and 'configs' in initializer_signature.parameters
    rewrites=[];launches=[]
    def rewrite(self,kernel_name,source_code,*args,**kwargs):
        _,actual_signature=function_and_signature(source_code)
        if body_key(source_code,actual_signature)==before_key:
            tree=ast.parse(source_code)
            function=next(n for n in tree.body if isinstance(n,ast.FunctionDef))
            assert ast.dump(function.args)==ast.dump(dynamic_function.args)
            function.body=copy.deepcopy(dynamic_function.body)
            source_code=ast.unparse(tree)+'\n# original SMC dynamic body-position sum\n'
            assert body_key(source_code,actual_signature)==after_key
            rewrites.append(dict(kernel=kernel_name,source=source_code,sha256=hashlib.sha256(source_code.encode()).hexdigest()))
        return compile_one(self,kernel_name,source_code,*args,**kwargs)
    def configure(self,*args,**kwargs):
        bound=initializer_signature.bind(self,*args,**kwargs);a=bound.arguments
        hit=body_key(a['fn'].src,a['triton_meta']['signature'])==after_key
        if hit:
            a['configs']=[selected]
            a['inductor_meta']=dict(a.get('inductor_meta') or {},dynamic_scale_rblock=False,coordinate_descent_tuning=False)
        result=initialize(*bound.args,**bound.kwargs)
        if hit:
            assert not self.compile_results and not self.launchers
            self.configs=[selected];launches.append(dict(name=a['fn'].__name__,config=str(selected)))
        return result
    AsyncCompile.triton=rewrite;CachingAutotuner.__init__=configure
    try:yield
    finally:
        AsyncCompile.triton=compile_one;CachingAutotuner.__init__=initialize
        Path(receipt).write_text(json.dumps(dict(static_body=before_key,original_dynamic_body=after_key,
            rewrites=rewrites,configurations=launches,original_graph_changed=False),indent=2))
        assert rewrites and launches,'native body-sum replay was not executed'
