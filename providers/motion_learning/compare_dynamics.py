"""Post-selection held-out prediction comparison on the old model's common scale."""
import argparse
import hashlib
import json
from pathlib import Path

import torch

from dynamics import WindowBatch, imagine, load_model


@torch.no_grad()
def common_metrics(model, batch, scale):
    predictions = torch.cat([imagine(model, batch.state[i:i + 128, 0], batch.action[i:i + 128], batch.context[i:i + 128])
                             for i in range(0, len(batch.state), 128)])
    errors = ((predictions - batch.target) / scale).square().mean(-1)
    persistence = ((batch.state[:, :1] - batch.target) / scale).square().mean(-1)
    late = batch.start_time_s >= 2
    return dict(windows=len(batch.state), normalized_state_mse=float(errors.mean()),
        persistence_mse=float(persistence.mean()), after_two_seconds=dict(windows=int(late.sum()),
            normalized_state_mse=float(errors[late].mean()) if late.any() else None))


def run(args):
    torch.set_num_threads(2)
    batches = {split: WindowBatch(getattr(args, split), split) for split in ["validation", "test"]}
    initial, metadata = load_model(args.initial)
    paths = [Path(args.initial)] + [Path(args.corrected) / f"dynamics-seed-{i}.pt" for i in range(3)]
    rows = []
    for i, path in enumerate(paths):
        model, meta = load_model(path)
        for key in ["model_ref", "dt_s", "state_axes", "action_axes", "context_axes", "frame_convention"]:
            for batch in batches.values():
                if meta["layout"][key] != batch.layout[key] or meta["layout"][key] != metadata["layout"][key]:
                    raise ValueError("incompatible common-scale prediction inputs")
        rows.append(dict(model="initial" if i == 0 else f"refitted-{i - 1}",
            checkpoint_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            metrics={split: common_metrics(model, batch, initial.state_scale) for split, batch in batches.items()}))
    report = dict(format="moonrobo.g1-common-scale-dynamics.v1", metric_scale="initial model train-only state scale",
        inputs={split: batch.digest for split, batch in batches.items()}, rows=rows,
        scope="Post-selection prediction diagnostics on identical held-out arrays and one shared scale; no physical-gradient or control qualification.")
    Path(args.output).write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(report))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["initial", "corrected", "validation", "test", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
