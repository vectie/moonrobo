"""Numerical control of the first recurrent q/qd boundary, never timing.

Replay the original SMC kernel and the native generated kernel bodies on the
same dx, cotangents and normalizer buffers. Recompiled native bodies must first
reproduce the captured native q/qd output exactly, or the control is rejected.
"""
import ast
import hashlib
import importlib.util
import json
import re
import textwrap

import torch
import triton


def native_function(wrapper, name):
    matches = re.findall(r"async_compile\.triton\('([^']+)', '''(.*?)'''", wrapper, re.S)
    source = next(textwrap.dedent(source) for key, source in matches if key == name)
    function = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef))
    assert function.name == name
    function.decorator_list = [ast.Attribute(value=ast.Name(id="triton", ctx=ast.Load()), attr="jit", ctx=ast.Load())]
    return ast.unparse(function)


def joint_control(out, wrapper, smc_kernel, smc_rows, native_rows, cotangent, wm):
    norm_name = "triton_poi_fused_add_convert_element_type_div_sqrt_14"
    combine_name = "triton_poi_fused_add_cat_convert_element_type_div_expand_mul_select_slice_sqrt_squeeze_sum_17"
    source = "import triton\nimport triton.language as tl\n\n" + "\n\n".join(native_function(wrapper, name) for name in (norm_name, combine_name))
    path = out / "joint_native_generated_bodies.py"
    path.write_text(source)
    spec = importlib.util.spec_from_file_location("joint_native_generated_bodies", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    dx = smc_rows["mm_6"][1][2].cuda()
    assert dx.shape == (2048, 136) and dx.dtype == torch.bfloat16
    assert torch.equal(dx[:, :133].cpu(), native_rows["mm_6"][1][2])
    normalized = torch.empty((2048, 133), device="cuda", dtype=torch.float32)
    norm_compiled = getattr(module, norm_name)[(triton.cdiv(2048*133, 1024),)](
        dx[:, :133].contiguous(), wm.in_norm.var, normalized, 2048*133,
        XBLOCK=1024, num_warps=4, enable_fp_fusion=True,
    )
    z3 = torch.zeros((2048, 3), device="cuda")
    z1 = torch.zeros((2048,), device="cuda")
    z70 = torch.zeros((2048, 70), device="cuda")
    native = torch.empty_like(z70, dtype=torch.bfloat16)
    smc = torch.empty_like(native)
    # Autograd normalizes cotangent layouts before entering the generated
    # backward wrapper. Its assert_size_stride requires (232,29,1), whereas
    # the upstream error VJP may return a noncontiguous tensor.
    q_cotangent, qd_cotangent = (g.contiguous() for g in cotangent[4:6])
    assert q_cotangent.stride() == qd_cotangent.stride() == (232,29,1)
    common = (z3, z3, z1, z70, z3, z3, q_cotangent)
    combine_compiled = getattr(module, combine_name)[(triton.cdiv(2048*70, 512),)](
        *common, normalized, qd_cotangent, wm.out_norm.var, native, 2048*70,
        XBLOCK=512, num_warps=8, enable_fp_fusion=True,
    )
    # This is the exact callable observed in the original SMC backward frame.
    smc_kernel.run(*common, dx, wm.in_norm.var, qd_cotangent, wm.out_norm.var,
                   smc, 2048*70, stream=torch.cuda.current_stream().cuda_stream)
    torch.cuda.synchronize()
    nq, sq = native[:, 12:].cpu(), smc[:, 12:].cpu()
    native_expected = native_rows["mm_8"][1][0][:, 12:]
    smc_expected = smc_rows["mm_8"][1][0][:, 12:]
    checks = dict(native_reproduces_captured_joint_output=torch.equal(nq,native_expected),
                  smc_reproduces_captured_joint_output=torch.equal(sq,smc_expected))
    indices=torch.nonzero(nq!=sq,as_tuple=False)
    result=dict(diagnostic_only=True, acceptance_not_implied=True,checks=checks,
                upstream_cotangent_strides=[list(g.stride()) for g in cotangent[4:6]],
                wrapper_cotangent_strides=[list(g.stride()) for g in (q_cotangent,qd_cotangent)],
                unequal=int(indices.shape[0]),max_abs=float((nq.float()-sq.float()).abs().max()),
                examples=[dict(batch=int(i),output_channel=int(j)+12,native=float(nq[i,j]),smc=float(sq[i,j])) for i,j in indices[:16]],
                native_source_sha256=hashlib.sha256(source.encode()).hexdigest(),
                scope="q/qd only at the first recurrent boundary; identical matrix result, cotangents and norms; other channels replaced with zeros and excluded")
    (out/"joint-normalization-control.json").write_text(json.dumps(result,indent=2))
    (out/"joint-native-normalize.ptx").write_text(norm_compiled.asm["ptx"])
    (out/"joint-native-combine.ptx").write_text(combine_compiled.asm["ptx"])
    assert all(checks.values()), "standalone kernel control did not reproduce captured native/reference outputs"
    return result
