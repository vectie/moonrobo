"""Train the existing actor on privileged teacher labels at student-visited states."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import time

import torch

from cpu_physics import PhysicsRuntime
from dynamics import WindowBatch
from policy import evaluate_physics, load_actor, qualifies, ranking
import balance_teacher as teacher_feedback


def collect_labels(runtime, actor, experiment, parameters, seed):
    episodes, observations, goals, targets = [], [], [], []
    for case in experiment["cases"]:
        if case["split"] != "train":
            continue
        for reset_seed in seed:
            teacher = teacher_feedback.BalanceTeacher(runtime, parameters)
            labels = []
            def predict(obs, goal):
                labels.append(teacher(obs, goal).tolist())
                with torch.no_grad():
                    return actor(torch.tensor(obs, dtype=torch.float32)[None], torch.tensor(goal, dtype=torch.float32)[None])[0].numpy()
            episode, _ = runtime.rollout(case, reset_seed, "policy", experiment["duration_s"],
                experiment["fall_height_m"], experiment["fall_upright_z"], policy=predict)
            if len(labels) != len(episode["steps"]):
                raise ValueError("teacher labels do not match actual student transitions")
            episodes.append(episode)
            observations.extend(s["observation"] for s in episode["steps"])
            goals.extend(s["goal"] for s in episode["steps"])
            targets.extend(labels)
    tensors = [torch.tensor(value, dtype=torch.float32) for value in [observations, goals, targets]]
    # Actual applied_action stays the student control. These labels are separate targets.
    return episodes, targets, tensors


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    collection = json.loads(Path(args.collection).read_text())
    teacher = json.loads(Path(args.teacher).read_text())
    teacher_digest = hashlib.sha256(Path(args.teacher).read_bytes()).hexdigest()
    if hashlib.sha256(Path(teacher_feedback.__file__).read_bytes()).hexdigest() != teacher["provider_sha256"]:
        raise ValueError("teacher implementation differs from the fitted source")
    train = WindowBatch(args.train, "train")
    if train.horizon != 1:
        raise ValueError("dataset aggregation requires point batches")
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    original = [train.observation[:, 0], train.goal[:, 0], train.action[:, 0]]
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    runs = []
    for seed in config["seeds"]:
        torch.manual_seed(seed)
        incoming = Path(args.policies) / f"actor-seed-{seed}.pt"
        actor, metadata = load_actor(incoming)
        optimizer = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
        baseline_val, _ = evaluate_physics(runtime, experiment, config["validation_seeds"], actor, "validation")
        best, selected, best_actor = baseline_val, 0, copy.deepcopy(actor.state_dict())
        history = [dict(round=0, validation=best["summary"])]
        recent = None
        stream_path = output / f"student-physics-seed-{seed}.jsonl.gz"
        start = time.perf_counter()
        with gzip.open(stream_path, "wt", encoding="utf-8", compresslevel=1) as stream:
            for round_index in range(config["rounds"]):
                reset_base = config["collection_seed_base"] + seed * 10000 + round_index * 2
                digest = hashlib.sha256(b"".join(v.detach().numpy().tobytes() for v in actor.state_dict().values())).hexdigest()
                episodes, labels, fresh = collect_labels(runtime, actor, collection, teacher["parameters"], [reset_base, reset_base + 1])
                for episode in episodes:
                    episode["id"] += f"-aggregation-{round_index}-" + digest[:16]
                recent = fresh if recent is None else [torch.cat((old, new))[-config["recent_points"]:] for old, new in zip(recent, fresh)]
                stream.write(json.dumps(dict(round=round_index + 1, policy_state_sha256=digest,
                    teacher_sha256=teacher_digest, dataset=runtime.dataset(episodes, collection["source_revision"]),
                    teacher_action_targets=labels, target_order="episode order, then step order; applied_action is the student control"), allow_nan=False) + "\n")
                for _ in range(config["updates_per_round"]):
                    half = config["batch_size"] // 2
                    old_ids = torch.randint(len(original[0]), (half,))
                    new_ids = torch.randint(len(recent[0]), (config["batch_size"] - half,))
                    obs, goals, targets = [torch.cat((old[old_ids], new[new_ids])) for old, new in zip(original, recent)]
                    loss = ((actor(obs, goals) - targets) / metadata["config"]["action_delta_rad"]).square().mean()
                    if not torch.isfinite(loss):
                        raise ValueError("nonfinite aggregation loss")
                    optimizer.zero_grad()
                    loss.backward()
                    torch.nn.utils.clip_grad_norm_(actor.parameters(), 1)
                    optimizer.step()
                current, _ = evaluate_physics(runtime, experiment, config["validation_seeds"], actor, "validation")
                row = dict(round=round_index + 1, validation=current["summary"], action_loss=float(loss.detach()),
                    collected_episodes=len(episodes), collected_transitions=len(labels),
                    collection_falls=sum(e["steps"][-1]["terminated"] for e in episodes), recent_points=len(recent[0]))
                history.append(row)
                if ranking(current) > ranking(best):
                    best, selected, best_actor = current, round_index + 1, copy.deepcopy(actor.state_dict())
                print(json.dumps(dict(seed=seed, **row)), flush=True)
        elapsed = time.perf_counter() - start
        physics_sha = hashlib.sha256(stream_path.read_bytes()).hexdigest()
        common = {**metadata, "config": {**metadata["config"], **config}, "training_kind": "dataset-aggregation",
            "teacher_sha256": teacher_digest, "student_physics_sha256": physics_sha,
            "initialization": dict(checkpoint=str(incoming), sha256=hashlib.sha256(incoming.read_bytes()).hexdigest(),
                mode="weights-only-warm-start", prior_selected_update=metadata["selected_update"])}
        latest_name, name = f"latest-actor-seed-{seed}.pt", f"actor-seed-{seed}.pt"
        torch.save({**common, "actor": actor.state_dict(), "selected_update": config["rounds"] * config["updates_per_round"]}, output / latest_name)
        actor.load_state_dict(best_actor)
        torch.save({**common, "actor": best_actor, "selected_update": selected * config["updates_per_round"]}, output / name)
        restored, _ = load_actor(output / name)
        if not torch.equal(restored(original[0][:8], original[1][:8]), actor(original[0][:8], original[1][:8])):
            raise ValueError("aggregated actor reload differs")
        baseline, _ = evaluate_physics(runtime, experiment, config["test_seeds"])
        candidate, episodes = evaluate_physics(runtime, experiment, config["test_seeds"], restored)
        (output / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline, candidate=candidate), indent=2, allow_nan=False))
        (output / f"candidate-data-seed-{seed}.json").write_text(json.dumps(runtime.dataset(episodes, experiment["source_revision"]), allow_nan=False))
        runs.append(dict(seed=seed, selected_round=selected, selected_update=selected * config["updates_per_round"],
            training_seconds=elapsed, checkpoint=name, latest_checkpoint=latest_name, reload_matches=True,
            student_physics=dict(file=stream_path.name, sha256=physics_sha),
            baseline=baseline["summary"], candidate=candidate["summary"], qualifies=qualifies(candidate, config), history=history))
    report = dict(format="moonrobo.g1-aggregation-fit.v1", kind="teacher-initialization", config=config,
        teacher_sha256=teacher_digest, training_batch_sha256=train.digest, runs=runs,
        provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), experiment=experiment,
        checkpoint_selection="validation-physics-only", critic_status="untrained-zero-output",
        any_qualified=any(r["qualifies"] for r in runs), physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["train", "policies", "teacher", "scene", "config", "collection", "experiment", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
