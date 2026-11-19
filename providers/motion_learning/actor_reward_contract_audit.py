"""Read-only generated-code identity audit; never imports a numerical runtime."""
import hashlib
import json
import sys
from pathlib import Path
from frozen_training_kernels_ab import contract, sources


def main():
    runs=Path('/home/wlc004s/moonrobo/runs')
    original=runs/'hotspot-shared-original-actor-fx-b/compile-debug/torchinductor/model__2_backward_9.3/output_code.py'
    source={name:contract(code) for name,code in sources(original)}
    root=runs/'hotspot-shared-training-smc-gate-t'
    paths={hashlib.sha256(p.read_bytes()).hexdigest():p for p in (root/'inductor-cache').rglob('*.py')}
    choices=json.loads((runs/'hotspot-mlp-actor-reward-reference-b/backward-choices.json').read_text())['smc_loaded_kernels']
    parsed={};rows=[]
    for row in json.loads((root/'result.json').read_text())['launched']:
        name=row['kernel']
        if name not in source:continue
        digest=row['module_sha256']
        if digest not in parsed:parsed[digest]=dict(sources(paths[digest]))
        current=contract(parsed[digest][name]);old=source[name]
        rows.append(dict(name=name,file=str(paths[digest]),body_equal=current[1]==old[1],hints_equal=current[2]==old[2],
                         old_config=choices[name]['configs'],actual_config=row['configs'],original_hints=old[2],actual_hints=current[2]))
    matched=[row for row in rows if row['body_equal'] and row['hints_equal']]
    result=dict(matched=matched,unmatched_original_names=sorted(set(source)-{row['name'] for row in matched}),candidates=rows)
    Path(sys.argv[1]).write_text(json.dumps(result,indent=2))


if __name__=='__main__':main()
