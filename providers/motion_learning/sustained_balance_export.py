"""Prepare the selected sustained learner and exact recorded teacher comparisons."""
import argparse
import gzip
import json
from pathlib import Path

from cpu_physics import PhysicsRuntime
from learned_balance_export import replay_from_recorded_states
from learned_balance_study import digest, summary


def run(args):
    source, output = Path(args.study), Path(args.output)
    report = json.loads((source / "report.json").read_bytes())
    proof = json.loads((source / "refit-verification.json").read_bytes())
    if not proof["all_tensors_exact"] or len(proof["verified_checkpoints"]) != 15:
        raise ValueError("missing train-only checkpoint reproduction")
    charter = json.loads((source / "charter.json").read_bytes())
    experiment = json.loads((Path(charter["original_balance_study"]) / "experiment.json").read_bytes())
    for name, key in [("teacher-training.jsonl.gz", "training_sha256"), ("selection-physics.jsonl.gz", "selection_sha256"),
                      ("evaluation-physics.jsonl.gz", "evaluation_sha256")]:
        if digest(source / name) != report[key]:
            raise ValueError("sustained source physics changed")
    output.mkdir(parents=True, exist_ok=True)
    (output / "policy").mkdir(exist_ok=True); (output / "collection").mkdir(exist_ok=True)
    with gzip.open(source / "teacher-training.jsonl.gz", "rt") as stream:
        first = json.loads(next(stream))["dataset"]
    with gzip.open(output / "collection/dataset.json.gz", "wt", compresslevel=6) as stream:
        json.dump(first, stream, allow_nan=False)
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    baseline, candidates = [], {s: [] for s in report["config"]["seeds"]}
    with gzip.open(source / "evaluation-physics.jsonl.gz", "rt") as stream:
        for line in stream:
            record = json.loads(line)
            if record["scope"] != "canonical-development":
                continue
            episode, trial = record["dataset"]["episodes"][0], record["trials"][0]
            if trial["episode_id"] != episode["id"]:
                raise ValueError("sustained replay identity mismatch")
            trial = {**trial, "replay": replay_from_recorded_states(runtime, episode)}
            if record["role"] == "teacher-reference":
                baseline.append(trial)
            else:
                candidates[record["seed"]].append(trial)
    if len(baseline) != 9:
        raise ValueError("expected nine unique teacher-reference trials")
    runs = []
    for seed, trials in candidates.items():
        if len(trials) != 9:
            raise ValueError("expected nine selected canonical trials per parent")
        row = next(r for r in report["final"] if r["role"]=="selected-final" and r["seed"]==seed and r["scope"]=="canonical-development")
        result = summary(trials)
        if result != row["summary"]:
            raise ValueError("exported selected summary differs")
        trace = dict(baseline=dict(summary=summary(baseline), trials=baseline), candidate=dict(summary=result, trials=trials),
            baseline_role="privileged selected teacher; nine unique conditions reused across parent comparisons",
            replay_source="geometry/contact reconstruction from recorded next_state; no policy rerun", physical_execution_allowed=False)
        (output / "policy" / f"physics-seed-{seed}.json").write_text(json.dumps(trace, allow_nan=False))
        path = Path(row["checkpoint"]["path"])
        runs.append(dict(seed=seed, selected_update=1, baseline=summary(baseline), candidate=result,
            qualifies=result["falls"]==0 and result["mean_joint_rmse_rad"]<=report["config"]["max_mean_joint_rmse_rad"],
            checkpoint=path.name, latest_checkpoint=path.name, checkpoint_sha256=digest(path)))
    policy = dict(format="moonrobo.g1-learned-balance-fit.v1", runs=runs,
        experiment={**experiment, "duration_s": report["config"]["duration_s"]}, checkpoint_format="moonrobo.g1-learned-balance-actor.v2",
        selected_variant=report["selected_variant"], head_fit_count=1, seed_semantics="frozen parent seed; one shared selected sixteen-coefficient ankle law",
        selected_update_semantics="one closed-form fit; architecture chosen on separate train-family conditions before final runs",
        baseline_role="privileged selected teacher, not the original parent actor",
        collection_role="first teacher-training episode only; complete eighteen-episode fit corpus in balance-training.jsonl.gz; labels are actual applied teacher actions",
        selection_role="all 135 train-family architecture-selection episodes, excluded from fitting, in balance-selection.jsonl.gz",
        evaluation_role="all 90 selected-policy/teacher-reference canonical and audit episodes in balance-evaluation.jsonl.gz",
        training_sha256=report["training_sha256"], selection_sha256=report["selection_sha256"], evaluation_sha256=report["evaluation_sha256"],
        research_report_sha256=digest(source / "report.json"), refit_verification_sha256=digest(source / "refit-verification.json"),
        qualification_scope="thirty-second development canonical suite: zero falls and mean joint RMSE <= 0.15 rad",
        release_qualified=False, physical_execution_allowed=False)
    (output / "policy/report.json").write_text(json.dumps(policy, indent=2, allow_nan=False))
    metadata = dict(format="moonrobo.g1-sustained-balance-export.v1", source_report_sha256=digest(source / "report.json"),
        source_refit_sha256=digest(source / "refit-verification.json"), provider_sha256=digest(__file__),
        representative_sha256=digest(output / "collection/dataset.json.gz"), runs=runs, physical_execution_allowed=False)
    (output / "export.json").write_text(json.dumps(metadata, indent=2, allow_nan=False))
    print(json.dumps(dict(runs=[dict(seed=r["seed"], candidate=r["candidate"], qualifies=r["qualifies"]) for r in runs])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["study", "scene", "output"]:
        parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
