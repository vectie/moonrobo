"""Training-only long-horizon search of existing privileged teacher parameters."""
import argparse
import gzip
import itertools
import json
from pathlib import Path
import time

from cpu_physics import PhysicsRuntime
from learned_balance_study import digest, summary


def trials_for(runtime, cases, seeds, parameters, config, factory, role, keep=False):
    trials, episodes = [], []
    for case in cases:
        for seed in seeds:
            episode, trial = runtime.rollout(case, seed, "policy", config["duration_s"],
                config["fall_height_m"], config["fall_upright_z"], policy=factory(parameters))
            episode["id"] += "-long-teacher-" + role
            trial.update(episode_id=episode["id"])
            trials.append({k: v for k, v in trial.items() if k != "replay"})
            if keep:
                episodes.append(episode)
    return episodes, trials


def rank(result):
    return -result["falls"], result["mean_survival_s"], -result["mean_joint_rmse_rad"]


def run(args):
    import teacher_feedback
    config = json.loads(Path(args.config).read_bytes())
    source = Path(args.study)
    original, collection, experiment = [json.loads((source / n).read_bytes()) for n in ["teacher.json", "collection.json", "experiment.json"]]
    if digest(teacher_feedback.__file__) != original["provider_sha256"]:
        raise ValueError("teacher implementation changed")
    cases = collection["cases"]
    if len(cases) != 9 or any(c["split"] != "train" for c in cases):
        raise ValueError("teacher search accepts the declared training families only")
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    factory = lambda parameters: teacher_feedback.BalanceTeacher(runtime, parameters)
    candidates, selected = [], None
    start = time.perf_counter()
    keys = list(config["grid"])
    for index, values in enumerate(itertools.product(*(config["grid"][k] for k in keys))):
        parameters = {**original["parameters"], **dict(zip(keys, values))}
        _, trials = trials_for(runtime, cases, config["training_reset_seeds"], parameters, config, factory, f"search-{index}")
        result = summary(trials)
        candidate = dict(index=index, parameters=parameters, summary=result, trials=trials,
            actual_transitions=sum(t["steps"] for t in trials), actual_wall_seconds=sum(t["wall_seconds"] for t in trials))
        candidates.append(candidate)
        if selected is None or rank(result) > rank(candidates[selected]["summary"]):
            selected = index
        # Write selection evidence before any canonical/audit evaluation is run.
        (output / "parameter-search.json").write_text(json.dumps(dict(config=config, candidates=candidates,
            selected_index=selected, selection_uses="training cases and training_reset_seeds only"), indent=2, allow_nan=False))
        print(json.dumps(dict(candidate=index, parameters=parameters, summary=result, selected_index=selected)), flush=True)
    selection_seconds = time.perf_counter()-start
    selected_parameters = candidates[selected]["parameters"]
    chosen = dict(format="moonrobo.g1-balance-teacher.v1", kind="handcrafted-simulator-feedback",
        parameters=selected_parameters, provider_sha256=original["provider_sha256"],
        source_teacher_sha256=digest(source / "teacher.json"), parameter_search_sha256=digest(output / "parameter-search.json"),
        selection="thirty-second training-family grid only", selected_index=selected,
        physical_execution_allowed=False)
    (output / "teacher.json").write_text(json.dumps(chosen, indent=2, allow_nan=False))
    rows = []
    log = output / "evaluation-physics.jsonl.gz"
    with gzip.open(log, "wt", compresslevel=6) as stream:
        for role, parameters in [("original", original["parameters"]), ("selected", selected_parameters)]:
            groups = [("canonical-development", experiment["cases"], config["canonical_reset_seeds"])]
            groups += [("training-family-audit", cases, [r]) for r in config["audit_reset_seeds"]]
            for scope, evaluated, resets in groups:
                episodes, trials = trials_for(runtime, evaluated, resets, parameters, config, factory, role+"-"+scope, keep=True)
                stream.write(json.dumps(dict(role=role, scope=scope, reset_seeds=resets,
                    dataset=runtime.dataset(episodes, experiment["source_revision"]), trials=trials), allow_nan=False) + "\n")
                stream.flush()
                row = dict(role=role, scope=scope, reset_seeds=resets, summary=summary(trials), trials=trials,
                    episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes))
                rows.append(row)
                print(json.dumps({k: v for k, v in row.items() if k != "trials"}), flush=True)
    pooled = []
    for role in ["original", "selected"]:
        for scope in ["canonical-development", "training-family-audit"]:
            trials = [t for row in rows if row["role"] == role and row["scope"] == scope for t in row["trials"]]
            result = summary(trials)
            pooled.append(dict(role=role, scope=scope, **result,
                cases=[dict(case_id=c, **summary([t for t in trials if t["case_id"] == c])) for c in sorted({t["case_id"] for t in trials})],
                numeric_pass=result["falls"] == 0 and result["mean_joint_rmse_rad"] <= config["max_mean_joint_rmse_rad"]))
    report = dict(format="moonrobo.g1-balance-teacher-long-fit.v1", config=config,
        selected_index=selected, selected_parameters=selected_parameters,
        search_trials=sum(len(c["trials"]) for c in candidates), search_transitions=sum(c["actual_transitions"] for c in candidates),
        search_seconds=selection_seconds, parameter_search_sha256=digest(output / "parameter-search.json"),
        source_teacher_sha256=digest(source / "teacher.json"), teacher_sha256=digest(output / "teacher.json"),
        provider_sha256=digest(__file__), evaluation_log_sha256=digest(log), evaluation=rows, pooled=pooled,
        wall_seconds=time.perf_counter()-start, learned_policy_qualified=False, physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(selected_index=selected, pooled=pooled)), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "study", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
