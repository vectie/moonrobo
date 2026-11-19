"""Differentiable residual dynamics trained on MoonBit-materialized windows."""

import argparse
import copy
import hashlib
import gzip
import json
from pathlib import Path
import time

import torch
from torch import nn
from torch.nn import functional as F


class WindowBatch:
    def __init__(self, path, split):
        self.path = Path(path)
        raw = self.path.read_bytes()
        self.storage_digest = hashlib.sha256(raw).hexdigest()
        if self.path.suffix == ".gz":
            raw = gzip.decompress(raw)
        self.digest = hashlib.sha256(raw).hexdigest()
        data = json.loads(raw)
        if data["format"] == "moonrobo.training-batch-shards.v1":
            if data["split"] != split or not data["shards"]:
                raise ValueError("nonempty shards for the requested split required")
            self.layout, self.horizon = data["layout"], data["window_length"]
            parts = []
            for item in data["shards"]:
                part = WindowBatch(self.path.parent / item["file"], split)
                if (part.digest != item["sha256"] or part.layout != self.layout or
                    part.horizon != self.horizon or len(part.state) != item["windows"]):
                    raise ValueError("training shard differs from its manifest")
                parts.append(part)
            for field in ["state", "action", "target", "observation", "goal", "start_time_s", "context"]:
                setattr(self, field, torch.cat([getattr(part, field) for part in parts]))
            return
        if data["format"] != "moonrobo.training-batch.v1" or data["split"] != split:
            raise ValueError("expected a MoonBit training batch for " + split)
        self.layout = data["layout"]
        n, self.horizon = len(data["windows"]), data["window_length"]
        if n < 1 or self.horizon < 1:
            raise ValueError("nonempty fixed-length windows required")
        def tensor(field, axes):
            value = torch.tensor(data[field], dtype=torch.float32).reshape(n, self.horizon, len(self.layout[axes]))
            if not torch.isfinite(value).all():
                raise ValueError("nonfinite tensor: " + field)
            return value
        self.state = tensor("state", "state_axes")
        self.action = tensor("applied_action", "action_axes")
        self.target = tensor("next_state", "state_axes")
        self.observation = tensor("observation", "observation_axes")
        self.goal = tensor("goal", "goal_axes")
        self.start_time_s = torch.tensor(data["time_s"], dtype=torch.float64).reshape(n, self.horizon)[:, 0]
        if not torch.isfinite(self.start_time_s).all():
            raise ValueError("nonfinite window time")
        self.context = torch.tensor(data["context"], dtype=torch.float32).reshape(n, len(self.layout["context_axes"]))
        if not torch.isfinite(self.context).all():
            raise ValueError("nonfinite context")

    def compatible(self, other, require_dataset_id=True):
        for field in ["dataset_id", "model_ref", "dt_s", "state_axes", "action_axes", "context_axes", "frame_convention"]:
            if field == "dataset_id" and not require_dataset_id:
                continue
            if self.layout[field] != other.layout[field]:
                raise ValueError("incompatible learning layout: " + field)
        if self.horizon != other.horizon:
            raise ValueError("window horizons differ")


class ResidualDynamics(nn.Module):
    def __init__(self, stats, width, horizontal_translation_invariant=False):
        super().__init__()
        self.horizontal_translation_invariant = horizontal_translation_invariant
        for name, value in stats.items():
            self.register_buffer(name, value.clone())
        ns, na, nc = len(self.state_mean), len(self.action_mean), len(self.context_mean)
        self.net = nn.Sequential(nn.Linear(ns + na + nc, width), nn.SiLU(),
                                 nn.Linear(width, width), nn.SiLU(), nn.Linear(width, ns))
        nn.init.zeros_(self.net[-1].weight)
        nn.init.zeros_(self.net[-1].bias)

    def forward(self, state, action, context):
        state_inputs = (state - self.state_mean) / self.state_scale
        if self.horizontal_translation_invariant:
            # An infinite flat plane has no distinguished global horizontal
            # origin. Predict increments without the root's absolute X/Y;
            # adding them to the incoming state preserves translated outputs.
            state_inputs = torch.cat((torch.zeros_like(state_inputs[..., :2]), state_inputs[..., 2:]), dim=-1)
        inputs = torch.cat((state_inputs,
                            (action - self.action_mean) / self.action_scale,
                            (context - self.context_mean) / self.context_scale), dim=-1)
        next_state = state + self.net(inputs) * self.state_scale
        # This initial provider explicitly targets the G1 qpos layout:
        # root translation [0:3], wxyz [3:7], scalar joints, qvel.
        quat = F.normalize(next_state[..., 3:7], dim=-1)
        return torch.cat((next_state[..., :3], quat, next_state[..., 7:]), dim=-1)


def fit_stats(train, floor):
    stats = {}
    for name, values in [("state", train.state.flatten(0, 1)),
                         ("action", train.action.flatten(0, 1)), ("context", train.context)]:
        stats[name + "_mean"] = values.mean(dim=0)
        stats[name + "_scale"] = values.std(dim=0, unbiased=False).clamp_min(floor)
    return stats


def imagine(model, initial, actions, context):
    state, predicted = initial, []
    for t in range(actions.shape[1]):
        state = model(state, actions[:, t], context)
        predicted.append(state)
    return torch.stack(predicted, dim=1)


@torch.no_grad()
def evaluate(model, batch):
    sums = torch.zeros(batch.horizon)
    baseline = torch.zeros(batch.horizon)
    late_sums, late_baseline, late_count = torch.zeros(batch.horizon), torch.zeros(batch.horizon), 0
    for start in range(0, len(batch.state), 128):
        initial = batch.state[start:start + 128, 0]
        truth = batch.target[start:start + 128]
        prediction = imagine(model, initial, batch.action[start:start + 128], batch.context[start:start + 128])
        errors = ((prediction - truth) / model.state_scale).square().mean(dim=-1)
        persistence_errors = ((initial[:, None] - truth) / model.state_scale).square().mean(dim=-1)
        sums += errors.sum(dim=0)
        baseline += persistence_errors.sum(dim=0)
        late = batch.start_time_s[start:start + 128] >= 2.0
        late_sums += errors[late].sum(dim=0)
        late_baseline += persistence_errors[late].sum(dim=0)
        late_count += int(late.sum())
    learned, persistence = sums / len(batch.state), baseline / len(batch.state)
    return dict(windows=len(batch.state), normalized_state_mse=float(learned.mean()),
                persistence_mse=float(persistence.mean()), per_step_mse=learned.tolist(),
                persistence_per_step_mse=persistence.tolist(),
                beats_persistence=bool(learned.mean() < persistence.mean()),
                after_two_seconds=dict(windows=late_count,
                  normalized_state_mse=float(late_sums.mean() / late_count) if late_count else None,
                  persistence_mse=float(late_baseline.mean() / late_count) if late_count else None,
                  beats_persistence=bool(late_sums.mean() < late_baseline.mean()) if late_count else None))


def gradient_probe(model, batch):
    # Input gradients survive freezing the weights. A finite-difference probe
    # tests autodiff implementation, not agreement with physical Jacobians.
    probe = copy.deepcopy(model).double()
    for parameter in probe.parameters():
        parameter.requires_grad_(False)
        parameter.grad = None
    state = batch.state[:1, 0].double().clone().requires_grad_(True)
    action = batch.action[:1].double().clone().requires_grad_(True)
    context = batch.context[:1].double()
    weights = torch.linspace(0.1, 1, state.shape[-1], dtype=torch.float64)
    scalar = (imagine(probe, state, action, context)[:, -1] * weights).sum()
    state_grad, action_grad = torch.autograd.grad(scalar, (state, action))
    direction = torch.linspace(-1, 1, action.numel(), dtype=torch.float64).reshape_as(action)
    epsilon = 1e-6
    with torch.no_grad():
        plus = (imagine(probe, state, action + epsilon * direction, context)[:, -1] * weights).sum()
        minus = (imagine(probe, state, action - epsilon * direction, context)[:, -1] * weights).sum()
    analytic = float((action_grad * direction).sum())
    numeric = float((plus - minus) / (2 * epsilon))
    passed = bool(torch.isfinite(state_grad).all() and torch.isfinite(action_grad).all()
                  and action_grad.norm() > 0 and state_grad.norm() > 0
                  and abs(analytic - numeric) < 1e-5 + 1e-3 * abs(numeric)
                  and all(p.grad is None for p in probe.parameters()))
    return dict(passed=passed, horizon=batch.horizon, action_gradient_norm=float(action_grad.norm()),
                state_gradient_norm=float(state_grad.norm()), analytic_directional=analytic,
                finite_difference_directional=numeric, frozen_parameter_gradients=True)


def load_model(path):
    """Load inference weights and training-only normalization without datasets."""
    checkpoint = torch.load(path, weights_only=True)
    encoding = checkpoint["config"].get("horizontal_translation_invariant", False)
    expected_format = "moonrobo.residual-dynamics.v2" if encoding else "moonrobo.residual-dynamics.v1"
    if checkpoint["format"] != expected_format:
        raise ValueError("dynamics checkpoint format does not match its input encoding")
    stats = {name: checkpoint["model"][name] for name in
             ["state_mean", "state_scale", "action_mean", "action_scale", "context_mean", "context_scale"]}
    model = ResidualDynamics(stats, checkpoint["config"]["hidden_width"], encoding)
    model.load_state_dict(checkpoint["model"])
    model.eval()
    return model, checkpoint


def sampling_pools(train, config):
    fraction = config.get("late_window_fraction", 0.0)
    weight = config.get("late_validation_weight", 0.0)
    if not 0 <= fraction <= 1 or not 0 <= weight <= 1:
        raise ValueError("late sampling fraction and validation weight must be in [0, 1]")
    early = torch.where(train.start_time_s < 2.0)[0]
    late = torch.where(train.start_time_s >= 2.0)[0]
    late_count = round(config["batch_size"] * fraction)
    if fraction and (not len(late) or (late_count < config["batch_size"] and not len(early))):
        raise ValueError("requested late-window sampling needs the corresponding time pools")
    return early, late, late_count


def validation_score(metrics, config):
    weight = config.get("late_validation_weight", 0.0)
    late = metrics["after_two_seconds"]["normalized_state_mse"]
    if weight and late is None:
        raise ValueError("late-weighted selection requires validation windows after two seconds")
    return (1 - weight) * metrics["normalized_state_mse"] + (weight * late if weight else 0)


def train_one(train, validation, test, config, seed, output):
    torch.manual_seed(seed)
    model = ResidualDynamics(fit_stats(train, config["normalization_floor"]), config["hidden_width"],
                             config.get("horizontal_translation_invariant", False))
    optimizer = torch.optim.Adam(model.parameters(), lr=config["learning_rate"])
    best_loss, best, best_update = float("inf"), None, 0
    history = []
    early, late, late_count = sampling_pools(train, config)
    start = time.perf_counter()
    for update in range(1, config["updates"] + 1):
        if config.get("late_window_fraction", 0):
            parts = []
            if late_count < config["batch_size"]:
                parts.append(early[torch.randint(len(early), (config["batch_size"] - late_count,))])
            if late_count:
                parts.append(late[torch.randint(len(late), (late_count,))])
            indices = torch.cat(parts)
        else:
            indices = torch.randint(len(train.state), (config["batch_size"],))
        prediction = imagine(model, train.state[indices, 0], train.action[indices], train.context[indices])
        loss = ((prediction - train.target[indices]) / model.state_scale).square().mean()
        if not torch.isfinite(loss):
            raise ValueError("nonfinite dynamics loss")
        optimizer.zero_grad()
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        if update % config["evaluate_every"] == 0 or update == config["updates"]:
            validation_metrics = evaluate(model, validation)
            score = validation_score(validation_metrics, config)
            history.append(dict(update=update, train_loss=float(loss.detach()),
                                validation_mse=validation_metrics["normalized_state_mse"],
                                late_validation_mse=validation_metrics["after_two_seconds"]["normalized_state_mse"],
                                selection_score=score))
            if score < best_loss:
                best_loss, best, best_update = score, copy.deepcopy(model.state_dict()), update
            print(json.dumps(dict(seed=seed, update=update,
                                  validation_mse=validation_metrics["normalized_state_mse"],
                                  selection_score=score)), flush=True)
    elapsed = time.perf_counter() - start
    model.load_state_dict(best)
    metrics = {"train": evaluate(model, train), "validation": evaluate(model, validation), "test": evaluate(model, test)}
    probe = gradient_probe(model, validation)
    checkpoint = output / f"dynamics-seed-{seed}.pt"
    checkpoint_format = "moonrobo.residual-dynamics.v2" if model.horizontal_translation_invariant else "moonrobo.residual-dynamics.v1"
    torch.save(dict(format=checkpoint_format, model=best, config=config,
                    layout=train.layout, seed=seed, selected_update=best_update,
                    training_batch_sha256=train.digest, normalization_source="train-windows-only"), checkpoint)
    restored, _ = load_model(checkpoint)
    reloaded = evaluate(restored, test)
    if reloaded != metrics["test"]:
        raise ValueError("checkpoint reload changed evaluation")
    return dict(seed=seed, selected_update=best_update, training_seconds=elapsed, metrics=metrics,
                sampling=dict(early_windows=len(early), late_windows=len(late),
                              late_examples_per_batch=late_count if config.get("late_window_fraction", 0) else None),
                gradient_probe=probe, checkpoint=checkpoint.name, reload_matches=True, history=history)


def run(args):
    config = json.loads(Path(args.config).read_text())
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    train = WindowBatch(args.train, "train")
    validation = WindowBatch(args.validation, "validation")
    test = WindowBatch(args.test, "test")
    train.compatible(validation)
    train.compatible(test)
    root_axes = [dict(name=f"qpos.{i}", unit="m" if i < 3 else "1") for i in range(7)]
    if train.layout["state_axes"][:7] != root_axes or "unitree_g1/scene_mjx.xml" not in train.layout["model_ref"]:
        raise ValueError("this initial quaternion projection requires the declared G1 qpos layout")
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    runs = [train_one(train, validation, test, config, seed, output) for seed in config["seeds"]]
    report = dict(format="moonrobo.dynamics-fit.v1", evidence_class="learned-model-prediction",
                  torch_version=str(torch.__version__), config=config, horizon=train.horizon,
                  normalization_source="train-windows-only", selection_source="validation-only",
                  provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  inputs={b.path.name + ":" + split: b.digest for split, b in [("train", train), ("validation", validation), ("test", test)]},
                  runs=runs, all_passed=all(r["gradient_probe"]["passed"] and r["metrics"]["test"]["beats_persistence"] for r in runs),
                  late_all_passed=all(r["metrics"][s]["after_two_seconds"]["beats_persistence"] is True
                                      for r in runs for s in ["validation", "test"]))
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(report=str(output / "report.json"), all_passed=report["all_passed"])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["train", "validation", "test", "config", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
