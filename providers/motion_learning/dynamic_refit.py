"""Refit a world model on validated actual-action streams with frozen units."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import time

import torch

from dynamics import WindowBatch, evaluate, gradient_probe, imagine, load_model, validation_score


class ActualActionBatch:
    def __init__(self, manifest_path):
        path = Path(manifest_path)
        raw = path.read_bytes(); manifest = json.loads(raw)
        if manifest["format"] != "moonrobo.g1-actual-action-streams.v1" or manifest["split"] != "train":
            raise ValueError("expected canonical-validated training streams")
        self.digest, self.layout = hashlib.sha256(raw).hexdigest(), manifest["layout"]
        self.horizon, stride = manifest["window_length"], manifest["stride"]
        parts = {key: [] for key in ["state", "action", "target", "context", "start_time_s"]}
        identities, self.sources, self.episodes, self.transitions = set(), [], 0, 0
        for source in manifest["sources"]:
            source_path = Path(source["path"])
            if hashlib.sha256(source_path.read_bytes()).hexdigest() != source["sha256"]:
                raise ValueError("actual-action source differs from native-validated bytes")
            counts = []
            if source["kind"] == "dataset":
                datasets = [json.loads(source_path.read_bytes())]
                for dataset in datasets:
                    counts.append(self.append(parts, dataset, identities, stride))
                del datasets, dataset
            elif source["kind"] == "student-jsonl-gzip":
                with gzip.open(source_path, "rt", encoding="utf-8") as stream:
                    for line in stream:
                        if line.strip():
                            # Counterfactual teacher_action_targets are deliberately not read.
                            counts.append(self.append(parts, json.loads(line)["dataset"], identities, stride))
            else:
                raise ValueError("unknown actual-action stream kind")
            expected = [(r["episodes"], r["transitions"]) for r in source["chunks"]]
            if counts != expected:
                raise ValueError("actual-action stream counts differ from native validation")
            self.sources.append(dict(path=str(source_path), sha256=source["sha256"], chunks=len(counts)))
            print(json.dumps(dict(loaded=str(source_path), chunks=len(counts))), flush=True)
        if self.episodes != manifest["episodes"]:
            raise ValueError("native/numerical episode counts differ")
        for key, values in parts.items():
            if not values:
                raise ValueError("no complete actual-action windows")
            setattr(self, key, torch.cat(values))

    def append(self, parts, dataset, identities, stride):
        for key in ["model_ref", "dt_s", "frame_convention", "state_axes", "action_axes", "context_axes"]:
            if dataset[key] != self.layout[key]:
                raise ValueError("actual-action layout differs: " + key)
        transitions = 0
        for episode in dataset["episodes"]:
            if episode["split"] != "train" or episode["id"] in identities:
                raise ValueError("held-out or duplicate actual-action episode")
            identities.add(episode["id"])
            steps = episode["steps"]; transitions += len(steps)
            if any(s["terminated"] or s["truncated"] for s in steps[:-1]):
                raise ValueError("actual-action window would cross an episode reset")
            final = len(steps) - self.horizon
            if final < 0:
                continue
            ids = list(range(0, final + 1, stride))
            if ids[-1] != final:
                ids.append(final)
            times = torch.tensor([s["time_s"] for s in steps], dtype=torch.float64)
            valid = (times.unfold(0, self.horizon, 1)[ids].diff(dim=1) - self.layout["dt_s"]).abs().max(1).values <= self.layout["dt_s"] * 1e-6
            indices = torch.tensor(ids)[valid]
            if not len(indices):
                continue
            for key, source, axes in [("state", "state", "state_axes"), ("action", "applied_action", "action_axes"), ("target", "next_state", "state_axes")]:
                tensor = torch.tensor([s[source] for s in steps], dtype=torch.float32)
                if tensor.shape[1] != len(self.layout[axes]) or not torch.isfinite(tensor).all():
                    raise ValueError("actual-action numeric dimensions differ")
                parts[key].append(tensor.unfold(0, self.horizon, 1).transpose(1, 2)[indices])
            parts["context"].append(torch.tensor(episode["context"], dtype=torch.float32)[None].expand(len(indices), -1))
            parts["start_time_s"].append(times[indices])
        self.episodes += len(dataset["episodes"]); self.transitions += transitions
        return len(dataset["episodes"]), transitions


def refit(initial, metadata, original, added, validation, test, config, seed, arm, directory, manifest_path):
    model = copy.deepcopy(initial)
    frozen_buffers = {k: v.clone() for k, v in model.named_buffers()}
    for p in model.parameters():
        p.requires_grad_(True)
    optimizer = torch.optim.Adam(model.parameters(), lr=config["learning_rate"])
    old_generator = torch.Generator().manual_seed(config["sampling_seed"] + seed)
    new_generator = torch.Generator().manual_seed(config["sampling_seed"] + 10000 + seed)
    initial_metrics = evaluate(model, validation)
    best_score, best, selected = validation_score(initial_metrics, config), copy.deepcopy(model.state_dict()), 0
    history = [dict(update=0, validation=initial_metrics, selection_score=best_score)]
    start = time.perf_counter()
    for update in range(1, config["updates"] + 1):
        old_ids = torch.randint(len(original.state), (config["batch_size"],), generator=old_generator)
        if arm == "mixed":
            half = config["batch_size"] // 2
            new_ids = torch.randint(len(added.state), (config["batch_size"] - half,), generator=new_generator)
            state, action, target, context = [torch.cat((getattr(original, key)[old_ids[:half]], getattr(added, key)[new_ids]))
                for key in ["state", "action", "target", "context"]]
        else:
            state, action, target, context = [getattr(original, key)[old_ids] for key in ["state", "action", "target", "context"]]
        loss = ((imagine(model, state[:, 0], action, context) - target) / model.state_scale).square().mean()
        if not torch.isfinite(loss):
            raise ValueError("nonfinite dynamic refit loss")
        optimizer.zero_grad(); loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1); optimizer.step()
        if update % config["evaluate_every"] == 0:
            metrics = evaluate(model, validation); score = validation_score(metrics, config)
            history.append(dict(update=update, loss=float(loss.detach()), validation=metrics, selection_score=score))
            if score < best_score:
                best_score, best, selected = score, copy.deepcopy(model.state_dict()), update
            print(json.dumps(dict(arm=arm, seed=seed, update=update, selection_score=score)), flush=True)
    seconds = time.perf_counter() - start
    spec = dict(format="moonrobo.g1-dynamics-refit-input.v1", arm=arm, base_batch_sha256=original.digest,
        parent_dynamics_training_batch_sha256=metadata["training_batch_sha256"],
        added_streams_manifest_sha256=added.digest if arm == "mixed" else None,
        added_streams_manifest=str(manifest_path) if arm == "mixed" else None,
        initial_dynamics_sha256=config["initial_dynamics_sha256"], config=config)
    directory.mkdir(parents=True, exist_ok=True)
    input_path = directory / "training-input.json"
    input_path.write_text(json.dumps(spec, indent=2, allow_nan=False))
    training_sha = hashlib.sha256(input_path.read_bytes()).hexdigest()
    def checkpoint(weights, update, path):
        torch.save({**metadata, "model": weights, "seed": seed, "selected_update": update,
            "config": {**metadata["config"], "refit": config}, "training_batch_sha256": training_sha,
            "parent_training_batch_sha256": original.digest, "refit_arm": arm,
            "normalization_source": "unchanged incoming sustained training normalization"}, path)
    latest = f"latest-dynamics-seed-{seed}.pt"
    checkpoint(model.state_dict(), config["updates"], directory / latest)
    model.load_state_dict(best)
    if any(not torch.equal(v, dict(model.named_buffers())[k]) for k, v in frozen_buffers.items()):
        raise ValueError("dynamic refit changed normalization")
    metrics = {"old_train": evaluate(model, original), "added_train": evaluate(model, added),
        "validation": evaluate(model, validation), "test": evaluate(model, test)}
    name = f"dynamics-seed-{seed}.pt"
    checkpoint(best, selected, directory / name)
    reloaded, _ = load_model(directory / name)
    if evaluate(reloaded, test) != metrics["test"]:
        raise ValueError("dynamic refit checkpoint reload differs")
    return dict(seed=seed, selected_update=selected, training_seconds=seconds, checkpoint=name, latest_checkpoint=latest,
        history=history, metrics=metrics, gradient_probe=gradient_probe(model, validation), reload_matches=True,
        normalization_unchanged=True, training_input_sha256=training_sha)


def run(args):
    config = json.loads(Path(args.config).read_text())
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    manifest_path = Path(args.manifest)
    manifest = json.loads(manifest_path.read_bytes())
    original = WindowBatch(manifest["base_batch"]["path"], "train")
    initial, metadata = load_model(args.initial)
    if original.digest != manifest["base_batch"]["sha256"] or original.digest != metadata["training_batch_sha256"] or original.layout != metadata["layout"]:
        raise ValueError("base replay differs from initial world-model training")
    validation, test = WindowBatch(args.validation, "validation"), WindowBatch(args.test, "test")
    original.compatible(validation); original.compatible(test)
    added = ActualActionBatch(manifest_path)
    if added.layout != original.layout or added.horizon != original.horizon:
        raise ValueError("new stream replay differs from original physical schema")
    config["initial_dynamics_sha256"] = hashlib.sha256(Path(args.initial).read_bytes()).hexdigest()
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    for arm in ["old-only", "mixed"]:
        directory = output / arm
        runs = [refit(initial, metadata, original, added, validation, test, config, seed, arm, directory, manifest_path)
            for seed in config["seeds"]]
        report = dict(format="moonrobo.dynamics-fit.v1", config=config, arm=arm, runs=runs, horizon=original.horizon,
            normalization_source="unchanged incoming sustained training normalization", selection_source="canonical validation only, including update zero",
            added_dataset=dict(episodes=added.episodes, transitions=added.transitions, windows=len(added.state),
                late_windows=int((added.start_time_s >= 2).sum()), manifest_sha256=added.digest, sources=added.sources),
            canonical_inputs={"validation": validation.digest, "test": test.digest},
            initial_dynamics_sha256=config["initial_dynamics_sha256"], base_batch_sha256=original.digest,
            provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), physical_execution_allowed=False)
        (directory / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "manifest", "initial", "validation", "test", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
