"""CPU regressions for frozen original choices restored from autotuner caches."""
import hashlib
import importlib
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import compiler_reference_contract


class FrozenTrainingTest(unittest.TestCase):
    def test_cached_constructor_bypass_and_unknown_kernel_audit(self):
        source=("@triton_heuristics.pointwise(size_hints={'x': 512}, "
                "triton_meta={'signature': {'x': '*fp32'}})\n"
                "def selected(x):\n    return x + 1\n")
        class Config:
            def __init__(self,kwargs,**options):self.kwargs,self.options=kwargs,options
            def __str__(self):
                return ', '.join(f'{k}: {v}' for k,v in sorted({**self.kwargs,**self.options}.items()))
        selected=Config({'XBLOCK':8},num_warps=2,num_ctas=1,num_stages=1,maxnreg=None)
        other=Config({'XBLOCK':32},num_warps=4,num_ctas=1,num_stages=1,maxnreg=None)
        class Autotuner:
            def __init__(self,fn,configs,triton_meta,size_hints,inductor_meta=None):
                self.fn,self.configs,self.triton_meta,self.size_hints=fn,configs,triton_meta,size_hints
                self.inductor_meta=inductor_meta or {};self.compile_results=[];self.launchers=[]
            def precompile(self,*,warm_cache_only=False,reload_kernel=None):
                if not self.compile_results:
                    self.compile_results=[types.SimpleNamespace(config=c) for c in self.configs]
                if not warm_cache_only:
                    self.launchers=[types.SimpleNamespace(config=r.config) for r in self.compile_results]
        triton=types.ModuleType('triton');triton.Config=Config
        heuristics=types.ModuleType('torch._inductor.runtime.triton_heuristics');heuristics.CachingAutotuner=Autotuner
        with patch.dict(sys.modules,{'compiler_reference_contract_f':compiler_reference_contract}):
            replay=importlib.import_module('frozen_training_kernels')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cache=root/'inductor-cache';cache.mkdir();path=cache/'kernel.py';path.write_text(source)
            digest=hashlib.sha256(path.read_bytes()).hexdigest()
            (root/'result.json').write_text(json.dumps({'launched':[{'module_sha256':digest,'kernel':'selected','configs':[str(selected)]}]}))
            fn=types.SimpleNamespace(__name__='selected',src=source,fn=None)
            # This object represents a deserialized StaticAutotuner. It was
            # initialized before the hook and contains several cached variants.
            cached=Autotuner(fn,[other,selected],{'signature':{'x':'*fp32'}},{'x':512},{'dynamic_scale_rblock':True})
            cached.compile_results=[types.SimpleNamespace(config=c) for c in (other,selected)]
            unknown=Autotuner(types.SimpleNamespace(__name__='selected',src=source.replace('x + 1','x + 2'),fn=None),[other],{'signature':{'x':'*fp32'}},{'x':512},{})
            previous=Autotuner.precompile
            with patch.dict(sys.modules,{'triton':triton,'torch._inductor.runtime.triton_heuristics':heuristics}):
                with replay.frozen_training_kernels(root,root/'receipt.json'):
                    cached.precompile();unknown.precompile()
                    self.assertEqual([str(x.config) for x in cached.launchers],[str(selected)])
                    self.assertFalse(cached.inductor_meta['dynamic_scale_rblock'])
                    self.assertEqual([str(x.config) for x in unknown.launchers],[str(other)])
            self.assertIs(Autotuner.precompile,previous)
            report=json.loads((root/'receipt.json').read_text())
            self.assertEqual(len(report['replayed']),1)
            self.assertTrue(report['replayed'][0]['cached_variant'])
            self.assertEqual(len(report['unknown']),1)
            self.assertEqual(report['unknown'][0]['stage'],'precompile')


if __name__=='__main__':unittest.main()
