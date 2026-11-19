"""Fresh train-only sustained teacher distillation with representation/channel controls."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch

from balance_features import BalanceKinematics, make_spec, sequence_features
from balance_feature_study import errors
from cpu_physics import PhysicsRuntime
from learned_balance import LearnedBalanceRunner
from learned_balance_study import digest, summary
from sustained_balance import SustainedBalanceHead, load_sustained_balance, save_sustained_balance
from temporal_actor import load_temporal


def write_episode(stream, runtime, revision, episode, trial, **roles):
    stream.write(json.dumps(dict(**roles, dataset=runtime.dataset([episode], revision), trials=[trial]), allow_nan=False)+"\n")
    stream.flush()


def collect(runtime, geometry, collection, config, factory, output):
    observations, goals, targets, features, sources, trials = [], [], [], [], [], []
    with gzip.open(output / "teacher-training.jsonl.gz", "wt", compresslevel=6) as stream:
        for case in collection["cases"]:
            if case["split"] != "train":
                raise ValueError("sustained teacher fitting accepts train cases only")
            for reset in config["training_reset_seeds"]:
                episode, trial = runtime.rollout(case, reset, "policy", config["duration_s"],
                    config["fall_height_m"], config["fall_upright_z"], policy=factory())
                episode["id"] += "-sustained-teacher-training"
                trial = {k: v for k, v in trial.items() if k != "replay"}
                trial.update(episode_id=episode["id"])
                obs = torch.tensor([s["observation"] for s in episode["steps"]], dtype=torch.float32)
                observations.append(obs)
                goals.append(torch.tensor([s["goal"] for s in episode["steps"]], dtype=torch.float32))
                targets.append(torch.tensor([s["applied_action"] for s in episode["steps"]], dtype=torch.float32))
                with torch.no_grad():
                    features.append(sequence_features(geometry, obs, runtime.dt, window=None))
                sources.append(dict(episode_id=episode["id"], case_id=case["id"], source_family=case["family"],
                    split="train", seed=reset, points=len(obs)))
                trials.append(trial)
                write_episode(stream, runtime, collection["source_revision"], episode, trial, role="teacher-training")
    (output / "training-sources.json").write_text(json.dumps(sources, indent=2, allow_nan=False))
    return [torch.cat(v) for v in [observations, goals, targets, features]], sources, summary(trials)


def evaluate_episode(runtime, parent, head, geometry, case, reset, config, suffix):
    runner = LearnedBalanceRunner(runtime, parent, head, geometry, case, reset, window=None)
    captured, parent_actions = [], []
    def predict(obs, goal):
        action = runner(obs, goal)
        captured.append(runner.last_feature.clone()); parent_actions.append(runner.last_parent.copy())
        return action
    episode, trial = runtime.rollout(case, reset, "policy", config["duration_s"],
        config["fall_height_m"], config["fall_upright_z"], policy=predict)
    obs = torch.tensor([s["observation"] for s in episode["steps"]], dtype=torch.float32)
    goal = torch.tensor([s["goal"] for s in episode["steps"]], dtype=torch.float32)
    actual = torch.tensor([s["applied_action"] for s in episode["steps"]], dtype=torch.float32)
    with torch.no_grad():
        offline = sequence_features(geometry, obs, runtime.dt, window=None)
        expected = head(obs, goal, offline)
        feature_error = float((offline-torch.stack(captured)).abs().max())
        action_error = float((actual[:, head.indices]-expected).abs().max())
        other = [i for i in range(runtime.model.nu) if i not in head.indices]
        other_error = float((actual[:, other]-torch.tensor(np.asarray(parent_actions))[:, other]).abs().max())
    if feature_error > config["maximum_feature_alignment_error"] or action_error > config["maximum_action_alignment_error_rad"] or other_error != 0:
        raise ValueError("sustained offline inputs/actions or frozen parent channels disagree")
    episode["id"] += suffix
    trial = {k: v for k, v in trial.items() if k != "replay"}
    trial.update(episode_id=episode["id"])
    return episode, trial, dict(feature_error=feature_error, action_error_rad=action_error, other_channel_error=other_error)


def selection_rank(result, coefficients):
    return -result["falls"], result["mean_survival_s"], -result["mean_joint_rmse_rad"], -coefficients


def run(args):
    import teacher_feedback
    config = json.loads(Path(args.config).read_bytes())
    old = Path(args.study); teacher_folder = Path(args.teacher_study)
    collection, experiment, charter = [json.loads((old / n).read_bytes()) for n in ["collection.json", "experiment.json", "charter.json"]]
    teacher = json.loads((teacher_folder / "teacher.json").read_bytes())
    if digest(teacher_feedback.__file__) != teacher["provider_sha256"]:
        raise ValueError("sustained teacher implementation changed")
    if teacher["parameter_search_sha256"] != digest(teacher_folder / "parameter-search.json"):
        raise ValueError("train-selected teacher parameters changed")
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    spec = make_spec(runtime.model); geometry = BalanceKinematics(spec)
    output = Path(args.output); (output / "policy").mkdir(parents=True, exist_ok=True)
    factory = lambda: teacher_feedback.BalanceTeacher(runtime, teacher["parameters"])
    start = time.perf_counter()
    points, sources, training_summary = collect(runtime, geometry, collection, config, factory, output)
    collection_seconds = time.perf_counter()-start
    obs, goals, targets, features = points
    fits, fitted = [], {}
    fit_start = time.perf_counter()
    lower, upper = runtime.model.actuator_ctrlrange.T
    for representation in ["range", "pose_rate"]:
        head = SustainedBalanceHead(runtime.names, lower, upper, pose_rate=representation=="pose_rate", fit_bound=teacher["parameters"]["residual_bound_rad"])
        details = head.fit(obs, goals, targets, features, config["uncensored_margin_rad"])
        with torch.no_grad():
            predicted = head(obs, goals, features).numpy()
        details.update(representation=representation, ankle_action=errors(predicted[:, :4], targets[:, head.ankle.indices].numpy()),
            waist_action=errors(predicted[:, 4], targets[:, head.waist_index].numpy()))
        fits.append(details); fitted[representation] = head.eval()
    fit_seconds = time.perf_counter()-fit_start
    print(json.dumps(dict(training_episodes=len(sources), training_points=len(obs), training_summary=training_summary,
        collection_seconds=collection_seconds, fit_seconds=fit_seconds, fits=fits)), flush=True)
    checkpoints, states = {}, {}
    for seed in config["seeds"]:
        incoming = Path(charter["incoming_policies"]) / f"actor-seed-{seed}.pt"
        parent, metadata = load_temporal(incoming)
        states[seed] = {k: v.clone() for k, v in parent.state_dict().items()}
        for variant in config["variants"]:
            head = copy.deepcopy(fitted[variant["representation"]])
            head.control_waist = variant["control_waist"]; head.output_bound = variant["output_bound"]
            head.indices = head.ankle.indices + ([head.waist_index] if head.control_waist else [])
            path = output / "policy" / f'actor-{variant["name"]}-seed-{seed}.pt'
            save_sustained_balance(path, metadata, head, spec, runtime.dt,
                dict(parent_sha256=digest(incoming), teacher_sha256=digest(teacher_folder / "teacher.json"),
                    training_sha256=digest(output / "teacher-training.jsonl.gz"), training_points=len(obs),
                    fit="two shared deterministic ankle/waist fits; parent training seeds are not independent head fits"))
            restored_parent, restored_head, _, _ = load_sustained_balance(path)
            if any(not torch.equal(v, restored_head.state_dict()[k]) for k, v in head.state_dict().items()):
                raise ValueError("sustained head checkpoint round-trip differs")
            if any(not torch.equal(v, restored_parent.state_dict()[k]) for k, v in states[seed].items()):
                raise ValueError("embedded sustained parent changed")
            checkpoints[(seed, variant["name"])] = dict(path=str(path), sha256=digest(path),
                head_state_sha256=hashlib.sha256(b"".join(v.numpy().tobytes() for v in head.state_dict().values())).hexdigest())
    selection = []
    with gzip.open(output / "selection-physics.jsonl.gz", "wt", compresslevel=6) as stream:
        for variant in config["variants"]:
            for seed in config["seeds"]:
                cp = checkpoints[(seed, variant["name"])]
                parent, head, geometry, _ = load_sustained_balance(cp["path"])
                trials, alignment = [], []
                for case in collection["cases"]:
                    reset = config["selection_seed_base"]+10000*seed
                    episode, trial, checked = evaluate_episode(runtime, parent, head, geometry, case, reset, config,
                        f'-sustained-{seed}-{variant["name"]}-selection')
                    trials.append(trial); alignment.append(checked)
                    write_episode(stream, runtime, collection["source_revision"], episode, trial,
                        role="training-selection", seed=seed, variant=variant["name"], alignment=checked)
                if any(not torch.equal(v, parent.state_dict()[k]) for k, v in states[seed].items()):
                    raise ValueError("selection changed frozen parent tensors")
                row = dict(seed=seed, variant=variant["name"], summary=summary(trials), trials=trials,
                    alignment=alignment, checkpoint=cp)
                selection.append(row)
                print(json.dumps({k: v for k, v in row.items() if k not in ["trials", "alignment"]}), flush=True)
    selections = []
    for variant in config["variants"]:
        trials = [t for row in selection if row["variant"]==variant["name"] for t in row["trials"]]
        coefficients = (24 if variant["representation"]=="pose_rate" else 16) + (3 if variant["control_waist"] else 0)
        selections.append(dict(**variant, summary=summary(trials), active_coefficients=coefficients))
    chosen = max(selections, key=lambda v: selection_rank(v["summary"], v["active_coefficients"]))
    (output / "selected.json").write_text(json.dumps(dict(selected_variant=chosen, selection=selections,
        scope="training-family selection only; no canonical or final audit evaluation has run"), indent=2, allow_nan=False))
    print(json.dumps(dict(selected_variant=chosen)), flush=True)
    final = []
    with gzip.open(output / "evaluation-physics.jsonl.gz", "wt", compresslevel=6) as stream:
        for seed in config["seeds"]:
            cp = checkpoints[(seed, chosen["name"])]
            parent, head, geometry, _ = load_sustained_balance(cp["path"])
            for scope, cases, resets in [("canonical-development", experiment["cases"], config["canonical_reset_seeds"]),
                ("training-family-audit", collection["cases"], [config["audit_seed_base"]+10000*seed])]:
                trials, alignment = [], []
                for case in cases:
                    for reset in resets:
                        episode, trial, checked = evaluate_episode(runtime, parent, head, geometry, case, reset, config,
                            f'-sustained-{seed}-{chosen["name"]}-'+scope)
                        trials.append(trial); alignment.append(checked)
                        write_episode(stream, runtime, collection["source_revision"], episode, trial,
                            role="selected-final", seed=seed, scope=scope, variant=chosen["name"], alignment=checked)
                row = dict(role="selected-final", seed=seed, scope=scope, summary=summary(trials), trials=trials, alignment=alignment, checkpoint=cp)
                final.append(row)
                print(json.dumps({k: v for k, v in row.items() if k not in ["trials", "alignment"]}), flush=True)
            if any(not torch.equal(v, parent.state_dict()[k]) for k, v in states[seed].items()):
                raise ValueError("final evaluation changed parent tensors")
        conditions = [("canonical-development", experiment["cases"], config["canonical_reset_seeds"])]
        conditions += [("training-family-audit", collection["cases"], [config["audit_seed_base"]+10000*s]) for s in config["seeds"]]
        for scope, cases, resets in conditions:
            trials = []
            for case in cases:
                for reset in resets:
                    episode, trial = runtime.rollout(case, reset, "policy", config["duration_s"], config["fall_height_m"], config["fall_upright_z"], policy=factory())
                    episode["id"] += "-sustained-teacher-reference-"+scope
                    trial = {k: v for k, v in trial.items() if k != "replay"}; trial["episode_id"] = episode["id"]
                    trials.append(trial)
                    write_episode(stream, runtime, collection["source_revision"], episode, trial, role="teacher-reference", scope=scope, seed=None)
            row = dict(role="teacher-reference", seed=None, scope=scope, reset_seeds=resets, summary=summary(trials), trials=trials)
            final.append(row)
            print(json.dumps({k: v for k, v in row.items() if k != "trials"}), flush=True)
    pooled = []
    for role in ["selected-final", "teacher-reference"]:
        for scope in ["canonical-development", "training-family-audit"]:
            trials = [t for row in final if row["role"]==role and row["scope"]==scope for t in row["trials"]]
            result = summary(trials)
            pooled.append(dict(role=role, scope=scope, **result,
                numeric_pass=result["falls"]==0 and result["mean_joint_rmse_rad"]<=config["max_mean_joint_rmse_rad"],
                cases=[dict(case_id=c, **summary([t for t in trials if t["case_id"]==c])) for c in sorted({t["case_id"] for t in trials})]))
    report = dict(format="moonrobo.g1-sustained-balance-study.v1", config=config, training_episodes=len(sources), training_points=len(obs),
        training_summary=training_summary, collection_seconds=collection_seconds, fit_seconds=fit_seconds, fits=fits,
        selection=selection, selection_variants=selections, selected_variant=chosen, final=final, pooled=pooled,
        training_sha256=digest(output / "teacher-training.jsonl.gz"), training_sources_sha256=digest(output / "training-sources.json"),
        selection_sha256=digest(output / "selection-physics.jsonl.gz"), evaluation_sha256=digest(output / "evaluation-physics.jsonl.gz"),
        selected_sha256=digest(output / "selected.json"), teacher_sha256=digest(teacher_folder / "teacher.json"),
        provider_sha256=digest(__file__), head_provider_sha256=digest(Path(__file__).with_name("sustained_balance.py")),
        feature_provider_sha256=digest(Path(__file__).with_name("balance_features.py")),
        shared_representation_fits=2, parent_actors=3, wall_seconds=time.perf_counter()-start,
        release_qualified=False, physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(selected_variant=chosen, pooled=pooled, wall_seconds=report["wall_seconds"])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "study", "teacher-study", "scene", "output"]:
        parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
