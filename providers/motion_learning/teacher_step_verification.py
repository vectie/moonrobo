"""Compare saved one-step teacher-only actors with previously measured deltas."""
import argparse
import hashlib
import json
from pathlib import Path

import torch

from actor_update_probe import scaled_actor
from temporal_actor import load_temporal


def run(args):
    rows = []
    for variant in ["frame", "preview"]:
        report = json.loads((Path(args.study) / variant / "policy/report.json").read_bytes())
        for result in report["runs"]:
            if result["selected_update"] != 1:
                continue
            seed = result["seed"]
            initial_path = Path(args.incoming) / variant / "policy" / f"actor-seed-{seed}.pt"
            direction_path = Path(args.probe) / variant / f"directions-seed-{seed}.pt"
            initial, _ = load_temporal(initial_path)
            selected, _ = load_temporal(Path(args.study) / variant / "policy" / result["checkpoint"])
            saved = torch.load(direction_path, weights_only=True)
            if saved["actor_sha256"] != hashlib.sha256(initial_path.read_bytes()).hexdigest():
                raise ValueError("teacher direction actor differs")
            predicted = scaled_actor(initial, saved["directions"]["draw-0-tail-True-teacher"], 1)
            errors = [float((value - selected.state_dict()[key]).abs().max()) for key, value in predicted.state_dict().items()]
            error = max(errors)
            if error > 1e-7:
                raise ValueError("teacher-only first update differs from the diagnosed parameter direction")
            rows.append(dict(variant=variant, seed=seed, maximum_parameter_error=error,
                bitwise_equal=all(torch.equal(value, selected.state_dict()[key]) for key, value in predicted.state_dict().items()),
                direction_sha256=hashlib.sha256(direction_path.read_bytes()).hexdigest()))
    Path(args.output).write_text(json.dumps(dict(format="moonrobo.g1-teacher-first-step-verification.v1", rows=rows), indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["study", "incoming", "probe", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
