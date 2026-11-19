"""Decode saved numeric physics records and independently recompute tracking metrics.

Streams one typed dataset per line; MoonBit owns invocation, native validation
and artifact bookkeeping. Does not replay a learned policy or restore later states.
"""
import argparse
import hashlib
import json
from pathlib import Path

import mujoco
import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from full_body_reference import FullBodyReference


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(args):
    folder, references = Path(args.study), Path(args.references)
    report = json.loads((folder/"report.json").read_bytes())
    manifest = json.loads((references/"manifest.json").read_bytes())
    if digest(references/"manifest.json") != report["reference_manifest_sha256"]:
        raise ValueError("reference manifest changed")
    model_checks = []
    for fit in report["fits"]:
        checkpoint = folder/fit["checkpoint"]
        if digest(checkpoint) != fit["checkpoint_sha256"]:
            raise ValueError("fitted actor changed")
        saved = torch.load(checkpoint, weights_only=True)
        if saved["format"] != "moonrobo.g1-reference-actor.v1" or saved["provenance"]["reference_manifest_sha256"] != report["reference_manifest_sha256"]:
            raise ValueError("fitted actor has incompatible reference provenance")
        weights = saved["state_dict"]["decoder.0.weight"]
        maximum = float(weights[:, saved["architecture"]["latent_dim"]:].abs().max())
        if report["config"].get("reference_only_initialization", False) and maximum != 0:
            raise ValueError("reference-only initialization leaked an observation decoder weight")
        model_checks.append(dict(seed=fit["seed"], observation_decoder_input_max_weight=maximum))
    runtime = PhysicsRuntime(args.scene, manifest["layout"]["dt_s"])
    loaded = {}
    for evaluation in report["evaluations"]+[report["baseline"]]:
        by_id = {trial["episode_id"]: trial for trial in evaluation["trials"]}
        for record in evaluation["records"]:
            path = folder/record["file"]
            if digest(path) != record["sha256"]:
                raise ValueError("saved physical trajectory changed")
            clip = next(c for c in manifest["clips"] if c["id"] == record["reference_id"])
            if clip["sha256"] != record["reference_sha256"]:
                raise ValueError("trajectory reference changed")
            if clip["id"] not in loaded:
                if digest(references/clip["file"]) != clip["sha256"]:
                    raise ValueError("reference clip bytes changed")
                with np.load(references/clip["file"], allow_pickle=False) as archive:
                    loaded[clip["id"]] = FullBodyReference(dict(archive), manifest["layout"])
            reference = loaded[clip["id"]]
            with np.load(path, allow_pickle=False) as archive:
                a = dict(archive)
            trial = by_id[record["episode_id"]]
            count, origin = record["steps"], record["origin_step"]
            if len(a["state"]) != count or not np.array_equal(a["state"][1:], a["next_state"][:-1]):
                raise ValueError("trajectory lost state continuity")
            goals = reference.goals[origin+1:origin+count+1]
            target = reference.arrays["state"][origin+1:origin+count+1]
            q_error = float(np.sqrt(np.mean((a["next_state"][:, runtime.q_indices]-target[:, runtime.q_indices])**2)))
            body_errors, root_errors, angles = [], [], []
            for i, state in enumerate(a["next_state"]):
                runtime.data.qpos[:] = state[:runtime.model.nq]
                mujoco.mj_kinematics(runtime.model, runtime.data)
                desired_p = reference.arrays["body_position"][origin+i+1]
                body_errors.append(float(np.mean(np.sum((runtime.data.xpos[1:]-desired_p)**2, axis=-1))))
                root_errors.append(float(np.sum((runtime.data.xpos[runtime.root]-desired_p[runtime.root-1])**2)))
                actual_r = runtime.data.xmat[runtime.root].reshape(3, 3)
                desired_r = reference.arrays["body_rotation"][origin+i+1, runtime.root-1]
                angles.append(float(np.arccos(np.clip((np.trace(desired_r @ actual_r.T)-1)/2, -1, 1)))**2)
            recomputed = dict(joint_rmse_rad=q_error, body_position_rmse_m=float(np.sqrt(np.mean(body_errors))),
                root_position_rmse_m=float(np.sqrt(np.mean(root_errors))), root_orientation_rmse_rad=float(np.sqrt(np.mean(angles))))
            differences = {key: abs(value-trial[key]) for key, value in recomputed.items()}
            if max(differences.values()) > 1e-10 or not np.allclose(a["reward"], np.exp(-np.asarray(body_errors)/.09), atol=1e-12, rtol=0):
                raise ValueError("recorded tracking metrics disagree with saved physics")
            steps = [dict(time_s=i*runtime.dt, state=a["state"][i].tolist(), observation=a["observation"][i].tolist(),
                applied_action=a["applied_action"][i].tolist(), next_state=a["next_state"][i].tolist(), goal=goals[i].tolist(),
                reward=float(a["reward"][i]), terminated=bool(a["terminated"][i]), truncated=bool(a["truncated"][i])) for i in range(count)]
            episode = dict(id=record["episode_id"], source_family=record["source_family"], split=record["split"],
                context=record["context"], steps=steps, case_id=record["reference_id"])
            dataset = runtime.dataset([episode], "reference-manifest:"+report["reference_manifest_sha256"])
            dataset.update(model_ref=manifest["model_ref"], dataset_id="g1-reference-initialization",
                goal_axes=manifest["layout"]["goal_axes"], provenance="Recorded physical policy trajectory; reference-control labels excluded from goal")
            print(json.dumps(dict(label=evaluation["label"], record=record, trial=trial, dataset=dataset,
                model_checks=model_checks, recomputed_metric_differences=differences), allow_nan=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["study", "references", "scene"]:
        parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
