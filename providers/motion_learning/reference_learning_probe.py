"""One fixed float64 directional check of the complete imagined controller."""
import argparse
import copy
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from dynamics import load_model
from reference_actor import load_reference_actor, load_references
from reference_learning import imagined_objective, state_digest
from reference_task import ReferenceSchedule, ReferenceValue


def run(args):
    folder = Path(args.study)
    report = json.loads((folder/"report.json").read_bytes())
    charter = json.loads((folder/"charter.json").read_bytes())
    config = report["config"]
    torch.set_num_threads(config["cpu_threads"])
    method = args.method
    config = {**config, "actor_critic_tail": method=="model-based"}
    selected = next(r for r in report["runs"] if r["method"]==method and r["seed"]==0)
    actor_path = folder/selected["checkpoint"]["checkpoint"]
    if hashlib.sha256(actor_path.read_bytes()).hexdigest() != selected["checkpoint"]["sha256"]:
        raise ValueError("probe actor differs from the fixed final checkpoint")
    actor, geometry, _ = load_reference_actor(actor_path)
    final_cycle = selected["cycles"][-1]["cycle"]
    model, _ = load_model(actor_path.parent/f"dynamics-cycle-{final_cycle}.pt")
    value_data = torch.load(actor_path.parent/f"value-cycle-{final_cycle}.pt", weights_only=True)
    value = ReferenceValue(actor, value_data["state_dict"]["state_mean"], value_data["state_dict"]["state_scale"], 9)
    value.load_state_dict(value_data["state_dict"])
    _, references = load_references(charter["references"])
    record = next(r for r in report["physical_records"] if r["role"]=="common-first-collection" and r["seed"]==0 and r["clip_index"]==0)
    schedule = ReferenceSchedule(references, geometry, [record["origin_step"]])
    with np.load(folder/record["file"], allow_pickle=False) as archive: a = dict(archive)
    offset = args.offset
    if not 0 <= offset < record["steps"]: raise ValueError("probe offset outside its physical episode")
    clips, phases = torch.tensor([0]), torch.tensor([record["origin_step"]+offset])
    current, future, valid = schedule.command(clips, phases, actor.future_length)
    history_indices = (offset-torch.arange(actor.history_length-1, -1, -1)).clamp_min(0)
    batch = dict(state=torch.from_numpy(a["state"][offset:offset+1]),
        history=torch.from_numpy(a["observation"])[history_indices][None],
        current=current, future=future, valid=valid,
        actual_features=torch.from_numpy(a["actual_features"][offset:offset+1]), reference_features=torch.from_numpy(a["reference_features"][offset:offset+1]),
        clip=clips, step=phases, origin=torch.full_like(phases, record["origin_step"]), remaining=schedule.length-phases,
        context=torch.tensor(record["context"], dtype=torch.float32)[None])
    actor.double(); model.double(); value.double(); geometry.double()
    for key in ["goals", "positions", "quaternions"]: setattr(schedule, key, getattr(schedule, key).double())
    schedule.reference_features = {key: item.double() for key, item in schedule.reference_features.items()}
    batch = {key: item.double() if item.is_floating_point() else item for key, item in batch.items()}
    for module in [actor, model, value]:
        for parameter in module.parameters(): parameter.requires_grad_(False); parameter.grad = None
    bias = actor.decoder[-1].bias
    bias.requires_grad_(True)
    before_model, before_value = state_digest(model), state_digest(value)
    objective, _ = imagined_objective(model, actor, value, batch, geometry, schedule, config)
    gradient, = torch.autograd.grad(objective, bias)
    direction = torch.linspace(-1, 1, len(bias), dtype=torch.float64)
    original = bias.detach().clone(); epsilon = 1e-6
    with torch.no_grad():
        bias.copy_(original+epsilon*direction)
        plus, _ = imagined_objective(model, actor, value, batch, geometry, schedule, config)
        bias.copy_(original-epsilon*direction)
        minus, _ = imagined_objective(model, actor, value, batch, geometry, schedule, config)
        bias.copy_(original)
    analytic = float((gradient*direction).sum()); numeric = float((plus-minus)/(2*epsilon))
    passed = bool(torch.isfinite(gradient).all() and gradient.norm()>0 and
        abs(analytic-numeric) < 1e-5+1e-3*abs(numeric) and state_digest(model)==before_model and
        state_digest(value)==before_value and all(p.grad is None for p in model.parameters()))
    result = dict(format="moonrobo.g1-reference-imagination-gradient.v1", passed=passed, method=method,
        source_record=record["episode_id"], source_offset_steps=offset, checkpoint_cycle=final_cycle, horizon=config["imagination_horizon"],
        precision="float64 check of float32 learned artifacts and recorded origin",
        analytic_directional=analytic, finite_difference_directional=numeric,
        absolute_error=abs(analytic-numeric), gradient_norm=float(gradient.norm()),
        frozen_model_value_unchanged=state_digest(model)==before_model and state_digest(value)==before_value,
        critic_tail_used=config["actor_critic_tail"],
        scope="Autodiff consistency through world model, restored policy history and causal EMA"+
            (" and physical-return critic tail" if config["actor_critic_tail"] else " with no critic tail")+"; not a physical-Jacobian accuracy test",
        physical_execution_allowed=False)
    name = "gradient-verification.json" if method=="model-based" else f"gradient-verification-{method}.json"
    (folder/name).write_text(json.dumps(result, indent=2, allow_nan=False))
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--study", required=True)
    parser.add_argument("--method", choices=["model-based", "prefix-only", "replay-prefix", "replay-prefix-extended", "replay-prefix-anchor"], default="model-based")
    parser.add_argument("--offset", type=int, default=0)
    run(parser.parse_args())
