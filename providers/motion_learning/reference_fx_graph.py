"""Read the restricted, tensor-only FX listing produced by pinned Inductor.

No source execution: reconstruct only ATen/prims calls, tuple indexing and the
original dataflow. Liveness-clearing assignments are ignored. Output None
slots are optionally removed for the native first-order autograd interface.
"""
import ast
import operator
import torch


def read_graph(source, *, filter_none=False, scalar_bindings=None):
    # Inductor uses this display-only class label in inference listings.
    if source.startswith('class <lambda>('):source=source.replace('class <lambda>(', 'class ReferenceGraph(', 1)
    fn=next(n for n in ast.walk(ast.parse(source)) if isinstance(n,ast.FunctionDef) and n.name=='forward')
    graph=torch.fx.Graph()
    names=[a.arg for a in fn.args.args if a.arg!='self']
    scalar_bindings={} if scalar_bindings is None else scalar_bindings
    assert set(scalar_bindings)<=set(names) and all(type(v) is int for v in scalar_bindings.values())
    env={name:scalar_bindings[name] if name in scalar_bindings else graph.placeholder(name) for name in names}
    names=[name for name in names if name not in scalar_bindings]
    def value(node):
        if isinstance(node,ast.Name):
            return env[node.id] if node.id in env else {'torch':torch,'inf':float('inf'),'nan':float('nan')}[node.id]
        if isinstance(node,ast.Constant):return node.value
        if isinstance(node,ast.Attribute):return getattr(value(node.value),node.attr)
        if isinstance(node,ast.List):return [value(n) for n in node.elts]
        if isinstance(node,ast.Tuple):return tuple(value(n) for n in node.elts)
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,ast.USub):return -value(node.operand)
        if isinstance(node,ast.Subscript):return graph.call_function(operator.getitem,(value(node.value),value(node.slice)))
        if isinstance(node,ast.BinOp):
            op={ast.Add:operator.add,ast.Sub:operator.sub,ast.Mult:operator.mul,ast.FloorDiv:operator.floordiv}[type(node.op)]
            a,b=value(node.left),value(node.right)
            return op(a,b) if type(a) is int and type(b) is int else graph.call_function(op,(a,b))
        if isinstance(node,ast.Call):
            args=tuple(value(n) for n in node.args)
            kwargs={k.arg:value(k.value) for k in node.keywords}
            if ast.unparse(node.func)=='device':return torch.device(*args,**kwargs)
            assert ast.unparse(node.func).startswith(('torch.ops.aten.','torch.ops.prims.')),ast.unparse(node.func)
            return graph.call_function(value(node.func),args,kwargs)
        raise AssertionError(ast.dump(node))
    indices=None
    for node in fn.body:
        if isinstance(node,(ast.Assign,ast.AnnAssign)):
            if isinstance(node.value,ast.Constant) and node.value.value is None:continue
            targets=node.targets if isinstance(node,ast.Assign) else [node.target]
            assert len(targets)==1 and isinstance(targets[0],ast.Name) and targets[0].id not in env
            env[targets[0].id]=value(node.value)
        elif isinstance(node,ast.Return):
            outputs=value(node.value)
            assert isinstance(outputs,tuple)
            indices=[i for i,v in enumerate(outputs) if v is not None]
            graph.output(tuple(outputs[i] for i in indices) if filter_none else outputs)
        else:raise AssertionError(ast.dump(node))
    assert indices is not None
    result=torch.fx.GraphModule(torch.nn.Module(),graph)
    result.graph.lint()
    return result,names,indices
