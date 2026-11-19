"""Matched temporal policy refinement with/without a calibrated finite value tail."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from dynamics import load_model
from policy import qualifies, ranking
from temporal_actor import load_temporal, save_temporal
from temporal_training import evaluate
from temporal_value import actor_replay, collect_value_data, finite_imagination, fit_value, load_value, make_value, physical_direction_probe, value_error


def weights_digest(module):
    digest = hashlib.sha256()
    for name, value in module.state_dict().items():
        digest.update(name.encode()); digest.update(value.detach().numpy().tobytes())
    return digest.hexdigest()


def run(args):
    config = json.loads(Path(args.config).read_bytes())
    experiment = json.loads(Path(args.experiment).read_bytes())
    collection = json.loads(Path(args.collection).read_bytes())
    teacher = json.loads(Path(args.data).read_bytes())
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    model, model_meta = load_model(args.dynamics)
    for key in ["model_ref", "dt_s", "state_axes", "action_axes", "context_axes", "frame_convention"]:
        if teacher[key] != model_meta["layout"][key]:
            raise ValueError("temporal value study physical replay schema differs")
    for p in model.parameters():
        p.requires_grad_(False); p.grad = None
    original_model = copy.deepcopy(model.state_dict())
    cases = {c["id"]: c for c in collection["cases"] if c["split"] == "train"}
    shared = actor_replay(runtime, teacher["episodes"], cases, config)
    shared_digest = hashlib.sha256(b"".join(p.numpy().tobytes() for p in shared)).hexdigest()
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    runs = []
    for seed in config["seeds"]:
        incoming_path = Path(args.policies) / f"actor-seed-{seed}.pt"
        actor, actor_meta = load_temporal(incoming_path)
        torch.manual_seed(config["critic_initial_seed"] + seed)
        value = make_value(model, actor, config)
        value_optimizer = torch.optim.Adam(value.parameters(), lr=config["critic_learning_rate"])
        optimizer = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
        actor_generator = torch.Generator().manual_seed(config["sampling_seed"] + seed)
        extra_teacher_generator = torch.Generator().manual_seed(config["sampling_seed"] + seed + 1000000)
        value_generator = torch.Generator().manual_seed(config["critic_sampling_seed"] + seed)
        best, _ = evaluate(runtime, experiment, config["validation_seeds"], actor, "validation")
        history, calibrations = [dict(update=0, validation=best["summary"])], []
        selected, best_weights, best_value, selected_critic_update = 0, copy.deepcopy(actor.state_dict()), None, 0
        log_path = output / f"critic-physics-seed-{seed}.jsonl.gz"
        start = time.perf_counter()
        with gzip.open(log_path, "wt", encoding="utf-8", compresslevel=1) as stream:
            def refresh(update):
                index = update // config["critic_refresh_every"]
                reset_seed = config["critic_collect_seed_base"] + 10000 * seed + index
                actor_sha = weights_digest(actor)
                episodes, points, targets, origins = collect_value_data(runtime, actor, collection, config, reset_seed, capture=update == 0)
                dataset = runtime.dataset(episodes, collection["source_revision"])
                dataset_sha = hashlib.sha256(json.dumps(dataset, allow_nan=False).encode()).hexdigest()
                record = dict(role="critic-training", actor_update=update, reset_seed=reset_seed, actor_state_sha256=actor_sha,
                    dataset=dataset, soft_return_targets=targets.tolist(), tail_at_original_task_end=0)
                if update == 0:
                    audit_seed = config["initial_audit_seed"] + 10000 * seed
                    audit_episodes, audit_points, audit_targets, _ = collect_value_data(runtime, actor, collection, config, audit_seed)
                    audit_before = value_error(value, audit_points, audit_targets)
                training = fit_value(value, value_optimizer, points, targets, config, value_generator)
                row = dict(actor_update=update, reset_seed=reset_seed, actor_state_sha256=actor_sha, dataset_sha256=dataset_sha,
                    episodes=len(episodes), transitions=len(targets), falls=sum(e["steps"][-1]["terminated"] for e in episodes),
                    time_limits=sum(e["steps"][-1]["truncated"] for e in episodes), training=training,
                    optimizer_steps=config["critic_fit_steps"])
                if update == 0:
                    row["independent_audit_before"] = audit_before
                    row["independent_audit_after"] = value_error(value, audit_points, audit_targets)
                    record["independent_audit"] = dict(reset_seed=audit_seed, dataset=runtime.dataset(audit_episodes, collection["source_revision"]),
                        soft_return_targets=audit_targets.tolist())
                    probe, direction = physical_direction_probe(runtime, model, actor, value, origins, config)
                    name = f"initial-direction-seed-{seed}.pt"
                    torch.save(dict(actor_state_sha256=actor_sha, direction=direction, config=config), output / name)
                    row["initial_direction"] = dict(file=name, sha256=hashlib.sha256((output / name).read_bytes()).hexdigest(), **probe)
                    record["probe_origins"] = origins
                stream.write(json.dumps(record, allow_nan=False) + "\n")
                calibrations.append(row)
                print(json.dumps(dict(seed=seed, calibration={k: v for k, v in row.items() if k not in ["initial_direction"]})), flush=True)
                return actor_replay(runtime, episodes, cases, config)

            recent = refresh(0)
            best_value = copy.deepcopy(value.state_dict())
            for update in range(1, config["updates"] + 1):
                if update > 1 and (update - 1) % config["critic_refresh_every"] == 0:
                    recent = refresh(update - 1)
                half = config["batch_size"] // 2
                old_ids = torch.randint(len(shared[0]), (half,), generator=actor_generator)
                new_ids = torch.randint(len(recent[0]), (config["batch_size"] - half,), generator=actor_generator)
                mode = config.get("actor_replay_distribution", "mixed")
                if mode == "teacher":
                    extra_ids = torch.randint(len(shared[0]), (config["batch_size"] - half,), generator=extra_teacher_generator)
                    batch = tuple(torch.cat((p[old_ids], p[extra_ids])) for p in shared)
                elif mode == "mixed":
                    batch = tuple(torch.cat((a[old_ids], b[new_ids])) for a, b in zip(shared, recent))
                else:
                    raise ValueError("unknown temporal actor replay distribution")
                objective = finite_imagination(model, actor, value, *batch, config)
                if not torch.isfinite(objective):
                    raise ValueError("nonfinite temporal value actor objective")
                optimizer.zero_grad(); (-objective / config["horizon"]).backward()
                norm = float(torch.nn.utils.clip_grad_norm_(actor.parameters(), 1))
                if not np.isfinite(norm):
                    raise ValueError("nonfinite temporal value actor gradient")
                optimizer.step()
                if any(p.grad is not None for p in value.parameters()):
                    raise ValueError("actor update wrote temporal value parameter gradients")
                if update in config["evaluation_updates"]:
                    current, _ = evaluate(runtime, experiment, config["validation_seeds"], actor, "validation")
                    row = dict(update=update, validation=current["summary"], imagined_return=float(objective.detach()), gradient_norm=norm,
                        critic_actor_update=calibrations[-1]["actor_update"])
                    history.append(row)
                    if ranking(current) > ranking(best):
                        best, selected = current, update
                        best_weights, best_value = copy.deepcopy(actor.state_dict()), copy.deepcopy(value.state_dict())
                        selected_critic_update = calibrations[-1]["actor_update"]
                    print(json.dumps(dict(seed=seed, **row)), flush=True)
            elapsed = time.perf_counter() - start
            latest_name, name = f"latest-actor-seed-{seed}.pt", f"actor-seed-{seed}.pt"
            evidence = dict(checkpoint=str(incoming_path), sha256=hashlib.sha256(incoming_path.read_bytes()).hexdigest(),
                dynamics_sha256=hashlib.sha256(Path(args.dynamics).read_bytes()).hexdigest(),
                teacher_replay_sha256=hashlib.sha256(Path(args.data).read_bytes()).hexdigest(),
                selected_critic_actor_update=selected_critic_update)
            base_meta = dict(config=actor_meta["base_config"], model_ref=actor_meta["model_ref"])
            save_temporal(actor, base_meta, config, output / latest_name, config["updates"],
                {**evidence, "critic_actor_update": calibrations[-1]["actor_update"]}, critic=value)
            actor.load_state_dict(best_weights); value.load_state_dict(best_value)
            save_temporal(actor, base_meta, config, output / name, selected,
                {**evidence, "critic_actor_update": selected_critic_update}, critic=value)
            restored, _ = load_temporal(output / name); restored_value = load_value(output / name)
            probe = (shared[1][:8, -actor.history_length:], shared[2][:8, 0], shared[2][:8, 1:1 + actor.future_length])
            if not torch.equal(restored(*probe), actor(*probe)):
                raise ValueError("temporal value actor checkpoint reload differs")
            value_inputs = shared[0][:8], shared[1][:8], shared[2][:8, :11], shared[3][:8], shared[4][:8]
            if not torch.equal(restored_value(*value_inputs), value(*value_inputs)):
                raise ValueError("temporal value checkpoint reload differs")
            final_episodes, final_points, final_targets, _ = collect_value_data(runtime, restored, collection, config,
                config["selected_audit_seed"] + 10000 * seed)
            final_audit = value_error(restored_value, final_points, final_targets)
            stream.write(json.dumps(dict(role="selected-value-audit", actor_update=selected,
                reset_seed=config["selected_audit_seed"] + 10000 * seed,
                dataset=runtime.dataset(final_episodes, collection["source_revision"]), soft_return_targets=final_targets.tolist()), allow_nan=False) + "\n")
        if any(not torch.equal(v, model.state_dict()[k]) for k, v in original_model.items()) or any(p.grad is not None for p in model.parameters()):
            raise ValueError("temporal value training changed frozen dynamics")
        candidate, _ = evaluate(runtime, experiment, config["test_seeds"], restored)
        incoming, _ = load_temporal(incoming_path)
        baseline, _ = evaluate(runtime, experiment, config["test_seeds"], incoming)
        if selected == 0:
            for before, after in zip(baseline["trials"], candidate["trials"]):
                for key in ["case_id", "seed", "steps", "failed", "joint_rmse_rad", "replay"]:
                    if before[key] != after[key]:
                        raise ValueError("selected update-zero temporal actor differs")
        (output / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline, candidate=candidate), indent=2, allow_nan=False))
        runs.append(dict(seed=seed, selected_update=selected, checkpoint=name, latest_checkpoint=latest_name,
            baseline=baseline["summary"], candidate=candidate["summary"], qualifies=qualifies(candidate, config),
            history=history, training_seconds=elapsed, initialization=evidence, dynamics_unchanged=True, reload_matches=True,
            temporal_value=dict(spec=value.spec, selected_critic_actor_update=selected_critic_update, selected_audit=final_audit),
            critic_physics=dict(file=log_path.name, sha256=hashlib.sha256(log_path.read_bytes()).hexdigest(), batches=calibrations)))
    report = dict(format="moonrobo.g1-policy-fit.v1", training_kind="temporal-physical-finite-value-model-refinement",
        actor_format="moonrobo.g1-temporal-actor.v1", config=config, runs=runs, experiment=experiment,
        baseline_role="incoming supervised temporal actor", checkpoint_selection="validation-physics-only", evidence_class="physics-simulation",
        dynamics_sha256=hashlib.sha256(Path(args.dynamics).read_bytes()).hexdigest(), dynamics_training_batch_sha256=model_meta["training_batch_sha256"],
        shared_teacher_sha256=hashlib.sha256(Path(args.data).read_bytes()).hexdigest(), shared_teacher_points_sha256=shared_digest,
        shared_teacher_actor_starts=len(shared[0]), provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        any_qualified=any(r["qualifies"] for r in runs), physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "experiment", "collection", "data", "policies", "dynamics", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
