"""Hold compiled reward artifacts fixed; isolate measured native input differences."""
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import torch
from compiled_world_detail_d import Pair
from shared_smc_probe_bf16_original import SharedProbe


def main():
    out = Path(os.environ['MOONROBO_SHARED_OUTPUT'])
    runs = Path('/workspace/moonrobo/runs')
    probe = SharedProbe(Path(os.environ['MOONROBO_SHARED_INPUT']), compiled=False)
    probe.prepare_actor()
    def reader(root, manifest):
        records = {r['name']: r['blob'] for r in json.loads((root / manifest).read_text())['records']}
        def read(name):
            b = records[name]; p = root / b['file']
            assert p.parent == root and p.stat().st_size == int(b['count']) * 8
            with p.open('rb') as f:
                assert hashlib.file_digest(f, 'sha256').hexdigest() == b['sha256']
            return torch.from_numpy(np.array(np.memmap(p, mode='r', dtype='<f8'))).float().reshape(b['shape']).cuda()
        return read
    read = reader(runs / 'hotspot-shared-actor-frozen-reference-c', 'boundaries.json')
    read_input = reader(runs / 'hotspot-shared-actor-reference-inputs-a', 'inputs.json')
    p, r, v, w, q, qd = [torch.cat([read(f'step-{t}-{n}') for t in range(32)]) for n in ('p', 'r', 'v', 'w', 'q', 'qd')]
    actions = torch.cat([read(f'step-{t}-action') for t in range(32)])
    motion = probe.ctx['motion']; mdp = probe.ctx['mdp']; kin = mdp.kin
    args = [kin.off_p, r, p, kin.off_R, kin.axes, q, qd, w, v, motion.root_p,
            torch.arange(4096, 33*4096, device='cuda'), motion.root_R,
            motion.body_p, motion.body_R, motion.body_v, motion.body_w,
            actions, torch.cat([probe.previous, actions[:-4096]]), mdp.soft_hi, mdp.soft_lo]
    native_r = read_input('constant-1')
    native_v = torch.cat([read_input(f'frame-{t}').reshape(4096, 14, 18)[:, :, 12:15] for t in range(33)]).contiguous()
    pair = Pair(runs / 'hotspot-mlp-actor-reward-reference-b/reward')
    records = []
    def run(a):
        result = pair.forward(a)
        gradients = pair.backward([torch.ones_like(t) for t in result])
        saved = [t.detach().cpu().clone() for t in (*result, *gradients)]
        pair.values = []
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0] > 16*1024**3 and torch.cuda.max_memory_reserved() < 32*1024**3
        return saved
    original = run(args)
    labels = ['reward', 'failure'] + [f'gradient-{i}' for i in pair.manifest['gradient_indices']]
    for name, use_r, use_v in [('native-both', True, True), ('native-rotation-only', True, False), ('native-velocity-only', False, True), ('original-repeat', False, False)]:
        candidate = list(args)
        if use_r: candidate[3] = native_r
        if use_v: candidate[14] = native_v
        actual = run(candidate)
        for label, a, b in zip(labels, actual, original):
            d = (a-b).abs()
            records.append(dict(route=name, name=label, unequal=int((a!=b).sum()),
                                violations=int((d>2e-6+2e-4*b.abs()).sum()), max_abs=float(d.max())))
        (out/'progress.json').write_text(json.dumps(records, indent=2))
    (out/'result.json').write_text(json.dumps(dict(diagnostic_only=True, comparisons=records,
        scope='same reward forward/backward artifacts and unit cotangents; only observed off_R and reference velocity changed',
        peak_reserved=torch.cuda.max_memory_reserved()), indent=2))


if __name__ == '__main__':
    main()
