"""Independently reproduce saved sustained heads from the recorded train corpus."""
import argparse
import gzip
import json
from pathlib import Path

import torch

from balance_features import sequence_features
from learned_balance import load_learned_balance
from learned_balance_study import digest
from sustained_balance import SustainedBalanceHead, load_sustained_balance
from temporal_actor import load_temporal


def run(folder):
    config = json.loads((folder / "config.json").read_bytes())
    report = json.loads((folder / "report.json").read_bytes())
    charter = json.loads((folder / "charter.json").read_bytes())
    collection = json.loads((Path(charter["original_balance_study"]) / "collection.json").read_bytes())
    allowed = {c["id"] for c in collection["cases"] if c["split"] == "train"}
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    first = folder / "policy" / f'actor-{config["variants"][0]["name"]}-seed-{config["seeds"][0]}.pt'
    parent, _, geometry, metadata = load_sustained_balance(first)
    arrays, ids = [[], [], [], []], []
    with gzip.open(folder / "teacher-training.jsonl.gz", "rt") as stream:
        for line in stream:
            record = json.loads(line)
            if record["role"] != "teacher-training":
                raise ValueError("non-training role in fit corpus")
            for episode, trial in zip(record["dataset"]["episodes"], record["trials"]):
                if episode["split"] != "train" or episode["case_id"] not in allowed or trial["seed"] not in config["training_reset_seeds"]:
                    raise ValueError("fit corpus includes a selection/audit/canonical condition")
                if episode["id"] != trial["episode_id"]:
                    raise ValueError("fit corpus identity differs")
                obs = torch.tensor([s["observation"] for s in episode["steps"]], dtype=torch.float32)
                arrays[0].append(obs)
                arrays[1].append(torch.tensor([s["goal"] for s in episode["steps"]], dtype=torch.float32))
                arrays[2].append(torch.tensor([s["applied_action"] for s in episode["steps"]], dtype=torch.float32))
                with torch.no_grad():
                    arrays[3].append(sequence_features(geometry, obs, metadata["dt_s"], window=None))
                ids.append(episode["id"])
    obs, goals, targets, features = [torch.cat(v) for v in arrays]
    if len(ids) != report["training_episodes"] or len(obs) != report["training_points"] or len(set(ids)) != len(ids):
        raise ValueError("fit corpus counts differ")
    fitted = {}
    for representation in ["range", "pose_rate"]:
        head = SustainedBalanceHead(metadata["kinematics"]["joint_names"], parent.base.lower, parent.base.upper,
            pose_rate=representation=="pose_rate", fit_bound=metadata["head_spec"]["fit_bound"])
        head.fit(obs, goals, targets, features, config["uncensored_margin_rad"])
        fitted[representation] = head
    checked = []
    for variant in config["variants"]:
        for seed in config["seeds"]:
            path = folder / "policy" / f'actor-{variant["name"]}-seed-{seed}.pt'
            _, restored, _, payload = load_sustained_balance(path)
            expected = fitted[variant["representation"]].state_dict()
            if any(not torch.equal(v, restored.state_dict()[k]) for k, v in expected.items()):
                raise ValueError("saved head cannot be reproduced exactly from train records")
            if payload["head_spec"]["output_bound"] != variant["output_bound"] or payload["head_spec"]["control_waist"] != variant["control_waist"]:
                raise ValueError("saved control intervention differs from the frozen variant")
            checked.append(dict(seed=seed, variant=variant["name"], checkpoint_sha256=digest(path), maximum_tensor_error=0.0))
    for loader in [load_temporal, load_learned_balance]:
        try:
            loader(first)
        except ValueError:
            pass
        else:
            raise ValueError("legacy loader accepted the v2 action mapping")
    result = dict(format="moonrobo.g1-sustained-balance-refit-verification.v1", training_episodes=len(ids), training_points=len(obs),
        training_sha256=digest(folder / "teacher-training.jsonl.gz"), training_episode_ids=ids,
        verified_checkpoints=checked, all_tensors_exact=True, legacy_loaders_reject_v2=True,
        provider_sha256=digest(__file__), physical_execution_allowed=False)
    (folder / "refit-verification.json").write_text(json.dumps(result, indent=2, allow_nan=False))
    print(json.dumps(dict(training_points=len(obs), verified_checkpoints=len(checked), all_tensors_exact=True)), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--study", required=True)
    run(Path(parser.parse_args().study))
