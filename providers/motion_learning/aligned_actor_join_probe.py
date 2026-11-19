"""Observe actual actor cotangents after the ten numerically aligned world updates."""
import hashlib
import json
import os
from pathlib import Path

import torch
import aligned_training_reference_s as reference
from actor_frozen_reference_h import observe_adjoints


def main():
    root=Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    original_class=reference.SharedProbe;instances=[]
    class Probe(original_class):
        def prepare_actor(self):
            super().prepare_actor()
            self.capture=observe_adjoints(self)
            instances.append(self)
    reference.SharedProbe=Probe
    try:
        reference.main()
    except AssertionError as error:
        assert str(error)=='complete coupled training update numerical gate failed'
    finally:
        reference.SharedProbe=original_class
    assert len(instances)==1
    captured=instances[0].capture
    for handle in captured.pop('handles'):handle.remove()
    assert captured['order']==list(range(31,-1,-1)) and len(captured['steps'])==32
    captured['upstream_source']='original node prehook'
    torch.save(captured,root/'original-adjoints.pt')
    assert (root/'original-adjoints.pt').stat().st_size<2*1024**3
    reference_root=Path('/workspace/moonrobo/runs/hotspot-shared-training-smc-gate-t')
    report=json.loads((reference_root/'result.json').read_text())
    path=reference_root/report['final_snapshot']['file']
    with path.open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==report['final_snapshot']['sha256']
    old=torch.load(path,map_location='cpu',weights_only=True,mmap=True)
    new=torch.load(root/'original-final.pt',map_location='cpu',weights_only=True,mmap=True)
    assert old['tensors'].keys()==new['tensors'].keys()
    differences={k:int(torch.count_nonzero(old['tensors'][k]!=v)) for k,v in new['tensors'].items()}
    assert not any(differences.values()),'observer changed reference update'
    (root/'observer-control.json').write_text(json.dumps(dict(actual_final_tensors_bitwise_equal=True,records=len(differences),step_order=captured['order']),indent=2))


if __name__=='__main__':main()
