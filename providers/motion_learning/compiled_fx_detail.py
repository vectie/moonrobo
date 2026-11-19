"""Static compiler-IR diagnostic. Parses FX source without executing it.

This comparison aligns the known saved-input names of this fixed world export.
It is not a general graph-equivalence proof and performs no deployment/actions.
"""
import ast
import json
import sys
from pathlib import Path


class RenameInputs(ast.NodeTransformer):
    mapping = {"primals_6":"primals_8", "primals_7":"primals_9",
               "primals_10":"primals_12", "primals_11":"primals_13",
               "primals_14":"primals_16", "primals_15":"primals_17",
               "primals_19":"primals_5", "primals_21":"primals_20"}

    def visit_Name(self, node):
        return ast.copy_location(ast.Name(id=self.mapping.get(node.id, node.id), ctx=node.ctx), node)


def expressions(path, rename=False):
    tree = ast.parse(Path(path).read_text())
    if rename:
        tree = RenameInputs().visit(tree)
    result = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0], ast.Name):
            key, value = node.targets[0].id, node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            key, value = node.target.id, node.value
        else:
            continue
        if isinstance(value, ast.Call):
            result[key] = ast.unparse(value)
    return result


def main():
    native, smc = expressions(sys.argv[1], True), expressions(sys.argv[2])
    mismatches = [dict(node=k, native=v, smc=smc[k]) for k,v in native.items() if k in smc and smc[k]!=v]
    print(json.dumps(dict(scope="name-aligned raw FX expressions; not equivalence proof",
        native_nodes=len(native),smc_nodes=len(smc),
        same_expressions=sum(v==smc.get(k) for k,v in native.items()),
        mismatches=mismatches, only_native=[k for k in native if k not in smc],
        only_smc=[k for k in smc if k not in native]), indent=2))


if __name__ == "__main__":
    main()
