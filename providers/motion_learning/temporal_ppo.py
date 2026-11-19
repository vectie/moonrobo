"""On-policy PPO using actual finite-task MuJoCo returns and temporal inputs."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch.distributions import Normal

from cpu_physics import PhysicsRuntime
from policy import qualifies, ranking, step_reward
from temporal_actor import TemporalRunner, load_temporal, save_temporal
from temporal_training import evaluate
from temporal_value import episode_value_points, load_value, value_error


def discounted_visitation(continuation, gamma):
    previous = torch.cat((torch.ones_like(continuation[:1]), continuation[:-1]))
    return previous.cumprod(0) * gamma ** torch.arange(len(continuation))


def policy_loss(new_log_prob, old_log_prob, advantage, weight, clip):
    ratio = (new_log_prob - old_log_prob).exp()
    return -(weight * torch.minimum(ratio * advantage, ratio.clamp(1 - clip, 1 + clip) * advantage)).mean()


def mean_latent(actor, points):
    return actor.latent_mean(points[1][:, -actor.history_length:], points[2][:, 0], points[2][:, 1:1 + actor.future_length])


def collect(runtime, actor, value, collection, config, seed, iteration, noise_generator):
    episodes, inputs, targets, latents, means, visitation, rewards_all, continuations = [], [], [], [], [], [], [], []
    reset_seed = config["collect_seed_base"] + seed * 10000 + iteration
    maximum_latent_error = 0.0
    for case in collection["cases"]:
        if case["split"] != "train":
            raise ValueError("PPO collection must not include held-out families")
        runner = TemporalRunner(runtime, actor, case, reset_seed)
        sampled, behavior_means, captured_inputs = [], [], []
        def predict(obs, goal):
            runner(obs, goal)
            with torch.no_grad():
                h, g, future = runner.last_inputs
                captured_inputs.append((h[0].clone(), g[0].clone(), future[0].clone()))
                mean = actor.latent_mean(h, g, future)
                latent = mean + config["raw_action_std"] * torch.randn(mean.shape, generator=noise_generator)
                sampled.append(latent[0]); behavior_means.append(mean[0])
                return actor.base.action_from_latent(latent, g)[0].numpy()
        episode, _ = runtime.rollout(case, reset_seed, "policy", config["duration_s"],
            config["fall_height_m"], config["fall_upright_z"], policy=predict)
        points, target = episode_value_points(runtime, episode, case, actor, config)
        latent, old_mean = torch.stack(sampled), torch.stack(behavior_means)
        with torch.no_grad():
            offline_inputs = points[1][:, -actor.history_length:], points[2][:, 0], points[2][:, 1:1 + actor.future_length]
            for index, expected in enumerate(offline_inputs):
                actual = torch.stack([p[index] for p in captured_inputs])
                if not torch.equal(actual, expected):
                    raise ValueError(f"PPO causal input {index} differs for {case['id']}: {float((actual - expected).abs().max())}")
            reconstructed = mean_latent(actor, points)
            error = float((reconstructed - old_mean).abs().max())
            maximum_latent_error = max(error, maximum_latent_error)
            # Identical inputs can differ slightly between one-row and batched
            # float32 matrix multiplication; compare each latent at its scale.
            torch.testing.assert_close(reconstructed, old_mean, atol=2e-5, rtol=2e-6)
            next_state = torch.tensor([s["next_state"] for s in episode["steps"]], dtype=torch.float32)
            action = torch.tensor([s["applied_action"] for s in episode["steps"]], dtype=torch.float32)
            reward, continuation = step_reward(next_state, action, points[1][:, -1, -runtime.model.nu:],
                points[2][:, 0], actor.body["q_indices"], config["target_height_m"])
        episodes.append(episode); inputs.append(points); targets.append(target)
        latents.append(latent); means.append(old_mean)
        visitation.append(discounted_visitation(continuation, config["gamma"]))
        rewards_all.append(reward); continuations.append(continuation)
    points = tuple(torch.cat([p[i] for p in inputs]) for i in range(5))
    latent, old_mean, target, weights = map(torch.cat, (latents, means, targets, visitation))
    with torch.no_grad():
        baseline = value(*points)
        old_log_prob = Normal(old_mean, config["raw_action_std"]).log_prob(latent).sum(-1)
    return dict(points=points, latent=latent, old_mean=old_mean, old_log_prob=old_log_prob,
        target=target, advantage=target - baseline, weight=weights, episodes=episodes,
        reset_seed=reset_seed, maximum_alignment_error=0.0, maximum_latent_error=maximum_latent_error,
        objective_rewards=torch.cat(rewards_all), continuation=torch.cat(continuations))


@torch.no_grad()
def exact_kl(actor, batch, std):
    points = batch["points"]
    values = []
    for i in range(0, len(batch["latent"]), 256):
        mean = mean_latent(actor, tuple(p[i:i + 256] for p in points))
        values.append(((mean - batch["old_mean"][i:i + 256]) / std).square().sum(-1) * .5)
    return float(torch.cat(values).mean())


def optimize(actor, value, actor_optimizer, value_optimizer, batch, config, generator):
    points, target = batch["points"], batch["target"]
    # Positive scalar normalization preserves the MC score-function direction.
    advantage = batch["advantage"] / batch["advantage"].std(unbiased=False).clamp_min(1)
    weights = batch["weight"] / batch["weight"].mean().clamp_min(1e-8)
    actor_steps, critic_steps, stopped, maximum_kl = 0, 0, False, 0.0
    before_value = value_error(value, points, target)
    last_policy_loss = 0.0
    for _ in range(config["epochs"]):
        for ids in torch.randperm(len(target), generator=generator).split(config["minibatch_size"]):
            mean = mean_latent(actor, tuple(p[ids] for p in points))
            log_prob = Normal(mean, config["raw_action_std"]).log_prob(batch["latent"][ids]).sum(-1)
            loss = policy_loss(log_prob, batch["old_log_prob"][ids], advantage[ids], weights[ids], config["clip_ratio"])
            if not torch.isfinite(loss):
                raise ValueError("nonfinite temporal PPO actor loss")
            actor_optimizer.zero_grad(); loss.backward()
            torch.nn.utils.clip_grad_norm_(actor.parameters(), 1); actor_optimizer.step()
            actor_steps += 1; last_policy_loss = float(loss.detach())
            kl = exact_kl(actor, batch, config["raw_action_std"])
            maximum_kl = max(kl, maximum_kl)
            if kl > config["target_kl"]:
                stopped = True
                break
        if stopped:
            break
    for _ in range(config["epochs"]):
        for ids in torch.randperm(len(target), generator=generator).split(config["minibatch_size"]):
            prediction = value(*(p[ids] for p in points))
            loss = ((prediction - target[ids]) / 100).square().mean()
            if not torch.isfinite(loss):
                raise ValueError("nonfinite temporal PPO critic loss")
            value_optimizer.zero_grad(); loss.backward()
            torch.nn.utils.clip_grad_norm_(value.parameters(), 1); value_optimizer.step()
            critic_steps += 1
    return dict(actor_steps=actor_steps, critic_steps=critic_steps, actor_early_stopped=stopped,
        maximum_full_batch_kl=maximum_kl, final_policy_loss=last_policy_loss,
        value_before=before_value, value_after=value_error(value, points, target))


def run(args):
    config = json.loads(Path(args.config).read_bytes())
    collection, experiment = [json.loads(Path(p).read_bytes()) for p in [args.collection, args.experiment]]
    torch.set_num_threads(config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, collection["control_dt_s"])
    output = Path(args.output); (output / "policy").mkdir(parents=True, exist_ok=True)
    (output / "collection").mkdir(exist_ok=True)
    runs = []
    for seed in config["seeds"]:
        actor_path = Path(args.policies) / f"actor-seed-{seed}.pt"
        value_path = Path(args.values) / f"actor-seed-{seed}.pt"
        actor, actor_meta = load_temporal(actor_path)
        value = load_value(value_path)
        value_meta = torch.load(value_path, weights_only=True)
        actor_sha = hashlib.sha256(actor_path.read_bytes()).hexdigest()
        if value_meta["initialization"]["sha256"] != actor_sha or value_meta["initialization"]["critic_actor_update"] != 0:
            raise ValueError("PPO requires the incoming actor's initial calibrated value")
        initial_buffers = {k: v.clone() for k, v in actor.named_buffers()}
        initial_value_buffers = {k: v.clone() for k, v in value.named_buffers()}
        actor_optimizer = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
        value_optimizer = torch.optim.Adam(value.parameters(), lr=config["critic_learning_rate"])
        noise_generator = torch.Generator().manual_seed(config["noise_seed"] + seed)
        optimizer_generator = torch.Generator().manual_seed(config["optimizer_seed"] + seed)
        best, _ = evaluate(runtime, experiment, config["validation_seeds"], actor, "validation")
        best_actor, best_value, selected = copy.deepcopy(actor.state_dict()), copy.deepcopy(value.state_dict()), 0
        history = [dict(iteration=0, transitions=0, actor_steps=0, critic_steps=0, validation=best["summary"])]
        transitions, episodes, falls, actor_steps, critic_steps = 0, 0, 0, 0, 0
        log_path = output / "policy" / f"ppo-physics-seed-{seed}.jsonl.gz"
        start = time.perf_counter()
        with gzip.open(log_path, "wt", encoding="utf-8", compresslevel=6) as stream:
            for iteration in range(config["iterations"]):
                batch = collect(runtime, actor, value, collection, config, seed, iteration, noise_generator)
                dataset = runtime.dataset(batch["episodes"], collection["source_revision"])
                if seed == 0 and iteration == 0:
                    with gzip.open(output / "collection/dataset.json.gz", "wt", compresslevel=6) as sample:
                        json.dump(dataset, sample, allow_nan=False)
                count = len(batch["target"])
                transitions += count; episodes += len(batch["episodes"])
                collected_falls = sum(e["steps"][-1]["terminated"] for e in batch["episodes"]); falls += collected_falls
                stream.write(json.dumps(dict(iteration=iteration + 1, reset_seed=batch["reset_seed"], dataset=dataset,
                    latent_samples=batch["latent"].tolist(), behavior_latent_means=batch["old_mean"].tolist(),
                    objective_rewards=batch["objective_rewards"].tolist(), soft_continuation=batch["continuation"].tolist(),
                    finite_return_targets=batch["target"].tolist(), discounted_visitation=batch["weight"].tolist()), allow_nan=False) + "\n")
                losses = optimize(actor, value, actor_optimizer, value_optimizer, batch, config, optimizer_generator)
                actor_steps += losses["actor_steps"]; critic_steps += losses["critic_steps"]
                current, _ = evaluate(runtime, experiment, config["validation_seeds"], actor, "validation")
                row = dict(iteration=iteration + 1, transitions=transitions, episodes=episodes, falls=falls,
                    collection_transitions=count, collection_falls=collected_falls,
                    maximum_input_alignment_error=batch["maximum_alignment_error"],
                    maximum_latent_reconstruction_error=batch["maximum_latent_error"], validation=current["summary"], **losses)
                # Cumulative counts have distinct names from this iteration's optimizer counts.
                row["total_actor_steps"], row["total_critic_steps"] = actor_steps, critic_steps
                history.append(row)
                if ranking(current) > ranking(best):
                    best, selected = current, iteration + 1
                    best_actor, best_value = copy.deepcopy(actor.state_dict()), copy.deepcopy(value.state_dict())
                print(json.dumps(dict(seed=seed, **row)), flush=True)
        seconds = time.perf_counter() - start
        base_meta = dict(config=actor_meta["base_config"], model_ref=actor_meta["model_ref"])
        evidence = dict(algorithm="temporal-ppo-physics", actor_sha256=actor_sha,
            value_checkpoint_sha256=hashlib.sha256(value_path.read_bytes()).hexdigest(),
            inherited_initial_value_actor_update=0, optimizer_state_restored=False, learned_transition_model_used=False)
        latest_name, name = f"latest-actor-seed-{seed}.pt", f"actor-seed-{seed}.pt"
        save_temporal(actor, base_meta, config, output / "policy" / latest_name, config["iterations"], evidence, critic=value)
        actor.load_state_dict(best_actor); value.load_state_dict(best_value)
        save_temporal(actor, base_meta, config, output / "policy" / name, selected, evidence, critic=value)
        restored, _ = load_temporal(output / "policy" / name); restored_value = load_value(output / "policy" / name)
        p = tuple(v[:8] for v in batch["points"])
        actor_inputs = p[1][:, -actor.history_length:], p[2][:, 0], p[2][:, 1:1 + actor.future_length]
        if not torch.equal(actor(*actor_inputs), restored(*actor_inputs)) or not torch.equal(value(*p), restored_value(*p)):
            raise ValueError("temporal PPO paired checkpoint reload differs")
        if any(not torch.equal(v, dict(actor.named_buffers())[k]) for k, v in initial_buffers.items()) or any(not torch.equal(v, dict(value.named_buffers())[k]) for k, v in initial_value_buffers.items()):
            raise ValueError("PPO changed incoming normalization")
        candidate, _ = evaluate(runtime, experiment, config["test_seeds"], restored)
        incoming, _ = load_temporal(actor_path)
        baseline, _ = evaluate(runtime, experiment, config["test_seeds"], incoming)
        if selected == 0:
            for a, b in zip(baseline["trials"], candidate["trials"]):
                for key in ["case_id", "seed", "steps", "failed", "joint_rmse_rad", "replay"]:
                    if a[key] != b[key]:
                        raise ValueError("PPO update-zero actor changed physical trace")
        (output / "policy" / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline, candidate=candidate), indent=2, allow_nan=False))
        runs.append(dict(seed=seed, selected_update=selected, checkpoint=name, latest_checkpoint=latest_name,
            baseline=baseline["summary"], candidate=candidate["summary"], qualifies=qualifies(candidate, config), history=history,
            training_seconds=seconds, training_transitions=transitions, training_episodes=episodes, training_falls=falls,
            actor_optimizer_steps=actor_steps, critic_optimizer_steps=critic_steps, normalization_unchanged=True,
            reload_matches=True, initialization=evidence, physics_log=dict(file=log_path.name, sha256=hashlib.sha256(log_path.read_bytes()).hexdigest())))
    report = dict(format="moonrobo.g1-temporal-ppo-fit.v1", algorithm="temporal-ppo-physics", config=config, experiment=experiment,
        collection_experiment=collection, runs=runs, checkpoint_selection="validation-physics-only", evidence_class="physics-simulation",
        baseline_role="incoming supervised temporal actor", learned_transition_model_used=False,
        registered_collection_role="first seed first training batch; complete actual training is in per-seed physics logs",
        inherited_pretraining="Same supervised actor and initial physical finite-value calibration as the model-based temporal studies; inherited normalization/teacher/data/model costs are not re-counted as new PPO samples.",
        provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), any_qualified=any(r["qualifies"] for r in runs), physical_execution_allowed=False)
    (output / "policy/report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "collection", "experiment", "policies", "values", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
