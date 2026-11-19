"""Opt-in AOT normalization boundaries matching SMC BF16 input conversion.

No parameter/statistic is compiled as a constant. The original unfused native
implementation is retained. This exports a candidate, NOT actor acceptance.
"""
import json
import os
from pathlib import Path

import torch
from export_compiled_world_g import export_pair
from precision_mlp_probe_a import read_tensor


def main():
    out = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    root = Path(os.environ["MOONROBO_SHARED_INPUT"])
    assert torch.cuda.mem_get_info()[0] > 24*1024**3
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True
    fixture = json.loads((root/"fixture.json").read_text())
    records = {r["name"]:r for r in fixture["records"]}
    frontend = torch._inductor.aot_compile

    def compile_captured(gm,args,*,options):
        if not options["aot_inductor.output_path"].endswith("backward.so"):
            return frontend(gm,args,options=options)
        from torch._inductor.compile_fx import compile_fx_inner,get_cpp_wrapper_config
        from torch._inductor.virtualized import V
        options={**get_cpp_wrapper_config(),**options,"cpp_wrapper":True}
        with torch._inductor.config.patch(options),V.set_aot_compilation(True),torch._guards.compile_context(torch._guards.CompileContext(None)):
            return compile_fx_inner(gm,args,cpp_wrapper=True,is_backward=True,is_inference=False).filename

    def normalize(x,mean,variance):
        return ((x-mean)/torch.sqrt(variance+1e-4)).to(torch.bfloat16)

    torch._inductor.aot_compile=compile_captured
    try:
        for name,record,index in (("goal","goal-0",3),("observation","history",2)):
            x=read_tensor(root,records[record]).requires_grad_()
            saved=fixture["metadata"]["normalizers"][index]
            mean=torch.tensor(saved["mean"],device="cuda")
            variance=torch.tensor(saved["variance"],device="cuda")
            export_pair(normalize,[x,mean,variance],torch.ones_like(x,dtype=torch.bfloat16),out/name)
    finally:
        torch._inductor.aot_compile=frontend
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16*1024**3 and torch.cuda.memory_reserved() < 32*1024**3
    (out/"result.json").write_text(json.dumps(dict(exported=True,diagnostic_only=True,
        scope="BF16 goal/observation normalization and input VJP; full actor not yet accepted",
        backward_entry="compile_fx_inner(is_backward=True)",peak_reserved=torch.cuda.max_memory_reserved()),indent=2))


if __name__=="__main__": main()
