"""Independently reconstruct branch actions, controller memory and rewards."""
import argparse
import json
from pathlib import Path

import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from policy import observation
from reference_action_response import digest, reward_targets
from reference_actor import load_reference_actor, load_references
from reference_feedback_response import controller_memory, double_schedule, policy_action
from reference_learning import BODY
from reference_task import observer_advance, reference_reward


def run(args):
    folder = Path(args.study)
    report = json.loads((folder/"report.json").read_bytes())
    source = Path(report["source_study"])
    if digest(source/"report.json") != report["source_report_sha256"]: raise ValueError("response source changed")
    previous = json.loads((source/"report.json").read_bytes())
    old_source = Path(previous["source_study"])
    if digest(old_source/"report.json") != previous["source_report_sha256"]: raise ValueError("controller source changed")
    old = json.loads((old_source/"report.json").read_bytes())
    old_records = {r["episode_id"]: r for r in old["physical_records"]}
    conditions = {(c["method"], c["seed"], c["clip_index"], c["offset"]): c for c in previous["conditions"]}
    manifest, references = load_references(report["references"])
    if digest(Path(report["references"])/"manifest.json") != report["reference_manifest_sha256"]:
        raise ValueError("reference manifest changed")
    torch.set_num_threads(2)
    runtime = PhysicsRuntime(args.scene)
    actors, verified_inputs = {}, set()
    for record in report["physical_records"]:
        actor_path = record["geometry_checkpoint"]
        if actor_path not in actors:
            if digest(actor_path) != record["source_actor_sha256"]: raise ValueError("controller changed")
            actor, geometry, _ = load_reference_actor(actor_path)
            actor.double(); geometry.double()
            actors[actor_path] = actor, geometry, double_schedule(references, geometry)
        actor, geometry, schedule = actors[actor_path]
        path, input_path = folder/record["file"], folder/record["inputs"]
        if digest(path) != record["sha256"] or digest(input_path) != record["inputs_sha256"]:
            raise ValueError("branch or initial controller state changed")
        with np.load(path, allow_pickle=False) as archive: a = dict(archive)
        with np.load(input_path, allow_pickle=False) as archive: inputs = dict(archive)
        if record["inputs"] not in verified_inputs:
            condition = conditions[(record["method"], record["seed"], record["clip_index"], record["offset"])]
            snapshot_path = source/condition["snapshot"]
            if digest(snapshot_path) != condition["snapshot_sha256"]: raise ValueError("source snapshot changed")
            with np.load(snapshot_path, allow_pickle=False) as snapshot:
                for key in snapshot.files:
                    if not np.array_equal(inputs[key], snapshot[key]): raise ValueError("initial solver or control tape differs")
            original = old_records[record["source_episode_id"]]
            archive_path = old_source/original["file"]
            if digest(archive_path) != original["sha256"]: raise ValueError("causal history archive changed")
            with np.load(archive_path, allow_pickle=False) as original_arrays:
                offset = record["offset"]
                ids = np.maximum(offset-np.arange(actor.history_length-1, -1, -1), 0)
                expected = dict(history=original_arrays["observation"][ids][None].astype(np.float64),
                    actual_features=original_arrays["actual_features"][offset:offset+1].astype(np.float64),
                    reference_features=original_arrays["reference_features"][offset:offset+1].astype(np.float64))
                for key in expected:
                    if not np.array_equal(inputs[key], expected[key]): raise ValueError("controller does not restore original causal memory")
            verified_inputs.add(record["inputs"])
        n = record["steps"]
        if a["state"].dtype != np.float64 or not np.array_equal(a["state"][0], inputs["state"]) or not np.array_equal(a["state"][1:], a["next_state"][:-1]):
            raise ValueError("branch precision, initial state or continuity differs")
        direction = np.zeros((32, 29))
        if record["role"]=="counterfactual":
            direction_path = folder/record["direction_file"]
            if digest(direction_path) != record["direction_sha256"]: raise ValueError("control-tape direction changed")
            with np.load(direction_path, allow_pickle=False) as archive: direction = archive["direction"]
            if direction.shape != (32, 29) or abs(float(np.mean(direction**2))-1.) > 1e-12:
                raise ValueError("direction has wrong shape or RMS normalization")
        perturbation = record["amplitude"]*direction
        history, features, memory = controller_memory(inputs)
        expected_controls = []
        with torch.no_grad():
            for t in range(n):
                base = inputs["actions"][t] if record["execution_mode"]=="open-tape" else policy_action(actor, schedule, inputs, history, features, t)[0].numpy()
                expected_controls.append(runtime.clip_control(base+perturbation[t]))
                if record["execution_mode"]=="feedback":
                    obs = observation(torch.from_numpy(a["next_state"][t:t+1]), torch.from_numpy(a["applied_action"][t:t+1]), BODY)
                    features, memory = observer_advance(geometry, obs, memory, .02)
                    history = torch.cat((history[:, 1:], obs[:, None]), 1)
        action_error = float(np.max(np.abs(np.asarray(expected_controls)-a["applied_action"])))
        if action_error > 1e-10: raise ValueError("branch actions disagree with frozen tape/causal feedback law")
        _, reference = references[record["clip_index"]]
        targets = reward_targets(reference, record["offset"], n)
        with torch.no_grad():
            obs = torch.from_numpy(a["observation"])
            reward, fallen, _ = reference_reward(geometry, torch.from_numpy(a["next_state"]), torch.from_numpy(a["applied_action"]), obs[:, -29:], *targets)
            reward_error = float((reward-torch.from_numpy(a["reward"])).abs().max())
            expected_obs = observation(torch.from_numpy(a["state"]), obs[:, -29:], BODY)
            obs_error = float((expected_obs-obs).abs().max())
        if reward_error > 1e-12 or obs_error > 1e-10 or not np.array_equal(fallen.numpy(), a["terminated"]):
            raise ValueError("reward, observation or termination differs")
        expected_previous = inputs["observation"][-29:] if record["execution_mode"]=="open-tape" else inputs["history"][0, -1, -29:]
        if not np.array_equal(a["observation"][0, -29:], expected_previous) or not np.array_equal(a["observation"][1:, -29:], a["applied_action"][:-1]):
            raise ValueError("previous-control history differs")
        if a["terminated"][:-1].any() or a["truncated"][:-1].any() or not (a["terminated"][-1] or a["truncated"][-1]):
            raise ValueError("invalid branch boundary")
        if not a["terminated"][-1] and n != 32: raise ValueError("short unfallen branch")
        steps = [dict(time_s=i*.02, state=a["state"][i].tolist(), observation=a["observation"][i].tolist(),
            applied_action=a["applied_action"][i].tolist(), next_state=a["next_state"][i].tolist(),
            goal=reference.goals[record["offset"]+i+1].tolist(), reward=float(a["reward"][i]),
            terminated=bool(a["terminated"][i]), truncated=bool(a["truncated"][i])) for i in range(n)]
        episode = dict(id=record["episode_id"], source_family=record["source_family"], split="train", context=record["context"], steps=steps)
        dataset = runtime.dataset([episode], "reference-feedback-response")
        dataset.update(model_ref=manifest["model_ref"], goal_axes=manifest["layout"]["goal_axes"],
            provenance="Known-state H32 action-tape/causal-feedback response; float64 archives and explicitly restored controller memory")
        print(json.dumps(dict(record=record, dataset=dataset, verification=dict(action_error_rad=action_error,
            reward_error=reward_error, observation_error=obs_error)), allow_nan=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--study", required=True); parser.add_argument("--scene", required=True)
    run(parser.parse_args())
