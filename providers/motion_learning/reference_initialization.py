"""Supervised full-reference initialization and actual physical coverage checks."""
import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch

from balance_features import BalanceKinematics
from cpu_physics import PhysicsRuntime
from full_body_reference import assess_tracking_quality, replay_reference
from reference_actor import ReferenceActor, ReferenceRunner, load_reference_actor, load_references, reference_observation, save_reference_actor


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def training_points(references, history_length, future_length):
    points = {key: [] for key in ["history", "current", "future", "valid", "target"]}
    for _, reference in references:
        count = reference.steps
        obs = torch.as_tensor(reference.arrays["observation"], dtype=torch.float32)
        goal = torch.as_tensor(reference.goals, dtype=torch.float32)
        # In this supervised corpus, actual and current-reference observations
        # agree on every channel used by relative feedback. Both causal filters
        # therefore agree; their common value cancels, so zero differences are exact.
        if not torch.equal(obs[:, :64], reference_observation(goal[:-1])[:, :64]):
            raise ValueError("source physical observations do not match current reference")
        history = (torch.arange(count)[:, None]-torch.arange(history_length-1, -1, -1)[None]).clamp_min(0)
        future = torch.arange(count)[:, None]+torch.arange(1, future_length+1)[None]
        points["history"].append(obs[history]); points["current"].append(goal[:-1])
        points["future"].append(goal[future.clamp_max(count)]); points["valid"].append(future<=count)
        points["target"].append(torch.as_tensor(reference.arrays["source_setpoint"], dtype=torch.float32))
    return {key: torch.cat(values) for key, values in points.items()}


def prediction(actor, points, indices):
    n = len(indices)
    return actor(points["history"][indices], points["current"][indices], points["future"][indices],
        points["valid"][indices], torch.zeros(n, 6), torch.zeros(n, 6))


@torch.no_grad()
def fit_error(actor, points):
    total, maximum, n = 0., 0., 0
    for start in range(0, len(points["target"]), 512):
        indices = torch.arange(start, min(start+512, len(points["target"])))
        error = prediction(actor, points, indices)-points["target"][indices]
        total += float(error.square().sum()); maximum = max(maximum, float(error.abs().max())); n += error.numel()
    return dict(action_rmse_rad=(total/n)**.5, max_action_error_rad=maximum)


def evaluate(runtime, references, actor, geometry, quality, output, label):
    folder = output / "physics" / label
    folder.mkdir(parents=True, exist_ok=True)
    trials, records = [], []
    for clip, reference in references:
        for origin_s in quality["origins_s"]:
            origin = round(origin_s/runtime.dt)
            runner = ReferenceRunner(actor, geometry, runtime.dt)
            episode, trial = replay_reference(runtime, reference, clip["case"], origin, "policy", policy=runner)
            episode["id"] += "-"+label; trial["episode_id"] = episode["id"]
            path = folder / (episode["id"]+".npz")
            steps = episode["steps"]
            np.savez_compressed(path, state=np.asarray([s["state"] for s in steps]),
                observation=np.asarray([s["observation"] for s in steps]),
                applied_action=np.asarray([s["applied_action"] for s in steps]),
                next_state=np.asarray([s["next_state"] for s in steps]),
                reward=np.asarray([s["reward"] for s in steps]),
                terminated=np.asarray([s["terminated"] for s in steps]),
                truncated=np.asarray([s["truncated"] for s in steps]))
            records.append(dict(file=str(path.relative_to(output)), sha256=digest(path),
                reference_id=clip["id"], reference_sha256=clip["sha256"], origin_step=origin,
                episode_id=episode["id"], source_family=episode["source_family"], split=episode["split"],
                context=episode["context"], steps=len(steps)))
            trials.append(trial)
            print(json.dumps(dict(label=label, **trial)), flush=True)
    count = sum(t["steps"] for t in trials)
    metrics = ["joint_rmse_rad", "body_position_rmse_m", "root_position_rmse_m", "root_orientation_rmse_rad"]
    return dict(label=label, trials=trials, records=records, quality=assess_tracking_quality(trials, quality),
        summary=dict(trials=len(trials), falls=sum(t["failed"] for t in trials), steps=count,
            mean_survival_s=sum(t["simulated_seconds"] for t in trials)/len(trials),
            **{key: float(np.sqrt(sum(t[key]**2*t["steps"] for t in trials)/count)) for key in metrics}))


def run(args):
    config = json.loads(Path(args.config).read_bytes())
    quality = json.loads(Path(args.quality).read_bytes())
    if digest(Path(args.references)/"manifest.json") != quality["reference_manifest_sha256"]:
        raise ValueError("reference quality target belongs to another manifest")
    manifest, references = load_references(args.references)
    inherited = torch.load(args.feedback, weights_only=True)
    if inherited["format"] != "moonrobo.g1-learned-balance-actor.v2" or not inherited["head_spec"]["pose_rate"]:
        raise ValueError("relative feedback requires the fitted five-input pose/rate law")
    coefficient = inherited["head"]["ankle.weight"][:, :-1] / inherited["head"]["ankle.scale"]
    names = manifest["layout"]["joint_names"]
    indices = [names.index(side+"_ankle_"+axis+"_joint") for side in ["left", "right"] for axis in ["pitch", "roll"]]
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    output = Path(args.output); (output/"policy").mkdir(parents=True, exist_ok=True)
    runtime = PhysicsRuntime(args.scene, manifest["layout"]["dt_s"])
    geometry = BalanceKinematics(inherited["kinematics"])
    started = time.perf_counter()
    points = training_points(references, config["history_length"], config["future_length"])
    maximum_target_residual = float((points["target"]-points["current"][:, :29]).abs().max())
    if maximum_target_residual >= config["output_bound_rad"]:
        raise ValueError("declared action residual cannot represent source labels")
    provenance = dict(reference_manifest_sha256=digest(Path(args.references)/"manifest.json"),
        feedback_checkpoint_sha256=digest(args.feedback), quality_sha256=digest(args.quality),
        training_points=len(points["target"]), fit="supervised source-control labels; fixed final update; all references are train families")
    evaluations, fits = [], []
    for seed in config["seeds"]:
        torch.manual_seed(seed)
        actor = ReferenceActor(len(manifest["layout"]["goal_axes"]), runtime.model.nu,
            *runtime.model.actuator_ctrlrange.T, coefficient, indices,
            history_length=config["history_length"], future_length=config["future_length"],
            width=config["width"], latent_dim=config["latent_dim"], output_bound=config["output_bound_rad"])
        actor.obs_mean.copy_(points["history"][:, -1].mean(0))
        actor.obs_scale.copy_(points["history"][:, -1].std(0, unbiased=False).clamp_min(config["normalization_floor"]))
        actor.goal_mean.copy_(points["current"].mean(0))
        actor.goal_scale.copy_(points["current"].std(0, unbiased=False).clamp_min(config["normalization_floor"]))
        mask_handle = None
        if config.get("reference_only_initialization", False):
            # Initialize the planned control mapping without an unconstrained
            # behavior-cloning shortcut through on-reference proprioception.
            # The frozen relative feedback still observes the actual robot.
            # Saved weights have no hook: later shared RL can train this path
            # from exactly the same initial outputs.
            with torch.no_grad():
                actor.decoder[0].weight[:, actor.latent_dim:].zero_()
            mask_handle = actor.decoder[0].weight.register_hook(lambda gradient:
                torch.cat((gradient[:, :actor.latent_dim], torch.zeros_like(gradient[:, actor.latent_dim:])), -1))
        if seed == config["seeds"][0]:
            path = output/"policy"/"actor-zero-output.pt"
            save_reference_actor(path, actor, inherited["kinematics"], runtime.dt, provenance)
        optimizer = torch.optim.Adam(actor.parameters(), lr=config["learning_rate"])
        generator = torch.Generator().manual_seed(seed+987)
        before = fit_error(actor, points); history = []
        fit_start = time.perf_counter()
        for update in range(1, config["updates"]+1):
            rows = torch.randint(len(points["target"]), (config["batch_size"],), generator=generator)
            error = prediction(actor, points, rows)-points["target"][rows]
            loss = error.square().mean()
            optimizer.zero_grad(); loss.backward(); torch.nn.utils.clip_grad_norm_(actor.parameters(), 1.)
            optimizer.step()
            if update % 100 == 0:
                row = dict(seed=seed, update=update, batch_action_mse_rad2=float(loss.detach()))
                history.append(row); print(json.dumps(row), flush=True)
        fit_seconds = time.perf_counter()-fit_start
        if mask_handle is not None:
            mask_handle.remove()
        path = output/"policy"/f"actor-seed-{seed}.pt"
        save_reference_actor(path, actor, inherited["kinematics"], runtime.dt, {**provenance, "seed": seed, "updates": config["updates"]})
        restored, restored_geometry, _ = load_reference_actor(path)
        if any(not torch.equal(v, restored.state_dict()[key]) for key, v in actor.state_dict().items()):
            raise ValueError("reference actor checkpoint changed on reload")
        fit = dict(seed=seed, updates=config["updates"], before=before, after=fit_error(restored, points),
            fit_seconds=fit_seconds, history=history, checkpoint=str(path.relative_to(output)), checkpoint_sha256=digest(path))
        fits.append(fit); print(json.dumps(fit), flush=True)
        eval_start = time.perf_counter()
        evaluated = evaluate(runtime, references, restored, restored_geometry, quality, output, f"seed-{seed}")
        evaluated["evaluation_seconds"] = time.perf_counter()-eval_start
        evaluations.append(evaluated)
    zero, zero_geometry, _ = load_reference_actor(output/"policy"/"actor-zero-output.pt")
    eval_start = time.perf_counter()
    baseline = evaluate(runtime, references, zero, zero_geometry, quality, output, "zero-output")
    baseline["evaluation_seconds"] = time.perf_counter()-eval_start
    report = dict(format="moonrobo.g1-reference-initialization.v1", config=config, quality_target=quality,
        **provenance, maximum_target_residual_rad=maximum_target_residual,
        provider_sha256=digest(__file__), actor_provider_sha256=digest(Path(__file__).with_name("reference_actor.py")),
        harness_sha256=digest(Path(__file__).with_name("full_body_reference.py")),
        fits=fits, evaluations=evaluations, baseline=baseline,
        provider_seconds=time.perf_counter()-started, release_qualified=False, physical_execution_allowed=False)
    (output/"report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(fits=[{k: v for k, v in f.items() if k != "history"} for f in fits],
        baseline=baseline["summary"], evaluations=[dict(label=e["label"], summary=e["summary"], quality_passed=e["quality"]["quality_passed"])
            for e in evaluations], provider_seconds=report["provider_seconds"])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["config", "quality", "references", "feedback", "scene", "output"]:
        parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
