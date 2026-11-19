"""Train-only ankle-head fitting and paired physical comparison of causal memories."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch

from balance_features import BalanceKinematics, make_spec, sequence_features
from balance_feature_study import errors, reference_episode
from cpu_physics import PhysicsRuntime
from learned_balance import LearnedAnkleHead, LearnedBalanceRunner, load_learned_balance, save_learned_balance
from temporal_actor import TemporalRunner, load_temporal


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def train_points(runtime, geometry, source, config, collection, factory):
    allowed = {c["id"]: c for c in collection["cases"] if c["split"] == "train"}
    features = {window: [] for window in config["windows"]}
    observations, goals, targets, rows = [], [], [], []
    with gzip.open(source, "rt") as stream:
        for line in stream:
            record = json.loads(line)
            if record["mode"] not in config["source_modes"]:
                continue
            episodes, trials = record["dataset"]["episodes"], record["trials"]
            if len(episodes) != len(trials):
                raise ValueError("unaligned intervention source episodes/trials")
            for episode, trial in zip(episodes, trials):
                if trial["scope"] != config["source_scope"] or episode["split"] != config["source_split"]:
                    continue
                if episode["case_id"] not in allowed or episode["case_id"] != trial["case_id"]:
                    raise ValueError("training point outside declared collection cases")
                suffix = f'-policy-{record["seed"]}-{record["mode"]}-{trial["scope"]}'
                if episode["id"] != trial["episode_id"] + suffix:
                    raise ValueError("source trial/episode identity mismatch")
                if any(s["terminated"] or s["truncated"] for s in episode["steps"][:-1]):
                    raise ValueError("source episode crosses a reset")
                obs = torch.tensor([s["observation"] for s in episode["steps"]], dtype=torch.float32)
                goal = torch.tensor([s["goal"] for s in episode["steps"]], dtype=torch.float32)
                # Privileged logged states supply labels only, after the train-role filter.
                target = torch.tensor(reference_episode(runtime, episode, factory)[4], dtype=torch.float32)
                observations.append(obs); goals.append(goal); targets.append(target)
                with torch.no_grad():
                    for window in config["windows"]:
                        features[window].append(sequence_features(geometry, obs, runtime.dt, window, config["transport"]))
                rows.append(dict(episode_id=episode["id"], parent_seed=record["seed"], source_mode=record["mode"],
                    case_id=episode["case_id"], family=allowed[episode["case_id"]]["family"],
                    split=episode["split"], scope=trial["scope"], points=len(obs)))
    if not rows or len({r["episode_id"] for r in rows}) != len(rows):
        raise ValueError("missing or duplicate training source episodes")
    return torch.cat(observations), torch.cat(goals), torch.cat(targets), {w: torch.cat(v) for w, v in features.items()}, rows


def summary(trials):
    return dict(trials=len(trials), falls=sum(t["failed"] for t in trials),
        mean_survival_s=float(np.mean([t["simulated_seconds"] for t in trials])),
        mean_joint_rmse_rad=float(np.mean([t["joint_rmse_rad"] for t in trials])))


def evaluate(runtime, parent, head, geometry, window, config, experiment, collection, seed, mode):
    episodes, trials = [], []
    maximum_feature_error = maximum_action_error = maximum_other_error = 0.
    conditions = [(c, reset, "canonical-development") for c in experiment["cases"] for reset in config["canonical_reset_seeds"]]
    conditions += [(c, config["train_audit_seed_base"] + 10000*seed, "train-family-audit") for c in collection["cases"]]
    for case, reset, scope in conditions:
        if mode == "student":
            runner = TemporalRunner(runtime, parent, case, reset)
        else:
            runner = LearnedBalanceRunner(runtime, parent, head, geometry, case, reset, window, config["transport"])
        captured, parent_actions = [], []
        def predict(obs, goal):
            action = runner(obs, goal)
            if mode != "student":
                captured.append(runner.last_feature.clone()); parent_actions.append(runner.last_parent.copy())
            return action
        episode, trial = runtime.rollout(case, reset, "policy", config["duration_s"],
            config["fall_height_m"], config["fall_upright_z"], policy=predict)
        if mode != "student":
            obs = torch.tensor([s["observation"] for s in episode["steps"]], dtype=torch.float32)
            goal = torch.tensor([s["goal"] for s in episode["steps"]], dtype=torch.float32)
            actual = torch.tensor([s["applied_action"] for s in episode["steps"]], dtype=torch.float32)
            with torch.no_grad():
                offline = sequence_features(geometry, obs, runtime.dt, window, config["transport"])
                expected = head(obs, goal, offline)
                maximum_feature_error = max(maximum_feature_error, float((offline - torch.stack(captured)).abs().max()))
                maximum_action_error = max(maximum_action_error, float((actual[:, head.indices] - expected).abs().max()))
                torch.testing.assert_close(offline, torch.stack(captured), atol=2e-5, rtol=1e-4)
                torch.testing.assert_close(actual[:, head.indices], expected, atol=2e-5, rtol=1e-4)
                other = [i for i in range(runtime.model.nu) if i not in head.indices]
                error = float((actual[:, other] - torch.tensor(np.asarray(parent_actions))[:, other]).abs().max())
                maximum_other_error = max(maximum_other_error, error)
                if error != 0:
                    raise ValueError("learned feedback changed a non-ankle parent output")
        episode["id"] += f'-learned-balance-{seed}-{mode}-{scope}'
        trial.update(episode_id=episode["id"], scope=scope)
        trials.append({k: v for k, v in trial.items() if k != "replay"}); episodes.append(episode)
    return dict(episodes=episodes, trials=trials,
        summaries={scope: summary([t for t in trials if t["scope"] == scope]) for scope in ["canonical-development", "train-family-audit"]},
        maximum_online_offline_feature_error=maximum_feature_error,
        maximum_online_offline_action_error=maximum_action_error, maximum_other_channel_error=maximum_other_error)


def run(args):
    import teacher_feedback
    config, collection, experiment, teacher = [json.loads(Path(p).read_bytes()) for p in
        [args.config, args.collection, args.experiment, args.teacher]]
    if digest(teacher_feedback.__file__) != teacher["provider_sha256"]:
        raise ValueError("training-label teacher implementation changed")
    source = Path(args.intervention) / "intervention-physics.jsonl.gz"
    if digest(source) != json.loads((Path(args.intervention) / "report.json").read_bytes())["physics_log_sha256"]:
        raise ValueError("intervention training source changed")
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    spec = make_spec(runtime.model); geometry = BalanceKinematics(spec)
    output = Path(args.output); (output / "policy").mkdir(parents=True, exist_ok=True)
    start = time.perf_counter()
    obs, goals, targets, features, source_rows = train_points(runtime, geometry, source, config, collection,
        lambda: teacher_feedback.BalanceTeacher(runtime, teacher["parameters"]))
    (output / "training-sources.json").write_text(json.dumps(source_rows, indent=2, allow_nan=False))
    heads, fits = {}, []
    lower, upper = runtime.model.actuator_ctrlrange.T
    for window in config["windows"]:
        head = LearnedAnkleHead(runtime.names, lower, upper, config["residual_bound_rad"])
        fitted = head.fit(head.inputs(obs, features[window]), goals, targets, config["uncensored_margin_rad"])
        with torch.no_grad():
            fitted["training_ankle_action_error"] = errors(head(obs, goals, features[window]).numpy(), targets[:, head.indices].numpy())
        head.eval(); heads[window] = head
        fits.append(dict(window=window, **fitted))
    fit_seconds = time.perf_counter() - start
    print(json.dumps(dict(training_episodes=len(source_rows), training_points=len(obs), fits=fits, fit_seconds=fit_seconds)), flush=True)
    rows = []
    log = output / "evaluation-physics.jsonl.gz"
    with gzip.open(log, "wt", compresslevel=6) as stream:
        for seed in config["seeds"]:
            incoming = Path(args.policies) / f"actor-seed-{seed}.pt"
            parent, metadata = load_temporal(incoming)
            initial = {k: v.clone() for k, v in parent.state_dict().items()}
            for parameter in parent.parameters():
                parameter.requires_grad_(False)
            for mode, window in [("student", None)] + [("h10" if w == 10 else "full", w) for w in config["windows"]]:
                checkpoint, checkpoint_sha = None, None
                head, active_parent, active_geometry = heads[window], parent, geometry
                if mode != "student":
                    checkpoint = output / "policy" / f"actor-{mode}-seed-{seed}.pt"
                    save_learned_balance(checkpoint, metadata, head, spec, window, runtime.dt,
                        dict(parent_sha256=digest(incoming), source_sha256=digest(source),
                            training_sources_sha256=digest(output / "training-sources.json"),
                            fit="one shared deterministic head per window, reused across three frozen parents", training_points=len(obs)))
                    active_parent, restored, active_geometry, payload = load_learned_balance(checkpoint)
                    for key, value in head.state_dict().items():
                        if not torch.equal(value, restored.state_dict()[key]):
                            raise ValueError("learned head checkpoint round-trip changed tensors")
                    for key, value in initial.items():
                        if not torch.equal(value, active_parent.state_dict()[key]):
                            raise ValueError("embedded frozen parent differs")
                    head = restored; checkpoint_sha = digest(checkpoint)
                cell = evaluate(runtime, active_parent, head, active_geometry, window, config, experiment, collection, seed, mode)
                episodes = cell.pop("episodes")
                stream.write(json.dumps(dict(seed=seed, mode=mode, dataset=runtime.dataset(episodes, collection["source_revision"]),
                    trials=cell["trials"]), allow_nan=False) + "\n"); stream.flush()
                row = dict(seed=seed, mode=mode, window=window, parent_sha256=digest(incoming),
                    checkpoint=None if checkpoint is None else str(checkpoint), checkpoint_sha256=checkpoint_sha,
                    episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes), **cell)
                rows.append(row)
                print(json.dumps({k: v for k, v in row.items() if k != "trials"}), flush=True)
                if any(not torch.equal(v, active_parent.state_dict()[k]) for k, v in initial.items()):
                    raise ValueError("evaluation changed the frozen parent")
    pooled = []
    for mode in ["student", "h10", "full"]:
        for scope in ["canonical-development", "train-family-audit"]:
            trials = [t for r in rows if r["mode"] == mode for t in r["trials"] if t["scope"] == scope]
            result = summary(trials)
            pooled.append(dict(mode=mode, scope=scope, **result,
                cases=[dict(case_id=c, **summary([t for t in trials if t["case_id"] == c])) for c in sorted({t["case_id"] for t in trials})]))
    report = dict(format="moonrobo.g1-learned-balance-study.v1", config=config, fits=fits,
        fit_seconds=fit_seconds, wall_seconds=time.perf_counter()-start,
        training_episodes=len(source_rows), training_points=len(obs), independently_fitted_heads=2,
        independent_parent_actors=3, source_sha256=digest(source), training_sources_sha256=digest(output / "training-sources.json"),
        provider_sha256=digest(__file__), feature_provider_sha256=digest(Path(__file__).with_name("balance_features.py")),
        head_provider_sha256=digest(Path(__file__).with_name("learned_balance.py")),
        evaluation_log_sha256=digest(log), evaluation=rows, pooled=pooled,
        release_qualified=False, physical_execution_allowed=False, scope=config["scope"])
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(pooled=pooled, wall_seconds=report["wall_seconds"])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "collection", "experiment", "teacher", "intervention", "policies", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
