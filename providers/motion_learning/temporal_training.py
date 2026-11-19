"""Three temporal-input variants on shared dynamic teacher training conditions."""
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
from policy import evaluate_physics, load_actor, qualifies, ranking
from temporal_actor import TemporalActor, TemporalRunner, episode_points, load_temporal, save_temporal


def evaluate(runtime, experiment, seeds, actor, split=None):
    episodes, trials = [], []
    for case in experiment["cases"]:
        if split is not None and case["split"] != split:
            continue
        for seed in seeds:
            runner = TemporalRunner(runtime, actor, case, seed)
            episode, trial = runtime.rollout(case, seed, "policy", experiment["duration_s"],
                experiment["fall_height_m"], experiment["fall_upright_z"], policy=runner)
            episodes.append(episode); trials.append(trial)
    summary = dict(trials=len(trials), falls=sum(t["failed"] for t in trials),
        mean_survival_s=float(np.mean([t["simulated_seconds"] for t in trials])),
        mean_joint_rmse_rad=float(np.mean([t["joint_rmse_rad"] for t in trials])))
    return dict(summary=summary, trials=trials), episodes


def point_set(runtime, episodes, cases, config, labels=None):
    pieces = [episode_points(runtime, episode, cases[episode["case_id"]], config["history_length"],
        config["future_length"], None if labels is None else labels[i]) for i, episode in enumerate(episodes)]
    return [torch.cat([piece[i] for piece in pieces]) for i in range(4)]


def collect_student(runtime, actor, experiment, teacher, seeds):
    import teacher_feedback
    episodes, labels, max_error = [], [], 0.0
    for case in experiment["cases"]:
        if case["split"] != "train":
            continue
        for seed in seeds:
            feedback = teacher_feedback.BalanceTeacher(runtime, teacher["parameters"])
            runner = TemporalRunner(runtime, actor, case, seed)
            targets, captured = [], {}
            def predict(obs, goal):
                targets.append(feedback(obs, goal).tolist())
                action = runner(obs, goal)
                index = runner.index - 1
                if index in [0, 1, 25, 100, 250, 499]:
                    captured[index] = tuple(value[0].clone() for value in runner.last_inputs)
                return action
            episode, _ = runtime.rollout(case, seed, "policy", experiment["duration_s"],
                experiment["fall_height_m"], experiment["fall_upright_z"], policy=predict)
            points = episode_points(runtime, episode, case, actor.history_length, actor.future_length, targets)
            for index, actual in captured.items():
                for field in range(3):
                    expected = points[field][index]
                    error = float((expected - actual[field]).abs().max()) if expected.numel() else 0.0
                    max_error = max(max_error, error)
                    if error > 1e-6:
                        raise ValueError("offline/online temporal input alignment differs")
            episodes.append(episode); labels.append(targets)
    return episodes, labels, max_error


def collect_teacher(args, runtime, collection, teacher, config, output):
    import teacher_feedback
    episodes, trials = [], []
    for case in collection["cases"]:
        if case["split"] != "train":
            continue
        for seed in config["teacher_seeds"]:
            feedback = teacher_feedback.BalanceTeacher(runtime, teacher["parameters"])
            episode, trial = runtime.rollout(case, seed, "policy", collection["duration_s"],
                collection["fall_height_m"], collection["fall_upright_z"], policy=feedback)
            episode["id"] += "-temporal-teacher"
            episodes.append(episode); trials.append({k: v for k, v in trial.items() if k != "replay"})
    data = runtime.dataset(episodes, collection["source_revision"])
    (output / "dataset.json").write_text(json.dumps(data, allow_nan=False))
    report = dict(format="moonrobo.g1-temporal-teacher.v1", episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes),
        falls=sum(t["failed"] for t in trials), trials=trials, collection=collection,
        teacher_sha256=hashlib.sha256(Path(args.teacher).read_bytes()).hexdigest(), physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps({k: report[k] for k in ["episodes", "transitions", "falls"]}), flush=True)


def fit(args, runtime, collection, teacher, config, output):
    experiment = json.loads(Path(args.experiment).read_text())
    raw = json.loads(Path(args.data).read_text())
    cases = {case["id"]: case for case in collection["cases"] if case["split"] == "train"}
    original = point_set(runtime, raw["episodes"], cases, config)
    runs = []
    for seed in config["seeds"]:
        torch.manual_seed(seed)
        incoming = Path(args.policies) / f"actor-seed-{seed}.pt"
        base, metadata = load_actor(incoming)
        baseline, _ = evaluate_physics(runtime, experiment, config["validation_seeds"], base, "validation")
        actor = TemporalActor(base, config["history_length"], config["future_length"], config["adapter_width"])
        first, _ = evaluate(runtime, experiment, config["validation_seeds"], actor, "validation")
        for a, b in zip(baseline["trials"], first["trials"]):
            for key in ["case_id", "seed", "steps", "failed", "joint_rmse_rad", "replay"]:
                if a[key] != b[key]:
                    raise ValueError("zero adapter changed initial closed-loop inference")
        optimizer = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
        generator = torch.Generator().manual_seed(config["sampling_seed"] + seed)
        best, selected, best_weights = first, 0, copy.deepcopy(actor.state_dict())
        history = [dict(round=0, validation=first["summary"])]
        recent = None
        path = output / f"student-physics-seed-{seed}.jsonl.gz"
        start = time.perf_counter()
        with gzip.open(path, "wt", encoding="utf-8", compresslevel=1) as stream:
            for index in range(config["rounds"]):
                reset = config["collection_seed_base"] + seed * 10000 + 2 * index
                digest = hashlib.sha256(b"".join(v.detach().numpy().tobytes() for v in actor.state_dict().values())).hexdigest()
                episodes, targets, error = collect_student(runtime, actor, collection, teacher, [reset, reset + 1])
                fresh = point_set(runtime, episodes, cases, config, targets)
                recent = fresh if recent is None else [torch.cat((a, b))[-config["recent_points"]:] for a, b in zip(recent, fresh)]
                for episode in episodes:
                    episode["id"] += f'-temporal-{config["method"]}-{index}-' + digest[:16]
                stream.write(json.dumps(dict(round=index + 1, actor_sha256=digest,
                    dataset=runtime.dataset(episodes, collection["source_revision"]), teacher_action_targets=targets,
                    target_order="one list per episode, one action per step; actual applied_action remains student control",
                    maximum_input_alignment_error=error), allow_nan=False) + "\n")
                for _ in range(config["updates_per_round"]):
                    half = config["batch_size"] // 2
                    old_ids = torch.randint(len(original[0]), (half,), generator=generator)
                    new_ids = torch.randint(len(recent[0]), (config["batch_size"] - half,), generator=generator)
                    h, goal, future, target = [torch.cat((a[old_ids], b[new_ids])) for a, b in zip(original, recent)]
                    loss = ((actor(h, goal, future) - target) / base.config["action_delta_rad"]).square().mean()
                    if not torch.isfinite(loss):
                        raise ValueError("nonfinite temporal supervision loss")
                    optimizer.zero_grad(); loss.backward()
                    torch.nn.utils.clip_grad_norm_(actor.parameters(), 1)
                    optimizer.step()
                current, _ = evaluate(runtime, experiment, config["validation_seeds"], actor, "validation")
                row = dict(round=index + 1, validation=current["summary"], action_loss=float(loss.detach()),
                    episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes),
                    falls=sum(e["steps"][-1]["terminated"] for e in episodes), maximum_input_alignment_error=error)
                history.append(row)
                if ranking(current) > ranking(best):
                    best, selected, best_weights = current, index + 1, copy.deepcopy(actor.state_dict())
                print(json.dumps(dict(seed=seed, **row)), flush=True)
        elapsed = time.perf_counter() - start
        evidence = dict(checkpoint=str(incoming), sha256=hashlib.sha256(incoming.read_bytes()).hexdigest(),
            teacher_sha256=hashlib.sha256(Path(args.teacher).read_bytes()).hexdigest(),
            student_physics_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        latest_name, name = f"latest-actor-seed-{seed}.pt", f"actor-seed-{seed}.pt"
        save_temporal(actor, metadata, config, output / latest_name, config["rounds"] * config["updates_per_round"], evidence)
        actor.load_state_dict(best_weights)
        save_temporal(actor, metadata, config, output / name, selected * config["updates_per_round"], evidence)
        restored, _ = load_temporal(output / name)
        if not torch.equal(actor(*(value[:8] for value in original[:3])), restored(*(value[:8] for value in original[:3]))):
            raise ValueError("temporal checkpoint reload differs")
        candidate, _ = evaluate(runtime, experiment, config["test_seeds"], restored)
        baseline_test, _ = evaluate_physics(runtime, experiment, config["test_seeds"], None)
        (output / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline_test, candidate=candidate), indent=2, allow_nan=False))
        runs.append(dict(seed=seed, selected_round=selected, selected_update=selected * config["updates_per_round"],
            training_seconds=elapsed, initial_matches_legacy=True, history=history, checkpoint=name,
            latest_checkpoint=latest_name, candidate=candidate["summary"], qualifies=qualifies(candidate, config),
            student_physics=dict(file=path.name, sha256=evidence["student_physics_sha256"]), reload_matches=True))
    report = dict(format="moonrobo.g1-temporal-fit.v1", config=config, runs=runs,
        checkpoint_selection="validation-physics-only", training_kind="teacher-supervision-and-student-state-labeling",
        data_sha256=hashlib.sha256(Path(args.data).read_bytes()).hexdigest(),
        provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        physical_execution_allowed=False, any_qualified=any(r["qualifies"] for r in runs))
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


def run(args):
    import teacher_feedback
    config = json.loads(Path(args.config).read_text())
    collection = json.loads(Path(args.collection).read_text())
    teacher = json.loads(Path(args.teacher).read_text())
    if hashlib.sha256(Path(teacher_feedback.__file__).read_bytes()).hexdigest() != teacher["provider_sha256"]:
        raise ValueError("teacher implementation differs from fitted source")
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    if args.command == "collect-teacher":
        collect_teacher(args, runtime, collection, teacher, config, output)
    elif args.command == "fit":
        fit(args, runtime, collection, teacher, config, output)
    else:
        actor, _ = load_temporal(args.checkpoint)
        report, _ = evaluate(runtime, json.loads(Path(args.experiment).read_text()), config["test_seeds"], actor)
        (output / "physics.json").write_text(json.dumps(report, indent=2, allow_nan=False))
        print(json.dumps(report["summary"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["collect-teacher", "fit", "evaluate"])
    for name in ["scene", "config", "collection", "teacher", "output"]:
        parser.add_argument("--" + name, required=True)
    for name in ["data", "policies", "experiment", "checkpoint"]:
        parser.add_argument("--" + name)
    run(parser.parse_args())
