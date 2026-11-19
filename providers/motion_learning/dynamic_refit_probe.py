"""Compare refitted dynamics on the same saved temporal physics origins."""
import argparse
import copy
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from actor_update_probe import scaled_actor
from cpu_physics import PhysicsRuntime
from dynamics import load_model
from temporal_actor import load_temporal
from temporal_probe import adam_direction, command_schedule, imagined_returns, open_loop_errors, physical_return


def compare_one(runtime, model, actor, origins, baselines, config):
    tensor = lambda key: torch.tensor([o[key] for o in origins], dtype=torch.float32)
    goals = torch.tensor(np.asarray([command_schedule(runtime, o, config["horizon"] + actor.future_length + 1) for o in origins]))
    batch = tensor("state"), tensor("history"), goals, tensor("context")
    with torch.no_grad():
        before = imagined_returns(model, actor, batch, config).numpy()
    delta, norm = adam_direction(model, actor, batch, config)
    by_scale, predicted = {}, {}
    for scale in config["multipliers"]:
        candidate = scaled_actor(actor, delta, scale)
        with torch.no_grad():
            predicted[scale] = imagined_returns(model, candidate, batch, config).numpy()
        by_scale[scale] = [physical_return(runtime, o, candidate, config)[0] for o in origins] if scale else baselines
    records = []
    for scale, outcomes in by_scale.items():
        for i, outcome in enumerate(outcomes):
            records.append(dict(multiplier=scale, origin=i, predicted_before=float(before[i]), predicted_after=float(predicted[scale][i]),
                baseline=baselines[i], candidate=outcome))
    summaries = []
    scale = config["centered_scale"]
    for subset in ["all", "dynamic", "stand", "late"]:
        ids = [i for i, o in enumerate(origins) if subset == "all" or
            subset == "dynamic" and o["case"]["motion"] == "random_joint_sines" or
            subset == "stand" and o["case"]["motion"] == "stand" or subset == "late" and o["start_step"] >= 100]
        mean = lambda values: float(np.mean(values)) if len(values) else None
        row = dict(subset=subset, origins=len(ids), gradient_norm=norm,
            predicted_change=mean([predicted[1.0][i] - before[i] for i in ids]),
            local_physical_change=mean([by_scale[1.0][i]["local_return"] - baselines[i]["local_return"] for i in ids]),
            full_physical_change=mean([by_scale[1.0][i]["full_return"] - baselines[i]["full_return"] for i in ids]),
            mean_steps_change=mean([by_scale[1.0][i]["steps"] - baselines[i]["steps"] for i in ids]),
            full_improves_fraction=mean([by_scale[1.0][i]["full_return"] > baselines[i]["full_return"] for i in ids]))
        model_slopes = [(predicted[scale][i] - predicted[-scale][i]) / (2 * scale) for i in ids]
        row["centered_model_slope"] = mean(model_slopes)
        for key in ["local_return", "full_return"]:
            slopes = [(by_scale[scale][i][key] - by_scale[-scale][i][key]) / (2 * scale) for i in ids]
            valid = [j for j in range(len(ids)) if abs(model_slopes[j]) > 1e-5 and abs(slopes[j]) > 1e-5]
            row["centered_" + key] = mean(slopes)
            row["sign_" + key] = dict(denominator=len(valid), agree=int(sum(model_slopes[j] * slopes[j] > 0 for j in valid)))
        summaries.append(row)
    return dict(summaries=summaries, records=records, open_loop_predictions=open_loop_errors(model, origins, config)), delta


def run(args):
    study, output = Path(args.study), Path(args.output)
    config = json.loads((Path(args.probe) / "config.json").read_bytes())
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, .02)
    output.mkdir(parents=True, exist_ok=True)
    initial, _ = load_model(args.initial)
    initial_sha = hashlib.sha256(Path(args.initial).read_bytes()).hexdigest()
    original_reports = {method: json.loads((Path(args.probe) / method / "report.json").read_bytes()) for method in ["frame", "preview"]}
    for report in original_reports.values():
        if report["dynamics_sha256"] != initial_sha or report["maximum_restore_error"] > 1e-8:
            raise ValueError("dynamic refit comparison origins do not match original physics probe")
    reports, rows, latest_predictions = [], [], []
    for arm in ["old-only", "mixed"]:
        for fit_seed in [0, 1, 2]:
            model_path = study / arm / f"dynamics-seed-{fit_seed}.pt"
            model, metadata = load_model(model_path)
            latest_path = study / arm / f"latest-dynamics-seed-{fit_seed}.pt"
            latest, latest_meta = load_model(latest_path)
            if metadata["config"]["refit"]["initial_dynamics_sha256"] != initial_sha:
                raise ValueError("refit does not originate from this model")
            for name, buffer in model.named_buffers():
                if not torch.equal(buffer, dict(initial.named_buffers())[name]):
                    raise ValueError("refit prediction scale differs")
            for p in model.parameters():
                p.requires_grad_(False); p.grad = None
            initial_weights = copy.deepcopy(model.state_dict())
            for method, old in original_reports.items():
                for group in old["origins"]:
                    policy_seed, origins = group["seed"], group["origins"]
                    actor_path = Path(args.policies) / method / "policy" / f"actor-seed-{policy_seed}.pt"
                    binding = next(r for r in old["bindings"] if r["seed"] == policy_seed)
                    if hashlib.sha256(actor_path.read_bytes()).hexdigest() != binding["incoming_sha256"]:
                        raise ValueError("probe incoming actor differs")
                    actor, _ = load_temporal(actor_path)
                    latest_predictions.append(dict(arm=arm, fit_seed=fit_seed, method=method, policy_seed=policy_seed,
                        update=latest_meta["selected_update"], checkpoint_sha256=hashlib.sha256(latest_path.read_bytes()).hexdigest(),
                        records=open_loop_errors(latest, origins, config)))
                    zero = [r for r in old["records"] if r["seed"] == policy_seed and r["direction"] == "on_policy_adam" and r["multiplier"] == 0]
                    baselines = [r["baseline"] for r in sorted(zero, key=lambda r: r["origin"])]
                    if len(baselines) != len(origins):
                        raise ValueError("missing paired physical baseline")
                    results, delta = compare_one(runtime, model, actor, origins, baselines, config)
                    key = dict(arm=arm, fit_seed=fit_seed, method=method, policy_seed=policy_seed,
                        selected_model_update=metadata["selected_update"], checkpoint_sha256=hashlib.sha256(model_path.read_bytes()).hexdigest())
                    reports.append(dict(**key, **results))
                    for row in results["summaries"]:
                        rows.append(dict(**key, **row))
                        if row["subset"] == "all":
                            print(json.dumps(rows[-1]), flush=True)
                    torch.save(dict(direction=delta, **key), output / f"direction-{arm}-{fit_seed}-{method}-{policy_seed}.pt")
            if any(not torch.equal(v, model.state_dict()[k]) for k, v in initial_weights.items()) or any(p.grad is not None for p in model.parameters()):
                raise ValueError("refit probe changed frozen model")
    summary = dict(format="moonrobo.g1-dynamic-refit-probe.v1", config=config, summaries=rows,
        original_probe_sha256={method: hashlib.sha256((Path(args.probe) / method / "report.json").read_bytes()).hexdigest() for method in original_reports},
        initial_dynamics_sha256=initial_sha, dynamics_unchanged=True, physical_execution_allowed=False,
        scope="All 3 refit seeds of old-only/mixed controls, same 111 saved training origins and incoming frame/preview actors. Prediction scale frozen. Fresh on-policy Adam directions, no new policy selection or qualification; reused baseline physics is bound by original report hashes.")
    (output / "report.json").write_text(json.dumps(dict(**summary, results=reports, latest_predictions=latest_predictions), indent=2, allow_nan=False))
    (output / "summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["study", "probe", "policies", "initial", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
