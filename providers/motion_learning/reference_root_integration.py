"""Paired numerical fits and actual physics probes of a root integration hypothesis."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch.nn.utils import parameters_to_vector, vector_to_parameters

from cpu_physics import PhysicsRuntime
from dynamics import imagine
from reference_actor import load_reference_actor, load_references
from reference_learning import ReferenceModelReplay, collect_episode, imagined_objective, join_batches, state_digest, take
from reference_task import ReferenceSchedule, ReferenceValue
from root_integrated_dynamics import RootIntegratedDynamics, load_root_integrated


def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def archived_batch(folder, records, actor, schedule):
    batches = []
    for record in records:
        path = folder/record["file"]
        if digest(path) != record["sha256"]: raise ValueError("source physics changed")
        with np.load(path, allow_pickle=False) as f: a = {k: torch.from_numpy(f[k]) for k in f.files}
        n = record["steps"]; obs = a["observation"]
        phases = torch.arange(n)+record["origin_step"]
        clips = torch.full((n,), record["clip_index"], dtype=torch.long)
        current, future, valid = schedule.command(clips, phases, actor.future_length)
        history = obs[(torch.arange(n)[:, None]-torch.arange(actor.history_length-1, -1, -1)[None]).clamp_min(0)]
        batches.append(dict(state=a["state"], next_state=a["next_state"], action=a["applied_action"],
            history=history, current=current, future=future, valid=valid,
            actual_features=a["actual_features"], reference_features=a["reference_features"],
            clip=clips, step=phases, origin=torch.full_like(phases, record["origin_step"]),
            remaining=schedule.length-phases,
            context=torch.tensor(record["context"], dtype=torch.float32)[None].expand(n, -1)))
    return join_batches(batches)


@torch.no_grad()
def prediction_metrics(model, batch):
    results = []
    for h in [8, 32]:
        sums = np.zeros(4); count = 0; first = 0
        for length in batch["episode_lengths"]:
            for offset in range(0, length-h+1, h//2):
                i = first+offset
                state, truth = batch["state"][i:i+1], batch["next_state"][i:i+h][None]
                prediction = imagine(model, state, batch["action"][i:i+h][None], batch["context"][i:i+1])
                sums += [float(((prediction-truth)/model.state_scale).square().mean()),
                    float(((state[:, None]-truth)/model.state_scale).square().mean()),
                    float((prediction[..., :3]-truth[..., :3]).square().mean()),
                    float((prediction[..., 36:39]-truth[..., 36:39]).square().mean())]
                count += 1
            first += length
        if not count: raise ValueError("missing diagnostic windows")
        results.append(dict(horizon=h, windows=count, normalized_state_mse=sums[0]/count,
            persistence_mse=sums[1]/count, root_position_component_rmse_m=float(np.sqrt(sums[2]/count)),
            root_linear_velocity_component_rmse_m_per_s=float(np.sqrt(sums[3]/count))))
    return results


@torch.no_grad()
def raw_means(actor, batch):
    return torch.cat([actor.latent_mean(batch["history"][i:i+256], batch["current"][i:i+256],
        batch["future"][i:i+256], batch["valid"][i:i+256]) for i in range(0, len(batch["state"]), 256)])


def load_value(source, seed, actor):
    path = source/f"model-based/seed-{seed}/policy/value-cycle-1.pt"
    data = torch.load(path, weights_only=True)
    state = data["state_dict"]
    value = ReferenceValue(actor, state["state_mean"], state["state_scale"], 9)
    value.load_state_dict(state)
    for p in value.parameters(): p.requires_grad_(False); p.grad = None
    return value, dict(file=str(path), sha256=digest(path), state_sha256=state_digest(value))


def apply_direction(actor, base, direction, amount):
    vector_to_parameters(base+amount*direction, actor.parameters())


def probe_physics(runtime, references, schedule, actor, geometry, config, seed, role, output, behavior, clips):
    records, trials, returns = [], [], []
    for clip in clips:
        batch, record, trial = collect_episode(runtime, references, schedule, actor, geometry, config,
            clip, 0, seed, 0, role, output, behavior)
        rewards = batch["reward"].double(); weights = config["gamma"]**torch.arange(len(rewards), dtype=torch.float64)
        returns.append(dict(clip_index=clip, prefix_return=float((rewards[:32]*weights[:32]).sum()),
            full_return=float((rewards*weights).sum())))
        records.append(record); trials.append(trial)
    print(json.dumps(dict(event="physics", role=role, seed=seed, returns=returns)), flush=True)
    return records, trials, returns


def run(args):
    started = time.perf_counter(); output = Path(args.output); source = Path(args.source)
    config = json.loads((output/"config.json").read_bytes())
    if digest(source/"report.json") != config["source_report_sha256"]: raise ValueError("wrong source study")
    source_report = json.loads((source/"report.json").read_bytes())
    source_charter = json.loads((source/"charter.json").read_bytes()); learning = source_report["config"]
    torch.set_num_threads(learning["cpu_threads"]); torch.use_deterministic_algorithms(True)
    actor, geometry, _ = load_reference_actor(output/"initial/actor-zero-output.pt")
    if digest(output/"initial/actor-zero-output.pt") != source_report["initialization_sha256"]: raise ValueError("incoming prior changed")
    _, references = load_references(source_charter["references"])
    if digest(Path(source_charter["references"])/"manifest.json") != source_report["reference_manifest_sha256"]:
        raise ValueError("reference manifest changed")
    schedule = ReferenceSchedule(references, geometry, [0]); runtime = PhysicsRuntime(args.scene)
    base = parameters_to_vector(actor.parameters()).detach().clone()
    common_behavior = dict(checkpoint="initial/actor-zero-output.pt", sha256=digest(output/"initial/actor-zero-output.pt"))
    records, baseline_trials, baseline_returns = probe_physics(runtime, references, schedule, actor, geometry,
        learning, 0, "baseline", output, common_behavior, config["probe_clip_indices"])
    rows = []
    for seed in config["seeds"]:
        selected = lambda role: [r for r in source_report["physical_records"] if r["seed"]==seed and r["role"]==role]
        training_records, diagnostic_records = selected("common-first-collection"), selected("model-diagnostic")
        training = archived_batch(source, training_records, actor, schedule)
        diagnostic = archived_batch(source, diagnostic_records, actor, schedule)
        starts = torch.tensor([0]+list(np.cumsum(training["episode_lengths"])[:-1]))
        first = take(training, starts)
        probe_starts = take(first, torch.tensor(config["probe_clip_indices"]))
        value, value_source = load_value(source, seed, actor)
        expected_value_hash = next(r for r in source_report["runs"] if r["seed"]==seed and r["method"]=="model-based")["cycles"][0]["critic"]["state_sha256"]
        if value_source["state_sha256"] != expected_value_hash: raise ValueError("critic differs from common fit")
        torch.manual_seed(config["model_seed_base"]+seed)
        shared = ReferenceModelReplay(training, {**learning, "model_updates_per_cycle": config["model_updates"]}, seed)
        initial_weights = copy.deepcopy(shared.model.state_dict()); initial_hash = state_digest(shared.model)
        for variant in config["variants"]:
            apply_direction(actor, base, torch.zeros_like(base), 0.)
            replay = copy.deepcopy(shared)
            if variant == "root-integrated":
                stats = {k: v for k, v in initial_weights.items() if k.endswith(("_mean", "_scale"))}
                replay.model = RootIntegratedDynamics(stats, learning["model_width"], schedule.dt)
                replay.model.load_state_dict(initial_weights)
                replay.optimizer = torch.optim.Adam(replay.model.parameters(), lr=learning["model_learning_rate"])
            if state_digest(replay.model) != initial_hash: raise ValueError("paired initial tensors differ")
            fit = replay.fit(); model = replay.model
            checkpoint = output/f"{variant}-seed-{seed}.pt"
            data = dict(model=model.state_dict(), training_episode_ids=[r["episode_id"] for r in training_records],
                source_report_sha256=config["source_report_sha256"], diagnostic_records_fitted=False)
            if variant == "root-integrated":
                data.update(format="moonrobo.g1-root-integrated-dynamics.v1", width=learning["model_width"], dt_s=schedule.dt)
            else: data.update(format="moonrobo.residual-dynamics.v2", config=dict(hidden_width=learning["model_width"], horizontal_translation_invariant=True))
            torch.save(data, checkpoint)
            if variant == "root-integrated":
                restored, _ = load_root_integrated(checkpoint)
                with torch.no_grad():
                    torch.testing.assert_close(restored(first["state"], training["action"][starts], first["context"]),
                        model(first["state"], training["action"][starts], first["context"]), atol=0, rtol=0)
            metrics = prediction_metrics(model, diagnostic)
            actor.zero_grad(set_to_none=True)
            objective, _ = imagined_objective(model, actor, value, first, geometry, schedule, learning)
            objective.backward()
            direction = torch.cat([(p.grad if p.grad is not None else torch.zeros_like(p)).flatten() for p in actor.parameters()]).detach()
            norm = float(direction.norm())
            if not torch.isfinite(direction).all() or norm <= 0: raise ValueError("invalid model direction")
            direction /= norm
            initial_mean = raw_means(actor, training)
            epsilon = .001
            apply_direction(actor, base, direction, epsilon)
            response = float((raw_means(actor, training)-initial_mean).square().mean().sqrt())/epsilon
            apply_direction(actor, base, direction, 0.)
            if response < 1e-8: raise ValueError("direction has no calibration response")
            direction_file = output/f"direction-{variant}-seed-{seed}.pt"
            torch.save(dict(format="moonrobo.g1-reference-parameter-direction.v1", direction=direction,
                base_actor_sha256=common_behavior["sha256"], parameter_names=[n for n, _ in actor.named_parameters()],
                gradient_norm=norm, calibration_response=response), direction_file)
            with torch.no_grad(): predicted_before = float(imagined_objective(model, actor, value, probe_starts, geometry, schedule, learning)[0])
            outcomes = []
            for amplitude in config["logit_rms_steps"]:
                for sign in config["probe_signs"]:
                    amount = sign*amplitude/response
                    apply_direction(actor, base, direction, amount)
                    achieved = float((raw_means(actor, training)-initial_mean).square().mean().sqrt())
                    with torch.no_grad(): predicted_after = float(imagined_objective(model, actor, value, probe_starts, geometry, schedule, learning)[0])
                    role = f"{variant}-amp-{amplitude}-sign-{sign}"
                    behavior = {**common_behavior, "direction_file": direction_file.name, "direction_sha256": digest(direction_file), "coefficient": amount}
                    fresh, trials, returns = probe_physics(runtime, references, schedule, actor, geometry, learning,
                        seed, role, output, behavior, config["probe_clip_indices"])
                    records += fresh
                    outcomes.append(dict(logit_rms_target=amplitude, sign=sign, coefficient=amount,
                        achieved_logit_rms=achieved, predicted_return_before=predicted_before,
                        predicted_return_after=predicted_after, predicted_change=predicted_after-predicted_before,
                        trials=trials, returns=returns,
                        prefix_change_mean=float(np.mean([r["prefix_return"]-b["prefix_return"] for r, b in zip(returns, baseline_returns)])),
                        full_change_mean=float(np.mean([r["full_return"]-b["full_return"] for r, b in zip(returns, baseline_returns)]))))
            rows.append(dict(seed=seed, variant=variant, initial_model_state_sha256=initial_hash, fit=fit,
                checkpoint=checkpoint.name, checkpoint_sha256=digest(checkpoint), critic=value_source,
                training_records=training_records, diagnostic_records=diagnostic_records, diagnostics=metrics,
                direction_file=direction_file.name, direction_sha256=digest(direction_file),
                gradient_norm=norm, calibration_response=response, outcomes=outcomes))
            print(json.dumps(dict(event="variant-finished", seed=seed, variant=variant, metrics=metrics)), flush=True)
    report = dict(format="moonrobo.g1-reference-root-integration.v1", config=config, source_study=str(source),
        references=source_charter["references"], reference_manifest_sha256=source_report["reference_manifest_sha256"],
        baseline_trials=baseline_trials, baseline_returns=baseline_returns, runs=rows, physical_records=records,
        provider_sha256=digest(__file__), provider_seconds=time.perf_counter()-started,
        physical_execution_allowed=False, release_qualified=False,
        scope="Paired offline fitting and local physical direction diagnostics; not policy training, qualification or cost-to-target")
    (output/"report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["source", "scene", "output"]: parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
