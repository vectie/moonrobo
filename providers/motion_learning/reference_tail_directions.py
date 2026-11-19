"""Physically compare saved full-return directions with new H32 prefix directions."""
import argparse
import copy
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch.nn.utils import parameters_to_vector

from cpu_physics import PhysicsRuntime
from dynamics import load_model
from reference_actor import load_reference_actor, load_references
from reference_learning import imagined_objective, state_digest, take
from reference_root_integration import archived_batch, apply_direction, digest, probe_physics, raw_means
from reference_task import ReferenceSchedule
from root_integrated_dynamics import load_root_integrated


class PrefixOnlyValue(torch.nn.Module):
    def forward(self, state, *args): return state[:, 0]*0


def inherited_record(record, source):
    result = copy.deepcopy(record)
    result["file"] = str(source/record["file"])
    result["behavior"]["checkpoint"] = str(source/record["behavior"]["checkpoint"])
    if "direction_file" in result["behavior"]:
        result["behavior"]["direction_file"] = str(source/record["behavior"]["direction_file"])
    return result


def run(args):
    started = time.perf_counter(); output = Path(args.output).resolve(); model_source = Path(args.models).resolve()
    config = json.loads((output/"config.json").read_bytes())
    if digest(model_source/"report.json") != config["model_source_report_sha256"]: raise ValueError("model study changed")
    previous = json.loads((model_source/"report.json").read_bytes()); source = Path(previous["source_study"])
    if digest(source/"report.json") != config["source_report_sha256"]: raise ValueError("physical source study changed")
    source_report = json.loads((source/"report.json").read_bytes()); learning = source_report["config"]
    torch.set_num_threads(learning["cpu_threads"]); torch.use_deterministic_algorithms(True)
    actor, geometry, _ = load_reference_actor(output/"initial/actor-zero-output.pt")
    base = parameters_to_vector(actor.parameters()).detach().clone()
    base_hash = digest(output/"initial/actor-zero-output.pt")
    if base_hash != source_report["initialization_sha256"]: raise ValueError("incoming actor changed")
    _, references = load_references(previous["references"])
    schedule = ReferenceSchedule(references, geometry, [0]); runtime = PhysicsRuntime(args.scene)
    baseline_returns = previous["baseline_returns"]
    records = [inherited_record(r, model_source) for r in previous["physical_records"]]
    rows = []
    for old in previous["runs"]:
        reused = copy.deepcopy(old); reused["tail_mode"] = "with-tail"; reused["new_model_updates"] = 0
        for key in ["checkpoint", "direction_file"]: reused[key] = str(model_source/old[key])
        reused["physics_reused"] = True; rows.append(reused)
        seed, variant = old["seed"], old["variant"]
        model_path = model_source/old["checkpoint"]
        if digest(model_path) != old["checkpoint_sha256"]: raise ValueError("frozen model changed")
        model, metadata = (load_root_integrated if variant=="root-integrated" else load_model)(model_path)
        for p in model.parameters(): p.requires_grad_(False); p.grad = None
        before = state_digest(model)
        if metadata["training_episode_ids"] != [r["episode_id"] for r in old["training_records"]]:
            raise ValueError("model training data differ from common collection")
        apply_direction(actor, base, torch.zeros_like(base), 0.)
        training = archived_batch(source, old["training_records"], actor, schedule)
        starts = torch.tensor([0]+list(np.cumsum(training["episode_lengths"])[:-1]))
        first = take(training, starts)
        probes = take(first, torch.tensor(config["probe_clip_indices"]))
        actor.zero_grad(set_to_none=True)
        objective, _ = imagined_objective(model, actor, PrefixOnlyValue(), first, geometry, schedule, learning)
        objective.backward()
        direction = torch.cat([(p.grad if p.grad is not None else torch.zeros_like(p)).flatten() for p in actor.parameters()]).detach()
        norm = float(direction.norm())
        if not torch.isfinite(direction).all() or norm <= 0: raise ValueError("invalid prefix direction")
        direction /= norm
        initial_mean = raw_means(actor, training)
        apply_direction(actor, base, direction, .001)
        response = float((raw_means(actor, training)-initial_mean).square().mean().sqrt())/.001
        apply_direction(actor, base, direction, 0.)
        if response < 1e-8: raise ValueError("uncalibrated prefix direction")
        direction_file = output/f"direction-{variant}-prefix-only-seed-{seed}.pt"
        torch.save(dict(format="moonrobo.g1-reference-parameter-direction.v1", direction=direction,
            base_actor_sha256=base_hash, parameter_names=[n for n, _ in actor.named_parameters()],
            gradient_norm=norm, calibration_response=response), direction_file)
        with torch.no_grad(): predicted_before = float(imagined_objective(model, actor, PrefixOnlyValue(), probes, geometry, schedule, learning)[0])
        outcomes = []
        for amplitude in config["logit_rms_steps"]:
            for sign in config["probe_signs"]:
                amount = sign*amplitude/response
                apply_direction(actor, base, direction, amount)
                achieved = float((raw_means(actor, training)-initial_mean).square().mean().sqrt())
                with torch.no_grad(): predicted_after = float(imagined_objective(model, actor, PrefixOnlyValue(), probes, geometry, schedule, learning)[0])
                behavior = dict(checkpoint="initial/actor-zero-output.pt", sha256=base_hash,
                    direction_file=direction_file.name, direction_sha256=digest(direction_file), coefficient=amount)
                role = f"{variant}-prefix-only-amp-{amplitude}-sign-{sign}"
                fresh, trials, returns = probe_physics(runtime, references, schedule, actor, geometry, learning,
                    seed, role, output, behavior, config["probe_clip_indices"])
                records += fresh
                outcomes.append(dict(logit_rms_target=amplitude, sign=sign, coefficient=amount,
                    achieved_logit_rms=achieved, predicted_return_before=predicted_before,
                    predicted_return_after=predicted_after, predicted_change=predicted_after-predicted_before,
                    trials=trials, returns=returns,
                    prefix_change_mean=float(np.mean([r["prefix_return"]-b["prefix_return"] for r, b in zip(returns, baseline_returns)])),
                    full_change_mean=float(np.mean([r["full_return"]-b["full_return"] for r, b in zip(returns, baseline_returns)]))))
        if state_digest(model) != before or any(p.grad is not None for p in model.parameters()):
            raise ValueError("prefix probe changed the model")
        row = {**copy.deepcopy(reused), "tail_mode": "prefix-only", "physics_reused": False,
            "direction_file": direction_file.name, "direction_sha256": digest(direction_file),
            "gradient_norm": norm, "calibration_response": response, "outcomes": outcomes,
            "critic_used": False, "frozen_model_unchanged": True}
        rows.append(row)
        print(json.dumps(dict(event="prefix-finished", variant=variant, seed=seed,
            changes=[dict(amplitude=o["logit_rms_target"], sign=o["sign"], prefix=o["prefix_change_mean"], full=o["full_change_mean"]) for o in outcomes])), flush=True)
    report = dict(format="moonrobo.g1-reference-tail-directions.v1", config=config, source_study=str(source),
        model_source_study=str(model_source), references=previous["references"],
        reference_manifest_sha256=previous["reference_manifest_sha256"],
        baseline_trials=previous["baseline_trials"], baseline_returns=baseline_returns, runs=rows, physical_records=records,
        reused_physical_records=len(previous["physical_records"]), new_physical_records=len(records)-len(previous["physical_records"]),
        provider_sha256=digest(__file__), provider_seconds=time.perf_counter()-started,
        physical_execution_allowed=False, release_qualified=False,
        scope="Paired local physical gradient diagnostics from frozen models; no training, selection, quality pass, new reference coverage or cost-to-target claim")
    (output/"report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["models", "scene", "output"]: parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
