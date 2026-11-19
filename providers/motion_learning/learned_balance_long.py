"""Frozen longer physical evaluation of learned balance checkpoints."""
import argparse
import gzip
import json
from pathlib import Path
import time

import torch

from cpu_physics import PhysicsRuntime
from learned_balance import LearnedBalanceRunner, load_learned_balance
from learned_balance_study import digest, summary
from temporal_actor import TemporalRunner, load_temporal


def run(args):
    config = json.loads(Path(args.config).read_bytes())
    source = Path(args.study)
    fit = json.loads((source / "report.json").read_bytes())
    experiment = json.loads((source / "experiment.json").read_bytes())
    charter = json.loads((source / "charter.json").read_bytes())
    if digest(source / "evaluation-physics.jsonl.gz") != fit["evaluation_log_sha256"]:
        raise ValueError("original ten-second evidence changed")
    prior = {}
    with gzip.open(source / "evaluation-physics.jsonl.gz", "rt") as stream:
        for line in stream:
            row = json.loads(line)
            for episode, trial in zip(row["dataset"]["episodes"], row["trials"]):
                if trial["scope"] == "canonical-development" and trial["seed"] == config["repeat_reset_seed"]:
                    prior[(row["seed"], row["mode"], trial["case_id"])] = episode["steps"]
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    rows, start = [], time.perf_counter()
    log = output / "evaluation-physics.jsonl.gz"
    with gzip.open(log, "wt", compresslevel=6) as stream:
        for seed in config["seeds"]:
            for mode in config["modes"]:
                if mode == "student":
                    checkpoint = Path(charter["incoming_policies"]) / f"actor-seed-{seed}.pt"
                    actor, _ = load_temporal(checkpoint)
                else:
                    checkpoint = source / "policy" / f"actor-{mode}-seed-{seed}.pt"
                    actor, head, geometry, metadata = load_learned_balance(checkpoint)
                initial = {k: v.clone() for k, v in actor.state_dict().items()}
                episodes, trials = [], []
                prefix_points = 0
                for case in experiment["cases"]:
                    for reset in config["reset_seeds"]:
                        runner = (TemporalRunner(runtime, actor, case, reset) if mode == "student" else
                            LearnedBalanceRunner(runtime, actor, head, geometry, case, reset, metadata["window"], metadata["transport"]))
                        episode, trial = runtime.rollout(case, reset, "policy", config["duration_s"],
                            config["fall_height_m"], config["fall_upright_z"], policy=runner)
                        if reset == config["repeat_reset_seed"]:
                            original = prior[(seed, mode, case["id"])]
                            if len(episode["steps"]) < len(original):
                                raise ValueError("long extension ended before the matching ten-second prefix")
                            for old, new in zip(original, episode["steps"]):
                                if any(old[k] != new[k] for k in old if k != "truncated"):
                                    raise ValueError("long evaluation changed the actual original prefix")
                            prefix_points += len(original)
                        episode["id"] += f'-balance-long-{seed}-{mode}'
                        trial.update(episode_id=episode["id"], scope="thirty-second-development")
                        episodes.append(episode); trials.append(trial)
                if any(not torch.equal(v, actor.state_dict()[k]) for k, v in initial.items()):
                    raise ValueError("long evaluation changed parent weights")
                stream.write(json.dumps(dict(seed=seed, mode=mode,
                    dataset=runtime.dataset(episodes, experiment["source_revision"]), trials=trials), allow_nan=False) + "\n")
                stream.flush()
                row = dict(seed=seed, mode=mode, checkpoint=str(checkpoint), checkpoint_sha256=digest(checkpoint),
                    summary=summary(trials), trials=[{k: v for k, v in t.items() if k != "replay"} for t in trials],
                    episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes),
                    exact_original_prefix_points=prefix_points)
                rows.append(row)
                print(json.dumps({k: v for k, v in row.items() if k != "trials"}), flush=True)
    pooled = []
    for mode in config["modes"]:
        trials = [t for row in rows if row["mode"] == mode for t in row["trials"]]
        pooled.append(dict(mode=mode, **summary(trials), cases=[dict(case_id=c,
            **summary([t for t in trials if t["case_id"] == c])) for c in sorted({t["case_id"] for t in trials})]))
    report = dict(format="moonrobo.g1-learned-balance-long.v1", config=config,
        fit_report_sha256=digest(source / "report.json"), evaluation_log_sha256=digest(log),
        provider_sha256=digest(__file__), evaluation=rows, pooled=pooled,
        wall_seconds=time.perf_counter()-start, release_qualified=False, physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(pooled=pooled, wall_seconds=report["wall_seconds"])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "study", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
