"""Same-trajectory diagnostic for the original compiled SMC reward boundary.

No training timing is measured. Recorded native state/action tensors must
already match SMC bitwise; the compiled reward is checked against its original
snapshot before comparing eager arithmetic or newly exposed reward terms.
"""
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import torch
from shared_smc_probe_bf16_original import SharedProbe


def stats(a, b):
    assert a.shape == b.shape
    a, b = a.detach().float().cpu(), b.detach().float().cpu()
    d = (a-b).abs()
    return dict(shape=list(a.shape), unequal=int((a != b).sum()),
                violations=int((d > 2e-6+2e-4*b.abs()).sum()), max_abs=float(d.max()))


def main():
    out = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    root = Path("/workspace/moonrobo/runs/hotspot-shared-actor-step-native-d")
    reference = Path("/workspace/moonrobo/runs/hotspot-shared-actor-boundary-smc-b")
    probe = SharedProbe(Path(os.environ["MOONROBO_SHARED_INPUT"]), compiled=True)
    probe.prepare_actor()
    indices = {directory: {r["name"]: r["blob"] for r in json.loads((directory/"boundaries.json").read_text())["records"]}
               for directory in (root, reference)}

    def read(directory, name):
        blob = indices[directory][name]
        path = directory/blob["file"]
        assert path.parent == directory and path.stat().st_size == int(blob["count"])*8
        with path.open("rb") as f:
            assert hashlib.file_digest(f, "sha256").hexdigest() == blob["sha256"]
        return torch.from_numpy(np.array(np.memmap(path, mode="r", dtype="<f8"))).float().reshape(blob["shape"])

    components = []
    for key in ("p", "r", "v", "w", "q", "qd"):
        rows = []
        for t in range(32):
            a, b = read(root, f"step-{t}-{key}"), read(reference, f"step-{t}-{key}")
            assert torch.equal(a, b)
            rows.append(a)
        components.append(torch.cat(rows).cuda().requires_grad_())
    actions = []
    for t in range(32):
        a, b = read(root, f"step-{t}-action"), read(reference, f"step-{t}-action")
        assert torch.equal(a, b)
        actions.append(a)
    action = torch.cat(actions).cuda().requires_grad_()
    previous = torch.cat([probe.previous, action[:-4096].detach()]).requires_grad_()
    frame = torch.arange(4096, 33*4096, device="cuda")
    actual = probe.ctx["reward_term"](tuple(components), frame, action, previous)
    compiled = [v.detach().cpu() for v in actual]
    del actual
    smc_r, native_r = read(reference, "rewards").flatten(), read(root, "rewards").flatten()
    original_control = stats(compiled[0], smc_r)
    assert original_control["unequal"] == 0, "compiled reward did not reproduce the original wrapper"
    with torch.no_grad():
        eager_r, terms = probe.ctx["mdp"].reward(tuple(components), frame, action, previous, terms=True)
        eager_d = probe.ctx["mdp"].soft_termination(tuple(components), frame)
    # Source-level layout control: SMC indexes [3,3]/[3,1] constants,
    # whereas native geometry uses leading singleton broadcast dimensions.
    # Verify the resulting arithmetic; do not assume these matmuls round alike.
    mdp, motion = probe.ctx["mdp"], probe.ctx["motion"]
    reference_state = tuple(torch.cat([probe.read(f"reference-{t}-{key}") for t in range(33)])
                            for key in ("p", "r", "v", "w", "q", "qd"))
    old_bodies = (motion.body_p, motion.body_R, motion.body_v, motion.body_w)
    controls = {}
    old_tf32 = torch.backends.cuda.matmul.allow_tf32
    try:
        with torch.no_grad():
            torch.backends.cuda.matmul.allow_tf32 = False
            controls["tf32_off_robot_only"] = stats(mdp.reward(tuple(components), frame, action, previous), native_r)
            motion.body_p, motion.body_R, motion.body_v, motion.body_w = mdp.kin.forward(*reference_state)
            controls["tf32_off_robot_and_reference"] = stats(mdp.reward(tuple(components), frame, action, previous), native_r)
    finally:
        torch.backends.cuda.matmul.allow_tf32 = old_tf32
        motion.body_p, motion.body_R, motion.body_v, motion.body_w = old_bodies
    class BatchedConstants:
        def __init__(self, value): self.value = value
        def __getitem__(self, index): return self.value[index].unsqueeze(0)
    kin = mdp.kin
    constants = (kin.off_p, kin.off_R, kin.axes)
    try:
        kin.off_p, kin.off_R, kin.axes = [BatchedConstants(v) for v in constants]
        with torch.no_grad():
            controls["batched_constants_robot_only"] = stats(mdp.reward(tuple(components), frame, action, previous), native_r)
            motion.body_p, motion.body_R, motion.body_v, motion.body_w = kin.forward(*reference_state)
            controls["batched_constants_robot_and_reference"] = stats(mdp.reward(tuple(components), frame, action, previous), native_r)
    finally:
        kin.off_p, kin.off_R, kin.axes = constants
        motion.body_p, motion.body_R, motion.body_v, motion.body_w = old_bodies
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0] > 16*1024**3 and torch.cuda.max_memory_reserved() < 32*1024**3
    result = dict(diagnostic_only=True, state_action_bitwise_verified=True,
                  original_compiled_control=original_control,
                  compiled_vs_native=stats(compiled[0], native_r),
                  eager_vs_native=stats(eager_r, native_r),
                  eager_vs_compiled=stats(eager_r, compiled[0]),
                  termination_eager_vs_compiled=stats(eager_d, compiled[1]),
                  source_layout_controls=controls,
                  peak_reserved=torch.cuda.max_memory_reserved())
    torch.save({k: v.detach().cpu() for k, v in terms.items()}, out/"eager-reward-terms.pt")
    (out/"result.json").write_text(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
