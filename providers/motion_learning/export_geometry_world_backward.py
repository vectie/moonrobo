"""Export corrected-math world backward from its natural post-grad graph.

Only the argument permutation is changed. Forward and error binaries stay
identical; no result is accepted without the separate full numerical gate.
"""
import ast
import hashlib
import json
import os
from pathlib import Path

import torch
from torch._subclasses.fake_tensor import FakeTensorMode
from compiler_reference_contract_c import reference_compilation


def main():
    out = Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    original = Path('/workspace/moonrobo/runs/hotspot-geometry-math-ieee-packages-a')
    capture = Path('/workspace/moonrobo/runs/hotspot-mlp-geometry-world-boundary-capture-a')
    source = capture/'compile-debug/torchinductor/model__0_backward_7.3'
    assert torch.cuda.mem_get_info()[0] > 24*1024**3
    torch.backends.cuda.matmul.allow_tf32 = False
    torch._inductor.config.compile_threads = 1
    for branch in ('rollout', 'error'):
        target = out/branch
        target.mkdir()
        for path in (original/branch).iterdir():
            if path.is_file() and not (branch == 'rollout' and path.name.startswith('backward')):
                (target/path.name).write_bytes(path.read_bytes())

    def function(path):
        return next(n for n in ast.walk(ast.parse(path.read_text()))
                    if isinstance(n, ast.FunctionDef) and n.name == 'forward')
    control = function(source/'fx_graph_readable.py')
    native = function(original/'rollout/backward.fx.txt')
    native_names = [a.arg for a in native.args.args if a.arg != 'self']
    rename = {'primals_6': 'primals_8', 'primals_7': 'primals_9',
              'primals_10': 'primals_12', 'primals_11': 'primals_13',
              'primals_14': 'primals_16', 'primals_15': 'primals_17',
              'primals_19': 'primals_5', 'primals_21': 'primals_20'}
    graph = torch.fx.Graph()
    environment = {rename.get(n, n): graph.placeholder(n) for n in native_names}
    assert set(environment) == {a.arg for a in control.args.args if a.arg != 'self'}

    def value(node):
        if isinstance(node, ast.Name):
            if node.id in environment:
                return environment[node.id]
            return {'torch': torch, 'device': torch.device, 'inf': float('inf')}[node.id]
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Attribute):
            return getattr(value(node.value), node.attr)
        if isinstance(node, (ast.List, ast.Tuple)):
            items = [value(x) for x in node.elts]
            return tuple(items) if isinstance(node, ast.Tuple) else items
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
            return -value(node.operand)
        if isinstance(node, ast.Call) and ast.unparse(node.func) == 'device':
            return torch.device(*[value(n) for n in node.args],
                                **{k.arg: value(k.value) for k in node.keywords})
        raise AssertionError(ast.dump(node))

    for node in control.body:
        if isinstance(node, ast.AnnAssign):
            assert isinstance(node.target, ast.Name) and isinstance(node.value, ast.Call)
            expr = node.value
            environment[node.target.id] = graph.call_function(
                value(expr.func), tuple(value(n) for n in expr.args),
                {k.arg: value(k.value) for k in expr.keywords})
        elif isinstance(node, ast.Return):
            outputs = [value(n) for n in node.value.elts
                       if not isinstance(n, ast.Constant) or n.value is not None]
            assert len(outputs) == 14
            graph.output(tuple(outputs))
        else:
            assert isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and node.value.value is None
    gm = torch.fx.GraphModule(torch.nn.Module(), graph)
    (out/'rollout/backward.fx.txt').write_text(gm.code)
    code = source/'output_code.py'
    digest = hashlib.sha256(code.read_bytes()).hexdigest()
    selected = {r['kernel']: {'configs': r['configs']}
                for r in json.loads((capture/'result.json').read_text())['launched']
                if r['module_sha256'] == digest}
    assert selected, 'exact captured module required'
    (out/'choices.json').write_text(json.dumps({'smc_loaded_kernels': selected}))
    # Shapes are fixed; unmatched padding decisions remain visible in receipt.
    (out/'padding.json').write_text('{"cache":{}}')
    manifest = json.loads((out/'rollout/manifest.json').read_text())
    dtype = {'torch.float32': torch.float32, 'torch.bfloat16': torch.bfloat16,
             'torch.int64': torch.int64, 'torch.bool': torch.bool}
    with reference_compilation(out/'padding.json', code, out/'choices.json', out/'reference-decisions.json'):
        with FakeTensorMode():
            examples = [torch.empty_strided(s['shape'], s['stride'], dtype=dtype[s['dtype']], device='cuda')
                        for s in manifest['graphs']['backward']['inputs']]
            from torch._inductor.compile_fx import compile_fx_inner, get_cpp_wrapper_config
            from torch._inductor.virtualized import V
            options = {**get_cpp_wrapper_config(), 'aot_inductor.output_path': str(out/'rollout/backward.so'),
                       'compile_threads': 1, 'cpp_wrapper': True}
            with torch._inductor.config.patch(options), V.set_aot_compilation(True), torch._guards.compile_context(torch._guards.CompileContext(None)):
                artifact = compile_fx_inner(gm, examples, cpp_wrapper=True, is_backward=True, is_inference=False)
            assert Path(artifact.filename).name == 'backward.so'
    manifest['backward_source'] = 'corrected-math natural post-grad FX; argument permutation only'
    manifest['backward_source_sha256'] = hashlib.sha256((source/'fx_graph_readable.py').read_bytes()).hexdigest()
    (out/'rollout/manifest.json').write_text(json.dumps(manifest, indent=2))
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16*1024**3 and torch.cuda.max_memory_reserved() < 32*1024**3
    (out/'result.json').write_text(json.dumps({'exported': True, 'acceptance_not_implied': True,
        'reserved_peak': torch.cuda.max_memory_reserved()}))


if __name__ == '__main__':
    main()
