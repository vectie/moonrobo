"""Compare already-generated actor backward ATen graphs, with input renaming.

Pure compiler analysis: no training, graph rewriting, or remote execution.
"""
import ast
import json
from pathlib import Path


RENAMES={'primals_16':'primals_47','primals_27':'primals_2','primals_35':'primals_51',
         'primals_38':'primals_34','primals_39':'primals_35','primals_42':'primals_38',
         'primals_43':'primals_39','primals_46':'primals_42','primals_47':'primals_43',
         'primals_50':'primals_53'}


class Rename(ast.NodeTransformer):
    def visit_Name(self,node):
        return ast.copy_location(ast.Name(id=RENAMES.get(node.id,node.id),ctx=node.ctx),node)


def equations(path,rename=False):
    tree=ast.parse(path.read_text())
    function=next(n for n in ast.walk(tree) if isinstance(n,ast.FunctionDef) and n.name=='forward')
    result={}
    for n in function.body:
        if isinstance(n,(ast.Assign,ast.AnnAssign)):
            if isinstance(n.value,ast.Constant) and n.value.value is None:continue
            key=n.target.id if isinstance(n,ast.AnnAssign) else n.targets[0].id
            value=Rename().visit(n.value) if rename else n.value
            result[key]=ast.unparse(value)
        elif isinstance(n,ast.Return):
            result['RETURN']=[ast.unparse(v) for v in n.value.elts if not isinstance(v,ast.Constant) or v.value is not None]
        else:raise AssertionError(ast.dump(n))
    return result


if __name__=='__main__':
    root=Path('output/spark-runtime-20261024/actor-backward-boundaries-20261029-a')
    original=equations(root/'postgrad-fx-a/recurrent-backward.fx.py',True)
    native=equations(root/'generated-code-a/native-recurrent-backward.fx.txt')
    print(json.dumps(dict(comparison='original post-grad FX vs retained native pre-padding backward',
        original_nodes=len(original)-1,native_nodes=len(native)-1,
        differences=[dict(node=k,original=original.get(k),native=native.get(k)) for k in sorted(original.keys()|native.keys()) if original.get(k)!=native.get(k)]),indent=2))
