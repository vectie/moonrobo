"""Finite-horizon policy updates with rolling histories and changing known goals."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from dynamics import load_model
from policy import qualifies, ranking
from temporal_actor import episode_points, load_temporal, preview_goals, save_temporal, temporal_imagination
from temporal_training import evaluate


def replay_points(runtime, raw, cases, actor, horizon):
    parts = []
    for episode in raw["episodes"]:
        case = cases[episode["case_id"]]
        history, goal, _, _ = episode_points(runtime, episode, case, actor.history_length, 0)
        nominal = np.asarray(episode["reference_nominal_rad"])
        offset = np.asarray(episode["reference_offset_rad"]) if "reference_offset_rad" in episode else None
        future = torch.tensor(np.asarray([preview_goals(runtime, case, nominal, offset, episode.get("reference_schedule"),
            s["time_s"], horizon + actor.future_length) for s in episode["steps"]]), dtype=torch.float32)
        schedule = torch.cat((goal[:, None], future), 1)
        state = torch.tensor([s["state"] for s in episode["steps"]], dtype=torch.float32)
        context = torch.tensor(episode["context"], dtype=torch.float32)[None].expand(len(state), -1)
        parts.append((state, history, schedule, context))
    return [torch.cat([part[i] for part in parts]) for i in range(4)]


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    collection = json.loads(Path(args.collection).read_text())
    raw = json.loads(Path(args.data).read_text())
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    model, model_metadata = load_model(args.dynamics)
    for key in ["model_ref", "dt_s", "state_axes", "action_axes", "context_axes", "frame_convention"]:
        if raw[key] != model_metadata["layout"][key]:
            raise ValueError("temporal actor replay differs from world-model physical schema")
    for p in model.parameters():
        p.requires_grad_(False); p.grad = None
    model_initial = copy.deepcopy(model.state_dict())
    cases = {case["id"]: case for case in collection["cases"] if case["split"] == "train"}
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    runs, points = [], None
    for seed in config["seeds"]:
        torch.manual_seed(seed)
        incoming_path = Path(args.policies) / f"actor-seed-{seed}.pt"
        actor, metadata = load_temporal(incoming_path)
        initial_weights = copy.deepcopy(actor.state_dict())
        if points is None:
            points = replay_points(runtime, raw, cases, actor, config["horizon"])
        optimizer = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
        generator = torch.Generator().manual_seed(config["sampling_seed"] + seed)
        best, _ = evaluate(runtime, experiment, config["validation_seeds"], actor, "validation")
        selected, best_actor = 0, copy.deepcopy(actor.state_dict())
        history = [dict(update=0, validation=best["summary"])]
        start = time.perf_counter()
        for update in range(1, config["updates"] + 1):
            indices = torch.randint(len(points[0]), (config["batch_size"],), generator=generator)
            state, observed_history, goals, context = [value[indices] for value in points]
            objective = temporal_imagination(model, actor, None, state, observed_history, goals, context, config)[0]
            if not torch.isfinite(objective):
                raise ValueError("nonfinite temporal model objective")
            optimizer.zero_grad(); (-objective / config["horizon"]).backward()
            norm = float(torch.nn.utils.clip_grad_norm_(actor.parameters(), 1))
            if not np.isfinite(norm):
                raise ValueError("nonfinite temporal actor gradient")
            optimizer.step()
            if update in config["evaluation_updates"]:
                current, _ = evaluate(runtime, experiment, config["validation_seeds"], actor, "validation")
                row = dict(update=update, validation=current["summary"], imagined_return=float(objective.detach()), gradient_norm=norm)
                history.append(row)
                if ranking(current) > ranking(best):
                    best, selected, best_actor = current, update, copy.deepcopy(actor.state_dict())
                print(json.dumps(dict(seed=seed, **row)), flush=True)
        elapsed = time.perf_counter() - start
        if any(not torch.equal(v, model.state_dict()[k]) for k, v in model_initial.items()) or any(p.grad is not None for p in model.parameters()):
            raise ValueError("temporal policy updates changed the frozen world model")
        evidence = dict(checkpoint=str(incoming_path), sha256=hashlib.sha256(incoming_path.read_bytes()).hexdigest(),
            dynamics_sha256=hashlib.sha256(Path(args.dynamics).read_bytes()).hexdigest(),
            replay_dataset_sha256=hashlib.sha256(Path(args.data).read_bytes()).hexdigest())
        base_meta = dict(config=metadata["base_config"], model_ref=metadata["model_ref"])
        latest_name, name = f"latest-actor-seed-{seed}.pt", f"actor-seed-{seed}.pt"
        save_temporal(actor, base_meta, config, output / latest_name, config["updates"], evidence)
        actor.load_state_dict(best_actor)
        save_temporal(actor, base_meta, config, output / name, selected, evidence)
        restored, _ = load_temporal(output / name)
        probe = (points[1][:8], points[2][:8, 0], points[2][:8, 1:1 + actor.future_length])
        if not torch.equal(actor(*probe), restored(*probe)):
            raise ValueError("temporal model-refined checkpoint reload differs")
        candidate, _ = evaluate(runtime, experiment, config["test_seeds"], restored)
        incoming, _ = load_temporal(incoming_path)
        baseline, _ = evaluate(runtime, experiment, config["test_seeds"], incoming)
        if selected == 0:
            for a, b in zip(baseline["trials"], candidate["trials"]):
                for key in ["case_id", "seed", "steps", "failed", "joint_rmse_rad", "replay"]:
                    if a[key] != b[key]:
                        raise ValueError("update-zero temporal actor differs from incoming")
        (output / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline, candidate=candidate), indent=2, allow_nan=False))
        runs.append(dict(seed=seed, selected_update=selected, training_seconds=elapsed, history=history,
            checkpoint=name, latest_checkpoint=latest_name, dynamics_unchanged=True, reload_matches=True,
            baseline=baseline["summary"], candidate=candidate["summary"], qualifies=qualifies(candidate, config),
            initialization=evidence, actor_format="moonrobo.g1-temporal-actor.v1"))
    report = dict(format="moonrobo.g1-policy-fit.v1", training_kind="temporal-finite-horizon-model-refinement",
        actor_format="moonrobo.g1-temporal-actor.v1", config=config, runs=runs, experiment=experiment,
        baseline_role="incoming temporal actor", evidence_class="physics-simulation", checkpoint_selection="validation-physics-only",
        dynamics_sha256=hashlib.sha256(Path(args.dynamics).read_bytes()).hexdigest(),
        dynamics_training_batch_sha256=model_metadata["training_batch_sha256"],
        replay_dataset_sha256=hashlib.sha256(Path(args.data).read_bytes()).hexdigest(),
        provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), any_qualified=any(r["qualifies"] for r in runs), physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "experiment", "collection", "data", "policies", "dynamics", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
