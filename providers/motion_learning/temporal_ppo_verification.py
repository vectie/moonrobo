"""Recompute temporal PPO's physical-return targets and applied latent actions."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import torch

from cpu_physics import PhysicsRuntime
from temporal_actor import load_temporal
from temporal_ppo import discounted_visitation
from temporal_value import episode_value_points
from policy import step_reward


def run(args):
    study = Path(args.study)
    report = json.loads((study / "policy/report.json").read_bytes())
    config, collection = report["config"], report["collection_experiment"]
    torch.set_num_threads(config["cpu_threads"])
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    cases = {c["id"]: c for c in collection["cases"]}
    rows = []
    for result in report["runs"]:
        seed = result["seed"]
        actor, _ = load_temporal(Path(args.incoming) / f"actor-seed-{seed}.pt")
        path = study / "policy" / result["physics_log"]["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != result["physics_log"]["sha256"]:
            raise ValueError("PPO physics log bytes changed")
        episodes, transitions, falls, records, max_action_error = 0, 0, 0, 0, 0.0
        identifiers = set()
        sensitivity, saturated, latent_count = 0., 0, 0
        with gzip.open(path, "rt") as stream:
            for index, line in enumerate(stream):
                record = json.loads(line)
                if record["iteration"] != index + 1 or record["reset_seed"] != config["collect_seed_base"] + 10000 * seed + index:
                    raise ValueError("PPO reset/collection order differs")
                entries = record["dataset"]["episodes"]
                if [e["case_id"] for e in entries] != list(cases):
                    raise ValueError("PPO collection case coverage differs")
                count, batch_falls = 0, 0
                for episode in entries:
                    if episode["split"] != "train" or episode["source_family"] != cases[episode["case_id"]]["family"]:
                        raise ValueError("PPO physics log includes non-training episodes")
                    if episode["id"] in identifiers:
                        raise ValueError("PPO repeated physical episode")
                    identifiers.add(episode["id"])
                    points, targets = episode_value_points(runtime, episode, cases[episode["case_id"]], actor, config)
                    size = len(targets)
                    sl = slice(count, count + size)
                    latent = torch.tensor(record["latent_samples"][sl])
                    means = torch.tensor(record["behavior_latent_means"][sl])
                    actions = torch.tensor([s["applied_action"] for s in episode["steps"]], dtype=torch.float32)
                    expected = actor.base.action_from_latent(latent, points[2][:, 0])
                    max_action_error = max(max_action_error, float((actions - expected).abs().max()))
                    torch.testing.assert_close(actions, expected, rtol=0, atol=0)
                    next_state = torch.tensor([s["next_state"] for s in episode["steps"]], dtype=torch.float32)
                    reward, continuation = step_reward(next_state, actions, points[1][:, -1, -runtime.model.nu:],
                        points[2][:, 0], actor.body["q_indices"], config["target_height_m"])
                    for key, expected in [("finite_return_targets", targets), ("objective_rewards", reward),
                            ("soft_continuation", continuation), ("discounted_visitation", discounted_visitation(continuation, config["gamma"]))]:
                        torch.testing.assert_close(torch.tensor(record[key][sl]), expected, atol=1e-5, rtol=1e-6)
                    if size > 1:
                        torch.testing.assert_close(points[1][1:, -1, -runtime.model.nu:], actions[:-1], rtol=0, atol=0)
                    sensitivity += float((1 - means.tanh().square()).sum())
                    saturated += int((means.abs() > 3).sum())
                    latent_count += means.numel()
                    if not all(not (s["terminated"] or s["truncated"]) for s in episode["steps"][:-1]):
                        raise ValueError("PPO physical episode crosses reset")
                    last = episode["steps"][-1]
                    if not (last["terminated"] or last["truncated"]):
                        raise ValueError("PPO finite episode has no terminal boundary")
                    count += size; batch_falls += int(last["terminated"])
                if any(len(record[key]) != count for key in ["latent_samples", "behavior_latent_means", "finite_return_targets", "objective_rewards", "soft_continuation", "discounted_visitation"]):
                    raise ValueError("PPO numerical targets/action counts differ")
                history = result["history"][index + 1]
                if history["collection_transitions"] != count or history["collection_falls"] != batch_falls:
                    raise ValueError("PPO history does not match actual sampling")
                episodes += len(entries); transitions += count; falls += batch_falls; records += 1
        if (records, episodes, transitions, falls) != (config["iterations"], result["training_episodes"], result["training_transitions"], result["training_falls"]):
            raise ValueError("PPO actual training totals differ")
        rows.append(dict(seed=seed, records=records, episodes=episodes, transitions=transitions, falls=falls,
            time_limits=episodes - falls, maximum_applied_action_error=max_action_error,
            saturated_behavior_latent_fraction=saturated / latent_count,
            mean_tanh_action_sensitivity=sensitivity / latent_count))
    Path(args.output).write_text(json.dumps(dict(format="moonrobo.g1-temporal-ppo-numerical-verification.v1", rows=rows,
        scope="Every saved training episode: actual latent-to-setpoint transform, causal previous action, full objective reward, finite MC target and discounted soft-survival visitation. Scalar targets recomputed in physical units; no learned transition inference.",
        physical_execution_allowed=False), indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["study", "incoming", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
