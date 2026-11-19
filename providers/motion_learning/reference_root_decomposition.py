"""Post-hoc prefix/tail derivative decomposition along already-tested directions.

No new fits, directions, checkpoints or physical trajectories are selected.
Physical central secants at two finite amplitudes are not exact derivatives.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import torch
from torch.nn.utils import parameters_to_vector, vector_to_parameters

from dynamics import load_model
from reference_actor import load_reference_actor, load_references
from reference_learning import imagined_objective, state_digest, take
from reference_root_integration import archived_batch, digest, load_value
from reference_task import ReferenceSchedule
from root_integrated_dynamics import load_root_integrated


class ZeroTail(torch.nn.Module):
    def forward(self, state, *args): return state[:, 0]*0


def run(args):
    folder = Path(args.study); report = json.loads((folder/"report.json").read_bytes())
    source = Path(report["source_study"])
    learning = json.loads((source/"report.json").read_bytes())["config"]
    torch.set_num_threads(learning["cpu_threads"])
    _, references = load_references(report["references"])
    results = []
    for row in report["runs"]:
        actor, geometry, _ = load_reference_actor(folder/"initial/actor-zero-output.pt")
        schedule = ReferenceSchedule(references, geometry, [0])
        training = archived_batch(source, row["training_records"], actor, schedule)
        starts = torch.tensor([0]+list(np.cumsum(training["episode_lengths"])[:-1]))
        batch = take(training, starts[report["config"]["probe_clip_indices"]])
        loader = load_root_integrated if row["variant"]=="root-integrated" else load_model
        model, _ = loader(folder/row["checkpoint"])
        value, _ = load_value(source, row["seed"], actor)
        direction = torch.load(folder/row["direction_file"], weights_only=True)["direction"].double()/row["calibration_response"]
        actor.double(); geometry.double(); model.double(); value.double()
        for key in ["goals", "positions", "quaternions"]: setattr(schedule, key, getattr(schedule, key).double())
        schedule.reference_features = {k: v.double() for k, v in schedule.reference_features.items()}
        batch = {k: v.double() if v.is_floating_point() else v for k, v in batch.items()}
        for module in [model, value]:
            for p in module.parameters(): p.requires_grad_(False); p.grad = None
        unchanged = (state_digest(model), state_digest(value))
        base = parameters_to_vector(actor.parameters()).detach().clone()
        parts = {}
        for name, critic in [("prefix", ZeroTail()), ("full", value)]:
            objective, active = imagined_objective(model, actor, critic, batch, geometry, schedule, learning)
            grad = torch.autograd.grad(objective, tuple(actor.parameters()), allow_unused=True)
            vector = torch.cat([(g if g is not None else torch.zeros_like(p)).flatten() for p, g in zip(actor.parameters(), grad)])
            analytic = float((vector*direction).sum())
            sweep = []
            for epsilon in [1e-6, 1e-7, 1e-8]:
                with torch.no_grad():
                    vector_to_parameters(base+epsilon*direction, actor.parameters())
                    plus, plus_active = imagined_objective(model, actor, critic, batch, geometry, schedule, learning)
                    vector_to_parameters(base-epsilon*direction, actor.parameters())
                    minus, minus_active = imagined_objective(model, actor, critic, batch, geometry, schedule, learning)
                    vector_to_parameters(base.clone(), actor.parameters())
                numeric = float((plus-minus)/(2*epsilon))
                sweep.append(dict(epsilon=epsilon, derivative=numeric, absolute_error=abs(analytic-numeric),
                    base_active_steps=active, plus_active_steps=plus_active, minus_active_steps=minus_active))
            numeric = sweep[-1]["derivative"]
            parts[name] = dict(value=float(objective.detach()), derivative_per_raw_logit_rms=analytic,
                finite_difference_derivative=numeric, absolute_error=abs(analytic-numeric),
                step_size_sweep=sweep, autodiff_consistent=abs(analytic-numeric)<1e-4+1e-3*abs(numeric))
        secants = []
        for amplitude in report["config"]["logit_rms_steps"]:
            plus = next(o for o in row["outcomes"] if o["sign"]==1 and o["logit_rms_target"]==amplitude)
            minus = next(o for o in row["outcomes"] if o["sign"]==-1 and o["logit_rms_target"]==amplitude)
            secants.append(dict(logit_rms_amplitude=amplitude,
                physical_prefix_secant=(plus["prefix_change_mean"]-minus["prefix_change_mean"])/(2*amplitude),
                physical_full_secant=(plus["full_change_mean"]-minus["full_change_mean"])/(2*amplitude)))
        frozen = unchanged==(state_digest(model), state_digest(value))
        if not frozen: raise ValueError("decomposition changed model/value")
        results.append(dict(seed=row["seed"], variant=row["variant"], parts=parts,
            tail_derivative_per_raw_logit_rms=parts["full"]["derivative_per_raw_logit_rms"]-parts["prefix"]["derivative_per_raw_logit_rms"],
            physical_secants=secants, frozen_model_value_unchanged=frozen,
            model_sha256=digest(folder/row["checkpoint"]), direction_sha256=row["direction_sha256"]))
    result = dict(format="moonrobo.g1-reference-root-decomposition.v1", results=results,
        source_report_sha256=digest(folder/"report.json"), provider_sha256=digest(__file__),
        scope="Post-hoc decomposition of existing directions on three known reset clips. Finite physical secants are not exact derivatives. No tail-free actor direction was physically tested.",
        physical_execution_allowed=False)
    (folder/"gradient-decomposition.json").write_text(json.dumps(result, indent=2, allow_nan=False))
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--study", required=True)
    run(parser.parse_args())
