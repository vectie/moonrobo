"""Teacher-labeled temporal initialization with clean or disturbed student physics."""
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
from policy import qualifies, ranking
from temporal_actor import TemporalRunner, episode_points, load_temporal, save_temporal
from temporal_training import evaluate, point_set


def collect_labeled(runtime, actor, collection, config, reset_seeds, noise_seed, teacher_factory=None):
    episodes, labels, latent_samples, trials = [], [], [], []
    for case_index, case in enumerate(collection["cases"]):
        if case["split"] != "train":
            raise ValueError("disturbance collection accepts training families only")
        for seed_index, reset in enumerate(reset_seeds):
            teacher = teacher_factory() if teacher_factory else None
            runner = TemporalRunner(runtime, actor, case, reset)
            generator = torch.Generator().manual_seed(noise_seed + 2 * case_index + seed_index)
            targets, samples, captured = [], [], []
            def predict(obs, goal):
                if teacher is not None:
                    targets.append(np.asarray(teacher(obs, goal)).tolist())
                runner(obs, goal)
                with torch.no_grad():
                    history, current, future = runner.last_inputs
                    captured.append(tuple(v[0].clone() for v in runner.last_inputs))
                    latent = actor.latent_mean(history, current, future)
                    latent = latent + config["collection_latent_std"] * torch.randn(latent.shape, generator=generator)
                    samples.append(latent[0].tolist())
                    return actor.base.action_from_latent(latent, current)[0].numpy()
            episode, trial = runtime.rollout(case, reset, "policy", config["duration_s"],
                config["fall_height_m"], config["fall_upright_z"], policy=predict)
            points = episode_points(runtime, episode, case, actor.history_length, actor.future_length)
            for field in range(3):
                if not torch.equal(points[field], torch.stack([p[field] for p in captured])):
                    raise ValueError("disturbance offline/online causal inputs differ")
            actual = torch.tensor([s["applied_action"] for s in episode["steps"]], dtype=torch.float32)
            with torch.no_grad():
                expected = actor.base.action_from_latent(torch.tensor(samples), points[1])
                torch.testing.assert_close(actual, expected, rtol=0, atol=0)
            episodes.append(episode); labels.append(targets); latent_samples.append(samples)
            trials.append({k: v for k, v in trial.items() if k != "replay"})
    summary = dict(trials=len(trials), falls=sum(t["failed"] for t in trials),
        mean_survival_s=float(np.mean([t["simulated_seconds"] for t in trials])),
        mean_joint_rmse_rad=float(np.mean([t["joint_rmse_rad"] for t in trials])))
    return dict(episodes=episodes, teacher_targets=labels, latent_samples=latent_samples,
        trials=trials, summary=summary, maximum_input_alignment_error=0.0)


def select_score(runtime, actor, collection, experiment, config, seed):
    probe_config = {**config, "collection_latent_std": config["selection_latent_std"]}
    train = collect_labeled(runtime, actor, collection, probe_config,
        [config["selection_seed_base"] + 10000 * seed], config["selection_noise_seed"] + 10000 * seed)
    validation, _ = evaluate(runtime, experiment, config["validation_seeds"], actor, "validation")
    trials = train["trials"] + [{k: v for k, v in t.items() if k != "replay"} for t in validation["trials"]]
    summary = dict(trials=len(trials), falls=sum(t["failed"] for t in trials),
        mean_survival_s=float(np.mean([t["simulated_seconds"] for t in trials])),
        mean_joint_rmse_rad=float(np.mean([t["joint_rmse_rad"] for t in trials])))
    return dict(summary=summary, training_audit=train["summary"], validation=validation["summary"], trials=trials)


def audit(runtime, actor, collection, config, seed, role, stream):
    rows = []
    for std in config["audit_latent_stds"]:
        checked = collect_labeled(runtime, actor, collection, {**config, "collection_latent_std": std},
            [config["audit_seed_base"] + 10000 * seed], config["audit_noise_seed"] + 10000 * seed)
        dataset = runtime.dataset(checked["episodes"], collection["source_revision"])
        stream.write(json.dumps(dict(role=role, latent_std=std, dataset=dataset), allow_nan=False) + "\n")
        rows.append(dict(latent_std=std, summary=checked["summary"], trials=checked["trials"]))
    return rows


def run(args):
    import teacher_feedback
    config = json.loads(Path(args.config).read_bytes())
    collection, experiment, teacher = [json.loads(Path(p).read_bytes()) for p in [args.collection, args.experiment, args.teacher]]
    if hashlib.sha256(Path(teacher_feedback.__file__).read_bytes()).hexdigest() != teacher["provider_sha256"]:
        raise ValueError("disturbance teacher implementation changed")
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    cases = {c["id"]: c for c in collection["cases"]}
    raw = json.loads(Path(args.data).read_bytes())
    original = point_set(runtime, raw["episodes"], cases, config)
    output = Path(args.output); (output / "policy").mkdir(parents=True, exist_ok=True)
    (output / "collection").mkdir(exist_ok=True)
    runs = []
    for seed in config["seeds"]:
        incoming_path = Path(args.policies) / f"actor-seed-{seed}.pt"
        actor, metadata = load_temporal(incoming_path)
        if (actor.history_length, actor.future_length) != (config["history_length"], config["future_length"]):
            raise ValueError("incoming temporal shape differs")
        initial = copy.deepcopy(actor.state_dict())
        initial_buffers = {k: v.clone() for k, v in actor.named_buffers()}
        generator = torch.Generator().manual_seed(config["sampling_seed"] + seed)
        optimizer = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
        best = select_score(runtime, actor, collection, experiment, config, seed)
        best_weights, selected = copy.deepcopy(initial), 0
        history = [dict(round=0, selection=best, transitions=0, episodes=0, falls=0)]
        recent = None
        total_transitions, total_episodes, total_falls = 0, 0, 0
        log = output / "policy" / f"disturbance-physics-seed-{seed}.jsonl.gz"
        start = time.perf_counter()
        with gzip.open(log, "wt", compresslevel=6) as stream:
            for index in range(config["rounds"]):
                reset = config["collection_seed_base"] + 10000 * seed + 2 * index
                digest = hashlib.sha256(b"".join(v.detach().numpy().tobytes() for v in actor.state_dict().values())).hexdigest()
                batch = collect_labeled(runtime, actor, collection, config, [reset, reset + 1],
                    config["noise_seed"] + 10000 * seed + 100 * index,
                    lambda: teacher_feedback.BalanceTeacher(runtime, teacher["parameters"]))
                episodes, targets = batch["episodes"], batch["teacher_targets"]
                fresh = point_set(runtime, episodes, cases, config, targets)
                recent = fresh if recent is None else [torch.cat((a, b))[-config["recent_points"]:] for a, b in zip(recent, fresh)]
                for episode in episodes:
                    episode["id"] += f'-{config["arm"]}-round-{index}'
                dataset = runtime.dataset(episodes, collection["source_revision"])
                if seed == 0 and index == 0:
                    with gzip.open(output / "collection/dataset.json.gz", "wt", compresslevel=6) as first:
                        json.dump(dataset, first, allow_nan=False)
                stream.write(json.dumps(dict(round=index + 1, behavior_state_sha256=digest,
                    reset_seeds=[reset, reset + 1], latent_std=config["collection_latent_std"], dataset=dataset,
                    teacher_action_targets=targets, latent_samples=batch["latent_samples"],
                    target_order="Separate teacher labels; applied_action remains actual noisy student control.",
                    maximum_input_alignment_error=batch["maximum_input_alignment_error"]), allow_nan=False) + "\n")
                for _ in range(config["updates_per_round"]):
                    half = config["batch_size"] // 2
                    old_ids = torch.randint(len(original[0]), (half,), generator=generator)
                    new_ids = torch.randint(len(recent[0]), (config["batch_size"] - half,), generator=generator)
                    h, g, f, target = [torch.cat((a[old_ids], b[new_ids])) for a, b in zip(original, recent)]
                    loss = ((actor(h, g, f) - target) / actor.base.config["action_delta_rad"]).square().mean()
                    if not torch.isfinite(loss):
                        raise ValueError("nonfinite disturbed supervision")
                    optimizer.zero_grad(); loss.backward()
                    torch.nn.utils.clip_grad_norm_(actor.parameters(), 1); optimizer.step()
                current = select_score(runtime, actor, collection, experiment, config, seed)
                total_transitions += sum(len(e["steps"]) for e in episodes)
                total_episodes += len(episodes); total_falls += batch["summary"]["falls"]
                row = dict(round=index + 1, selection=current, action_loss=float(loss.detach()),
                    transitions=total_transitions, episodes=total_episodes, falls=total_falls,
                    collection=batch["summary"], maximum_input_alignment_error=batch["maximum_input_alignment_error"])
                history.append(row)
                if ranking(current) > ranking(best):
                    best, selected, best_weights = current, index + 1, copy.deepcopy(actor.state_dict())
                print(json.dumps(dict(seed=seed, arm=config["arm"], **{k: v for k, v in row.items() if k != "selection"},
                    selection=current["summary"])), flush=True)
        elapsed = time.perf_counter() - start
        evidence = dict(algorithm="teacher-supervised-disturbance-initialization", checkpoint=str(incoming_path),
            sha256=hashlib.sha256(incoming_path.read_bytes()).hexdigest(),
            teacher_sha256=hashlib.sha256(Path(args.teacher).read_bytes()).hexdigest(),
            student_physics_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
        base_meta = dict(config=metadata["base_config"], model_ref=metadata["model_ref"])
        name, latest = f"actor-seed-{seed}.pt", f"latest-actor-seed-{seed}.pt"
        save_temporal(actor, base_meta, config, output / "policy" / latest,
            config["rounds"] * config["updates_per_round"], evidence)
        actor.load_state_dict(best_weights)
        save_temporal(actor, base_meta, config, output / "policy" / name, selected * config["updates_per_round"], evidence)
        restored, _ = load_temporal(output / "policy" / name)
        if not torch.equal(actor(*(p[:8] for p in original[:3])), restored(*(p[:8] for p in original[:3]))):
            raise ValueError("disturbed policy reload differs")
        if any(not torch.equal(v, dict(actor.named_buffers())[k]) for k, v in initial_buffers.items()):
            raise ValueError("disturbed policy normalization changed")
        incoming, _ = load_temporal(incoming_path)
        baseline, _ = evaluate(runtime, experiment, config["test_seeds"], incoming)
        candidate, _ = evaluate(runtime, experiment, config["test_seeds"], restored)
        (output / "policy" / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline, candidate=candidate), indent=2, allow_nan=False))
        audit_path = output / "policy" / f"disturbance-audit-seed-{seed}.jsonl.gz"
        with gzip.open(audit_path, "wt", compresslevel=6) as stream:
            before_audit = audit(runtime, incoming, collection, config, seed, "incoming-independent-audit", stream)
            after_audit = audit(runtime, restored, collection, config, seed, "selected-independent-audit", stream)
        runs.append(dict(seed=seed, selected_update=selected * config["updates_per_round"], selected_round=selected,
            checkpoint=name, latest_checkpoint=latest, baseline=baseline["summary"], candidate=candidate["summary"],
            qualifies=qualifies(candidate, config), history=history, training_seconds=elapsed,
            training_transitions=total_transitions, training_episodes=total_episodes, training_falls=total_falls,
            optimizer_steps=config["rounds"] * config["updates_per_round"], normalization_unchanged=True,
            reload_matches=True, initialization=evidence, incoming_audit=before_audit, selected_audit=after_audit,
            physics_log=dict(file=log.name, sha256=evidence["student_physics_sha256"]),
            audit_log=dict(file=audit_path.name, sha256=hashlib.sha256(audit_path.read_bytes()).hexdigest())))
    report = dict(format="moonrobo.g1-temporal-disturbance-fit.v1", algorithm="teacher-supervised-disturbance-initialization",
        config=config, experiment=experiment, collection_experiment=collection, runs=runs,
        checkpoint_selection="fixed train-family disturbance audit plus held-out sway; audit episodes never fit weights",
        registered_collection_role="first seed first student training batch; complete student collection and separate teacher labels in per-seed logs",
        shared_teacher_data_sha256=hashlib.sha256(Path(args.data).read_bytes()).hexdigest(),
        provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        any_qualified=any(r["qualifies"] for r in runs), learned_transition_model_used=False, critic_status="not-trained",
        physical_execution_allowed=False)
    (output / "policy/report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "collection", "experiment", "teacher", "data", "policies", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
