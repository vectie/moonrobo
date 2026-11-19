"""Compare q/v integration residuals in held-out own-policy physics and models.

Trapezoidal integration is a diagnostic approximation to five MuJoCo substeps,
not an identity asserted of the physical simulator or a new qualification gate.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from dynamics import load_model


def run(args):
    folder = Path(args.study)
    report = json.loads((folder/"report.json").read_bytes())
    torch.set_num_threads(report["config"]["cpu_threads"])
    results = []
    with torch.no_grad():
        for seed in report["config"]["seeds"]:
            model_path = folder/f"model-based/seed-{seed}/policy/dynamics-cycle-3.pt"
            model, metadata = load_model(model_path)
            physics_joint, learned_joint, physics_root, learned_root = [], [], [], []
            records = [r for r in report["physical_records"] if r["role"]=="model-diagnostic" and r["seed"]==seed]
            ids = []
            for record in records:
                if record["episode_id"] in metadata["training_episode_ids"]:
                    raise ValueError("model diagnostic was fitted")
                path = folder/record["file"]
                if hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
                    raise ValueError("diagnostic physics changed")
                with np.load(path, allow_pickle=False) as archive: a = dict(archive)
                state = torch.from_numpy(a["state"]); target = torch.from_numpy(a["next_state"])
                predicted = model(state, torch.from_numpy(a["applied_action"]),
                    torch.tensor(record["context"], dtype=torch.float32)[None].expand(len(state), -1))
                physics_joint.append(target[:, 7:36]-state[:, 7:36]-.01*(state[:, 42:71]+target[:, 42:71]))
                learned_joint.append(predicted[:, 7:36]-state[:, 7:36]-.01*(state[:, 42:71]+predicted[:, 42:71]))
                physics_root.append(target[:, :3]-state[:, :3]-.01*(state[:, 36:39]+target[:, 36:39]))
                learned_root.append(predicted[:, :3]-state[:, :3]-.01*(state[:, 36:39]+predicted[:, 36:39]))
                ids.append(record["episode_id"])
            rms = lambda parts: float(torch.cat(parts).square().mean().sqrt())
            actual, learned = rms(physics_joint), rms(learned_joint)
            results.append(dict(seed=seed, diagnostic_episode_ids=ids, transitions=sum(len(v) for v in physics_joint),
                physics_joint_trapezoid_residual_rmse_rad=actual, model_joint_trapezoid_residual_rmse_rad=learned,
                joint_residual_ratio=learned/max(actual, 1e-12),
                physics_root_trapezoid_residual_rmse_m=rms(physics_root), model_root_trapezoid_residual_rmse_m=rms(learned_root),
                model_sha256=hashlib.sha256(model_path.read_bytes()).hexdigest()))
    result = dict(format="moonrobo.g1-reference-model-consistency.v1", results=results,
        source_report_sha256=hashlib.sha256((folder/"report.json").read_bytes()).hexdigest(),
        provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        scope="Post-training held-out one-step integration diagnostic. No source-control labels or refitting. Residual ratios do not prove physical Jacobian accuracy or policy stability.", physical_execution_allowed=False)
    (folder/"model-consistency.json").write_text(json.dumps(result, indent=2, allow_nan=False))
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--study", required=True)
    run(parser.parse_args())
