"""Reconstruct root-diagnostic policy probes and emit actual typed transitions."""
import argparse
import json
from pathlib import Path

import numpy as np
import torch
from torch.nn.utils import parameters_to_vector, vector_to_parameters

from balance_features import sequence_features
from cpu_physics import PhysicsRuntime
from reference_actor import load_reference_actor, load_references, reference_observation
from reference_root_integration import digest
from reference_task import ReferenceSchedule, reference_reward


def run(args):
    folder = Path(args.study); report = json.loads((folder/"report.json").read_bytes())
    source = json.loads((Path(report["source_study"])/"report.json").read_bytes())
    config = source["config"]; torch.set_num_threads(config["cpu_threads"])
    manifest, references = load_references(report["references"])
    actor, geometry, _ = load_reference_actor(folder/"initial/actor-zero-output.pt")
    base = parameters_to_vector(actor.parameters()).detach().clone()
    schedule = ReferenceSchedule(references, geometry, [0]); runtime = PhysicsRuntime(args.scene)
    returns_by_id = {trial["episode_id"]: result for trial, result in zip(report["baseline_trials"], report["baseline_returns"])}
    for row in report["runs"]:
        if digest(folder/row["checkpoint"]) != row["checkpoint_sha256"]: raise ValueError("model changed")
        if digest(folder/row["direction_file"]) != row["direction_sha256"]: raise ValueError("direction changed")
        if digest(row["critic"]["file"]) != row["critic"]["sha256"]: raise ValueError("critic changed")
        for outcome in row["outcomes"]:
            if abs(outcome["achieved_logit_rms"]-outcome["logit_rms_target"]) > 1e-5:
                raise ValueError("probe amplitude disagrees with calibration")
            for trial, result in zip(outcome["trials"], outcome["returns"]): returns_by_id[trial["episode_id"]] = result
    for record in report["physical_records"]:
        path = folder/record["file"]; behavior = record["behavior"]
        if digest(path) != record["sha256"] or digest(folder/behavior["checkpoint"]) != behavior["sha256"]:
            raise ValueError("probe bytes changed")
        if record["action_std"] != 0 or record["origin_step"] != 0: raise ValueError("unexpected probe law")
        vector_to_parameters(base.clone(), actor.parameters())
        if "direction_file" in behavior:
            direction_path = folder/behavior["direction_file"]
            if digest(direction_path) != behavior["direction_sha256"]: raise ValueError("probe direction changed")
            data = torch.load(direction_path, weights_only=True)
            if data["base_actor_sha256"] != behavior["sha256"] or data["parameter_names"] != [n for n, _ in actor.named_parameters()]:
                raise ValueError("probe direction refers to another actor")
            vector_to_parameters(base+behavior["coefficient"]*data["direction"], actor.parameters())
        with np.load(path, allow_pickle=False) as f: a = {k: torch.from_numpy(f[k]) for k in f.files}
        n, c = record["steps"], record["clip_index"]
        if a["state"].dtype != torch.float32 or not torch.equal(a["state"][1:], a["next_state"][:-1]):
            raise ValueError("probe continuity or dtype differs")
        phases, clips = torch.arange(n), torch.full((n,), c, dtype=torch.long)
        current, future, valid = schedule.command(clips, phases, actor.future_length)
        obs = a["observation"]
        history = obs[(torch.arange(n)[:, None]-torch.arange(actor.history_length-1, -1, -1)[None]).clamp_min(0)]
        with torch.no_grad():
            actual = sequence_features(geometry, obs, schedule.dt, window=None)
            desired = sequence_features(geometry, reference_observation(current), schedule.dt, window=None)
            means, actions = [], []
            for first in range(0, n, 256):
                ids = slice(first, first+256)
                means.append(actor.latent_mean(history[ids], current[ids], future[ids], valid[ids]))
                actions.append(actor(history[ids], current[ids], future[ids], valid[ids], actual[ids], desired[ids]))
            mean_error = float((torch.cat(means)-a["latent"]).abs().max())
            action_error = float((torch.cat(actions)-a["applied_action"]).abs().max())
            feature_error = max(float((actual-a["actual_features"]).abs().max()), float((desired-a["reference_features"]).abs().max()))
            reward, fallen, _ = reference_reward(geometry, a["next_state"], a["applied_action"], obs[:, -29:],
                schedule.positions[clips, phases+1], schedule.quaternions[clips, phases+1], schedule.goals[clips, phases+1, :29], schedule.dt)
            reward_error = float((reward-a["reward"]).abs().max())
            if mean_error > 8e-5 or action_error > config["maximum_action_alignment_error_rad"] or feature_error > config["maximum_feature_alignment_error"]:
                raise ValueError("saved policy probe does not reconstruct")
            if reward_error > 1e-6 or not torch.equal(fallen, a["terminated"]): raise ValueError("reward/fall mismatch")
            weights = config["gamma"]**torch.arange(n, dtype=torch.float64)
            reward = reward.double(); expected = returns_by_id[record["episode_id"]]
            if max(abs(float((reward*weights).sum())-expected["full_return"]),
                abs(float((reward[:32]*weights[:32]).sum())-expected["prefix_return"])) > 1e-10:
                raise ValueError("physical return differs from archived reward")
        steps = [dict(time_s=i*schedule.dt, state=a["state"][i].tolist(), observation=obs[i].tolist(),
            applied_action=a["applied_action"][i].tolist(), next_state=a["next_state"][i].tolist(),
            goal=references[c][1].goals[i+1].tolist(), reward=float(a["reward"][i]),
            terminated=bool(a["terminated"][i]), truncated=bool(a["truncated"][i])) for i in range(n)]
        dataset_id = "reference-tail-directions" if report["format"]=="moonrobo.g1-reference-tail-directions.v1" else "reference-root-integration"
        dataset = runtime.dataset([dict(id=record["episode_id"], source_family=record["source_family"], split="train",
            context=record["context"], steps=steps)], dataset_id)
        dataset.update(model_ref=manifest["model_ref"], goal_axes=manifest["layout"]["goal_axes"])
        print(json.dumps(dict(record=record, dataset=dataset, maxima=dict(actor_mean_error=mean_error,
            action_error_rad=action_error, feature_error=feature_error, reward_error=reward_error)),
            allow_nan=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--study", required=True); parser.add_argument("--scene", required=True)
    run(parser.parse_args())
