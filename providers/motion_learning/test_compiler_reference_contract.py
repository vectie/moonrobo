"""CPU regression for the native-only frozen compiler-decision adapter."""
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from compiler_reference_contract import reference_compilation, frozen_original_compilation


class ContractTest(unittest.TestCase):
    def test_original_replay_distinguishes_identical_bodies_by_full_source(self):
        class Config:
            def __init__(self,kwargs,**options):self.kwargs,self.options=kwargs,options
            def __str__(self):return str(self.kwargs)
        class Autotuner:
            def __init__(self,fn,configs,triton_meta,inductor_meta=None):
                # Simulate the constructor's registered-config preference.
                self.configs,self.meta=[Config({'XBLOCK':1})],inductor_meta
        class AsyncCompile:
            def triton(self,kernel_name,source_code):
                fn=types.SimpleNamespace(src=source_code,__name__=kernel_name)
                return Autotuner(fn,[Config({'XBLOCK':1})],{'signature':{'x':'*fp32'}},{'dynamic_scale_rblock':True})
        compiler=types.ModuleType('torch._inductor');compiler.config=types.SimpleNamespace(compile_threads=1)
        asynchronous=types.ModuleType('torch._inductor.async_compile');asynchronous.AsyncCompile=AsyncCompile
        heuristics=types.ModuleType('torch._inductor.runtime.triton_heuristics');heuristics.CachingAutotuner=Autotuner
        triton=types.ModuleType('triton');triton.Config=Config
        sources=[f"@triton_heuristics.pointwise(size_hints={{'x': {n}}}, triton_meta={{'signature': {{'x': '*fp32'}}}})\ndef selected(x):\n    return x + 1\n" for n in (512,1024)]
        old_compile,old_init=AsyncCompile.triton,Autotuner.__init__
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);code,choices,receipt=[root/n for n in ('code.py','choices.json','receipt.json')]
            code.write_text('\n'.join(f'k{i}=async_compile.triton("k{i}",{source!r})' for i,source in enumerate(sources)))
            choices.write_text(json.dumps({'smc_loaded_kernels':{f'k{i}':{'configs':[f'XBLOCK: {n}, num_warps: 4, num_ctas: 1, num_stages: 1, maxnreg: None']} for i,n in enumerate((512,1024))}}))
            with patch.dict(sys.modules,{'torch._inductor':compiler,'torch._inductor.async_compile':asynchronous,'torch._inductor.runtime.triton_heuristics':heuristics,'triton':triton}):
                with frozen_original_compilation(code,choices,receipt):
                    for i,n in enumerate((512,1024)):
                        actual=AsyncCompile().triton('selected',sources[i])
                        self.assertEqual(actual.configs[0].kwargs,{'XBLOCK':n})
                        self.assertFalse(actual.meta['dynamic_scale_rblock'])
                    unknown=AsyncCompile().triton('unknown',sources[0].replace('x + 1','x + 2'))
                    self.assertEqual(unknown.configs[0].kwargs,{'XBLOCK':1})
                self.assertIs(AsyncCompile.triton,old_compile)
                self.assertIs(Autotuner.__init__,old_init)
                report=json.loads(receipt.read_text())
                self.assertEqual(report['exact_source_contracts'],2)
                self.assertEqual(len(report['kernels']),2)
                self.assertEqual(len(report['unmatched_sources']),1)

    def test_exact_kernel_disables_late_reduction_retuning_and_restores_hooks(self):
        source="""@triton_heuristics.reduction(triton_meta={'signature': {'x': '*fp32'}})
def selected(x):
    return x + 1
"""
        class Config:
            def __init__(self,kwargs,**options):self.kwargs,self.options=kwargs,options
            def __str__(self):return str((self.kwargs,self.options))
        class Autotuner:
            def __init__(self,fn,configs,triton_meta,inductor_meta=None):
                self.configs=configs
                self.meta=inductor_meta
        pad=types.ModuleType('torch._inductor.fx_passes.pad_mm')
        original_pad=lambda key:None
        pad.get_cached_should_pad=original_pad
        passes=types.ModuleType('torch._inductor.fx_passes');passes.pad_mm=pad
        heuristics=types.ModuleType('torch._inductor.runtime.triton_heuristics')
        heuristics.CachingAutotuner=Autotuner
        triton=types.ModuleType('triton');triton.Config=Config
        original_init=Autotuner.__init__
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            cache,code,choices,receipt=[root/n for n in ('cache.json','code.py','choices.json','receipt.json')]
            cache.write_text(json.dumps({'cache':{}}))
            code.write_text('selected = async_compile.triton("selected", '+repr(source)+')')
            choices.write_text(json.dumps({'smc_loaded_kernels':{'selected':{'configs':['XBLOCK: 2, R0_BLOCK: 1024, num_warps: 8, num_ctas: 1, num_stages: 1, maxnreg: None']}}}))
            with patch.dict(sys.modules,{'torch._inductor.fx_passes':passes,'torch._inductor.runtime.triton_heuristics':heuristics,'triton':triton}):
                with reference_compilation(cache,code,choices,receipt):
                    initial={'dynamic_scale_rblock':True,'coordinate_descent_tuning':True,'unrelated':17}
                    fn=types.SimpleNamespace(src=source,__name__='native_renamed')
                    actual=Autotuner(fn,[Config({'R0_BLOCK':512})],{'signature':{'x':'*fp32'}},initial)
                    self.assertEqual(actual.configs[0].kwargs,{'XBLOCK':2,'R0_BLOCK':1024})
                    self.assertFalse(actual.meta['dynamic_scale_rblock'])
                    self.assertFalse(actual.meta['coordinate_descent_tuning'])
                    self.assertEqual(actual.meta['unrelated'],17)
                    self.assertTrue(initial['dynamic_scale_rblock'],'caller metadata must not be mutated')
                    unknown=types.SimpleNamespace(src=source.replace('x + 1','x + 2'),__name__='unmatched')
                    untouched=Autotuner(unknown,[Config({'R0_BLOCK':512})],{'signature':{'x':'*fp32'}},initial)
                    self.assertIs(untouched.meta,initial)
                self.assertIs(Autotuner.__init__,original_init)
                self.assertIs(pad.get_cached_should_pad,original_pad)
                recorded=json.loads(receipt.read_text())['kernels']
                self.assertEqual(len(recorded),1)
                self.assertFalse(recorded[0]['dynamic_scale_rblock'])


if __name__=='__main__':unittest.main()
