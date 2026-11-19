"""Matched training phase boundaries; no per-operator observer or synchronization.

The policy body is the original SMC AST with only the existing fixed permutation
substitution. Removing the timing context managers must recover that AST exactly.
CUDA events measure stream elapsed time, not active kernel time. Never add CPU
submission time to stream time. Compare observer-on/off runs separately.
"""
import ast
import copy
import hashlib
import json
import os
import time
from contextlib import ExitStack
from pathlib import Path

import torch
import supermimic.rotations as rotations
from shared_smc_probe_bf16_original import SharedProbe, Meter, networks, mdp_module
from frozen_training_kernels_am import frozen_training_kernels
from geometry_math_revision import corrected_smc_geometry
from geometry_reference_constants_b import fp64_robot_constants, captured_padding


def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def artifacts(root):
    return {str(p.relative_to(root)): digest(p)
            for folder in ('inductor-cache', 'triton-cache')
            for p in (root/folder).rglob('*') if p.is_file() and
            (p.suffix in ('.py', '.so', '.cubin', '.ptx', '.json', '.c', '.cpp')
             or '.best_config' in p.name)}


def instrument_policy(probe):
    tree = ast.parse(Path(os.environ['SHARED_SMC_TRAIN']).read_text())
    body = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'policy_update')
    class Orders(ast.NodeTransformer):
        count = 0
        def visit_Assign(self, node):
            if ast.unparse(node.targets[0]) == 'perm':
                assert ast.unparse(node.value) == 'torch.randperm(n, device=dev)'
                node.value = ast.parse('orders[_]', mode='eval').body
                self.count += 1
            return node
    rewrite = Orders()
    body = rewrite.visit(body)
    assert rewrite.count == 1
    expected = ast.dump(body, include_attributes=False)
    def wrap(label, nodes):
        assert nodes
        ctx = ast.parse(f'_cost_meter.span({label!r})', mode='eval').body
        return ast.With(items=[ast.withitem(context_expr=ctx, optional_vars=None)], body=nodes)
    def find(nodes, predicate):
        found = [i for i,n in enumerate(nodes) if predicate(n)]
        assert len(found) == 1, found
        return found[0]
    nodes = body.body
    rollout = find(nodes, lambda n: isinstance(n, ast.For) and ast.unparse(n.target) == 't')
    reward = find(nodes, lambda n: isinstance(n, ast.Assign) and ast.unparse(n.targets[0]) == '(r, d)' and isinstance(n.value, ast.Call))
    tail = find(nodes, lambda n: isinstance(n, ast.If) and ast.unparse(n.test) == 'not args.no_critic' and not any(isinstance(x, ast.For) for x in ast.walk(n)))
    backward = find(nodes, lambda n: isinstance(n, ast.Expr) and ast.unparse(n.value) == 'loss.backward()')
    adam = find(nodes, lambda n: isinstance(n, ast.Assign) and ast.unparse(n.targets[0]) == 'gn')
    restore = find(nodes, lambda n: isinstance(n, ast.Expr) and ast.unparse(n.value) == 'set_requires_grad(wm, True)')
    critic = find(nodes, lambda n: isinstance(n, ast.If) and ast.unparse(n.test) == 'not args.no_critic' and any(isinstance(x, ast.For) for x in ast.walk(n)))
    critic_node = nodes[critic]
    epochs = find(critic_node.body, lambda n: isinstance(n, ast.For) and ast.unparse(n.target) == '_')
    epoch_loop = critic_node.body[epochs]
    minibatch = next(n for n in epoch_loop.body if isinstance(n, ast.For))
    mb = minibatch.body
    assert len(mb) == 6
    assert ast.unparse(mb[2]) == 'opt_v.zero_grad(set_to_none=True)'
    assert ast.unparse(mb[3]) == 'v_loss.backward()'
    minibatch.body = [wrap('critic.forward', mb[:2]), wrap('critic.zero_grad', mb[2:3]),
                      wrap('critic.backward', mb[3:4]), wrap('critic.adam', mb[4:])]
    critic_node.body = [wrap('critic.prepare', critic_node.body[:epochs]), epoch_loop]
    body.body = [wrap('actor.setup', nodes[:rollout]), wrap('actor.forward', nodes[rollout:rollout+1]),
                 wrap('actor.pack', nodes[rollout+1:reward]), wrap('actor.reward', nodes[reward:reward+1]),
                 wrap('actor.return', nodes[reward+1:tail]), wrap('actor.tail', nodes[tail:tail+1]),
                 wrap('actor.loss_zero_grad', nodes[tail+1:backward]), wrap('actor.backward', nodes[backward:backward+1]),
                 *nodes[backward+1:adam], wrap('actor.adam', nodes[adam:restore]),
                 wrap('actor.restore', nodes[restore:critic]), critic_node, *nodes[critic+1:]]
    class Strip(ast.NodeTransformer):
        def visit_With(self, node):
            node = self.generic_visit(node)
            ctx = node.items[0].context_expr
            return node.body if isinstance(ctx, ast.Call) and ast.unparse(ctx.func) == '_cost_meter.span' else node
    assert ast.dump(Strip().visit(copy.deepcopy(body)), include_attributes=False) == expected
    module = ast.fix_missing_locations(ast.Module(body=[body], type_ignores=[]))
    exec(compile(module, 'cost-original-smc-policy-fixed-orders', 'exec'), probe.ctx)
    probe.actor = probe.ctx['policy_update']
    return hashlib.sha256(expected.encode()).hexdigest()


def snapshot(probe, metrics):
    tensors = {}
    for name, model, opt in zip(('world', 'policy', 'critic'), probe.models, probe.opts):
        for i,p in enumerate(model.parameters()):
            state = opt.state.get(p, {})
            for field,value in [('parameter',p), ('gradient',p.grad), ('moment1',state.get('exp_avg')), ('moment2',state.get('exp_avg_sq'))]:
                if value is not None:
                    tensors[f'{name}-{i}-{field}'] = value.detach().cpu().clone()
    norms = [dict(mean=n.mean.cpu().tolist(),variance=n.var.cpu().tolist(),count=float(n.count))
             for n in (probe.wm.in_norm,probe.wm.out_norm,probe.pi.obs_norm,probe.pi.goal_norm,probe.critic.norm)]
    return dict(tensors=tensors, normalizers=norms, metrics=metrics)


def main():
    out = Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    runs = Path('/workspace/moonrobo/runs')
    control = os.environ['GEOMETRY_COST_CONTROL']
    assert control in ('original','ieee','corrected')
    observer = os.environ['MOONROBO_SHARED_OBSERVER']
    assert observer in ('off','events')
    repeats = int(os.environ['MOONROBO_SHARED_REPETITIONS']); assert repeats in (1,13)
    torch._inductor.config.compile_threads = 1
    torch._inductor.config.fx_graph_cache = True
    torch._functorch.config.enable_autograd_cache = False
    original_root = runs/'hotspot-shared-training-smc-gate-t'
    corrected_root = runs/'hotspot-shared-geometry-math-reference-gate-i'
    ieee_reference = os.environ.get('GEOMETRY_COST_IEEE_REFERENCE')
    with ExitStack() as stack:
        if control == 'corrected':
            stack.enter_context(corrected_smc_geometry(networks,mdp_module,rotations))
            stack.enter_context(fp64_robot_constants())
            stack.enter_context(captured_padding(str(runs/'hotspot-mlp-geometry-world-boundary-capture-a/inductor-cache/cache/f92a497d48fc1e801d19741fe9400d6fec3acb29f7fe6611804a20fa1dda1c24'),out/'padding-decisions.json'))
        elif control == 'ieee' and ieee_reference:
            stack.enter_context(captured_padding(str(Path(ieee_reference)/'inductor-cache/cache/f92a497d48fc1e801d19741fe9400d6fec3acb29f7fe6611804a20fa1dda1c24'),out/'padding-decisions.json'))
        stack.enter_context(frozen_training_kernels(corrected_root if control == 'corrected' else original_root,out/'frozen-decisions.json'))
        probe = SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']),compiled=True)
        if control != 'original':
            torch.backends.cuda.matmul.allow_tf32 = False
        probe.prepare_actor(); probe.ctx['args'].wm_window = 8
        ast_digest = instrument_policy(probe)
        rows = []; fixed = None
        for i in range(repeats):
            probe.reset(); torch.cuda.synchronize()
            if i == 3:
                fixed = artifacts(out)
            meter = Meter(observer if i >= 3 else 'off')
            probe.ctx['_cost_meter'] = meter
            begin = time.perf_counter_ns()
            for _ in range(10):
                world = probe.world_update(meter)
            metrics = [*world,*probe.actor_update(meter)]
            submitted = time.perf_counter_ns(); torch.cuda.synchronize(); end = time.perf_counter_ns()
            rows.append(dict(iteration=i,steady=i>=3,wall_ms=(end-begin)/1e6,
                             host_call_ms=(submitted-begin)/1e6,drain_ms=(end-submitted)/1e6,
                             profile=meter.report(),metrics=metrics))
            assert torch.cuda.mem_get_info()[0] > 16*1024**3
            assert torch.cuda.max_memory_reserved() < 32*1024**3
            print('COST_ROW',i,rows[-1]['wall_ms'],flush=True)
        assert fixed is None or artifacts(out) == fixed, 'steady compilation changed'
        actual = snapshot(probe,metrics)
        expected_path = (runs/'hotspot-shared-geometry-math-reference-gate-n' if control == 'corrected' else original_root)/'original-final.pt'
        if control == 'ieee' and ieee_reference:
            expected_path = Path(ieee_reference)/'original-final.pt'
        expected = torch.load(expected_path,map_location='cpu',weights_only=True,mmap=True)
        equality = {k:torch.equal(v,expected['tensors'][k]) for k,v in actual['tensors'].items()}
        # IEEE alone intentionally changes arithmetic from the old TF32 baseline.
        exact_required = control != 'ieee' or bool(ieee_reference)
        exact = all(equality.values()) and actual['normalizers']==expected['normalizers'] and metrics==expected['metrics']
        torch.save(actual,out/'original-final.pt')
        result = dict(schema='moonrobo.geometry-cost-probe.v1',control=control,observer=observer,
                      rows=rows,policy_ast_without_timing_sha256=ast_digest,
                      same_initial_state_each_repeat=True,artifacts_fixed_during_steady=True,
                      numerical_gate=dict(exact_required=exact_required,exact=exact,tensors=equality,reference=str(expected_path)),
                      passed=exact or not exact_required,
                      memory=dict(torch_allocated_peak_bytes=torch.cuda.max_memory_allocated(),torch_reserved_peak_bytes=torch.cuda.max_memory_reserved()))
        (out/'result.json').write_text(json.dumps(result,indent=2))
        assert result['passed'], 'timing instrumentation changed numerical result'
    decisions=json.loads((out/'frozen-decisions.json').read_text())
    assert not decisions['unknown'], 'unfrozen kernel choice'


if __name__ == '__main__':
    main()
