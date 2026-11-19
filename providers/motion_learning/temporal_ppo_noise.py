"""Training-only exploration calibration from unchanged incoming temporal actors."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from temporal_actor import TemporalRunner, load_temporal


def run(args):
    config = json.loads(Path(args.config).read_bytes())
    collection = json.loads(Path(args.collection).read_bytes())
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    rows = []
    log = output / "noise-physics.jsonl.gz"
    with gzip.open(log, "wt", compresslevel=6) as stream:
        for seed in config["seeds"]:
            actor_path = Path(args.policies) / f"actor-seed-{seed}.pt"
            actor, _ = load_temporal(actor_path)
            for std in config["standard_deviations"]:
                episodes, trials = [], []
                squared_noise, saturated, count = 0., 0, 0
                for index, case in enumerate(collection["cases"]):
                    if case["split"] != "train":
                        raise ValueError("exploration calibration requires train families only")
                    reset = config["collect_seed_base"] + 10000 * seed
                    # Each case has a coupled noise stream across amplitudes,
                    # independent of other cases' different fall times.
                    generator = torch.Generator().manual_seed(config["noise_seed"] + seed + 100000 * index)
                    runner = TemporalRunner(runtime, actor, case, reset)
                    def predict(obs, goal):
                        nonlocal squared_noise, saturated, count
                        deterministic = runner(obs, goal)
                        with torch.no_grad():
                            history, current, future = runner.last_inputs
                            mean = actor.latent_mean(history, current, future)
                            latent = mean + std * torch.randn(mean.shape, generator=generator)
                            action = actor.base.action_from_latent(latent, current)[0].numpy()
                            squared_noise += float(np.square(action - deterministic).sum())
                            saturated += int((mean.abs() > 3).sum())
                            count += mean.numel()
                            return action
                    episode, trial = runtime.rollout(case, reset, "policy", config["duration_s"],
                        config["fall_height_m"], config["fall_upright_z"], policy=predict)
                    episode["id"] += f"-noise-{std}"
                    episodes.append(episode); trials.append({k: v for k, v in trial.items() if k != "replay"})
                row = dict(seed=seed, latent_std=std, episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes),
                    falls=sum(t["failed"] for t in trials), mean_survival_s=float(np.mean([t["simulated_seconds"] for t in trials])),
                    mean_joint_rmse_rad=float(np.mean([t["joint_rmse_rad"] for t in trials])),
                    setpoint_noise_rms_rad=(squared_noise / count) ** .5,
                    saturated_latent_fraction=saturated / count, trials=trials,
                    incoming_sha256=hashlib.sha256(actor_path.read_bytes()).hexdigest())
                stream.write(json.dumps(dict(seed=seed, latent_std=std, dataset=runtime.dataset(episodes, collection["source_revision"])), allow_nan=False) + "\n")
                rows.append(row)
                print(json.dumps({k: v for k, v in row.items() if k != "trials"}), flush=True)
    report = dict(format="moonrobo.g1-temporal-ppo-noise.v1", config=config, rows=rows,
        log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
        scope="No learning: original incoming actors, same first PPO training reset per seed, coupled per-case noise streams. Separate diagnostic sampling cost, not PPO training samples. Only train families; no validation/test-based amplitude selection.",
        physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "collection", "policies", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
