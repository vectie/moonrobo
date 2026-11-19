"""CPU PPO baseline in actual MuJoCo with the shared actor and reward.

The on-policy optimizer uses sampled latent Gaussian actions. The fixed tanh
and actuator clipping are applied by the shared Actor; likelihood ratios are
computed on the stored latent samples, never on post-clipping setpoints.
No learned transition model is used for rewards, advantages or gradients.
"""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch import nn
from torch.distributions import Normal

from cpu_physics import PhysicsRuntime
from dynamics import WindowBatch, fit_stats
from policy import Actor, Critic, evaluate_physics, load_actor, ranking, step_reward, qualifies


def physical_gae(rewards, values, next_values, terminated, truncated, gamma, lam):
    """Bootstrap a time limit, but never carry GAE across an episode reset."""
    advantage = torch.zeros((), dtype=rewards.dtype)
    result = torch.empty_like(rewards)
    for i in reversed(range(len(rewards))):
        delta = rewards[i] + gamma * (1 - terminated[i]) * next_values[i] - values[i]
        advantage = delta + gamma * lam * (1 - terminated[i]) * (1 - truncated[i]) * advantage
        result[i] = advantage
    return result, result + values


def collect(runtime, cases, actor, critic, config, update):
    trajectories, latents = [], []
    scale = config["raw_action_std"]
    def sample(obs, goal):
        with torch.no_grad():
            obs = torch.tensor(obs, dtype=torch.float32)[None]
            goal = torch.tensor(goal, dtype=torch.float32)[None]
            latent = Normal(actor.latent_mean(obs, goal), scale).sample()
            latents.append(latent[0])
            return actor.action_from_latent(latent, goal)[0].numpy()
    for i in range(config["episodes_per_update"]):
        episode, _ = runtime.rollout(cases[(update + i) % len(cases)],
                                     update * config["episodes_per_update"] + i,
                                     "policy", config["duration_s"], config["fall_height_m"],
                                     config["fall_upright_z"], policy=sample)
        trajectories.append(episode)
    steps = [step for episode in trajectories for step in episode["steps"]]
    tensor = lambda name: torch.tensor([step[name] for step in steps], dtype=torch.float32)
    state, next_state, obs, goal = tensor("state"), tensor("next_state"), tensor("observation"), tensor("goal")
    contexts = torch.tensor([episode["context"] for episode in trajectories for _ in episode["steps"]], dtype=torch.float32)
    latent = torch.stack(latents)
    with torch.no_grad():
        reward, _ = step_reward(next_state, tensor("applied_action"), obs[:, -runtime.model.nu:],
                                goal, actor.body["q_indices"], config["target_height_m"])
        values = critic(state, goal, contexts)
        next_values = critic(next_state, goal, contexts)
        advantage, target = physical_gae(reward, values, next_values, tensor("terminated"), tensor("truncated"),
                                          config["gamma"], config["gae_lambda"])
        log_prob = Normal(actor.latent_mean(obs, goal), scale).log_prob(latent).sum(-1)
    return dict(obs=obs, goal=goal, state=state, context=contexts, latent=latent,
                old_log_prob=log_prob, advantage=advantage, target=target,
                mean_reward=float(reward.mean()), episodes=len(trajectories),
                falls=sum(e["steps"][-1]["terminated"] for e in trajectories),
                goal_min=goal.amin(0), goal_max=goal.amax(0))


def optimize(actor, critic, actor_opt, critic_opt, batch, config):
    advantage = batch["advantage"]
    advantage = (advantage - advantage.mean()) / advantage.std(unbiased=False).clamp_min(1e-8)
    maximum_kl, stopped = 0.0, False
    for _ in range(config["epochs"]):
        for mini in torch.randperm(len(advantage)).split(config["minibatch_size"]):
            log_prob = Normal(actor.latent_mean(batch["obs"][mini], batch["goal"][mini]),
                              config["raw_action_std"]).log_prob(batch["latent"][mini]).sum(-1)
            difference = log_prob - batch["old_log_prob"][mini]
            ratio = difference.exp()
            approximate_kl = float(((ratio - 1) - difference).mean().detach())
            maximum_kl = max(maximum_kl, approximate_kl)
            if approximate_kl > config["target_kl"]:
                stopped = True
                break
            loss = -torch.minimum(ratio * advantage[mini], ratio.clamp(1 - config["clip_ratio"], 1 + config["clip_ratio"]) * advantage[mini]).mean()
            if not torch.isfinite(loss):
                raise ValueError("nonfinite PPO policy loss")
            actor_opt.zero_grad(); loss.backward()
            nn.utils.clip_grad_norm_(actor.parameters(), 1.0)
            actor_opt.step()
        if stopped:
            break
    for _ in range(config["epochs"]):
        for mini in torch.randperm(len(advantage)).split(config["minibatch_size"]):
            value = critic(batch["state"][mini], batch["goal"][mini], batch["context"][mini])
            value_loss = (value - batch["target"][mini]).square().mean()
            if not torch.isfinite(value_loss):
                raise ValueError("nonfinite PPO value loss")
            critic_opt.zero_grad(); value_loss.backward()
            nn.utils.clip_grad_norm_(critic.parameters(), 1.0)
            critic_opt.step()
    return dict(policy_loss=float(loss.detach()), value_loss=float(value_loss.detach()),
                maximum_minibatch_kl=maximum_kl, policy_early_stopped=stopped)


def baseline_diagnostic(runtime, experiment, config):
    case = next(case for case in experiment["cases"] if case["split"] == "train")
    episode, trial = runtime.rollout(case, 0, "position", experiment["duration_s"],
                                     experiment["fall_height_m"], experiment["fall_upright_z"])
    errors = np.array([np.array(step["next_state"])[runtime.q_indices] - step["goal"] for step in episode["steps"]])
    joints = [dict(name=name, mean_error_rad=float(errors[:, i].mean()),
                   rms_error_rad=float(np.sqrt(np.square(errors[:, i]).mean())),
                   servo_gain=float(runtime.model.actuator_gainprm[i, 0]),
                   max_residual_servo_force=float(runtime.model.actuator_gainprm[i, 0] * config["action_delta_rad"]))
              for i, name in enumerate(runtime.names)]
    return dict(case_id=case["id"], fall_time_s=trial["simulated_seconds"],
                final_root_height_m=trial["replay"][-1]["root_height_m"],
                final_upright_z=trial["replay"][-1]["upright_z"],
                joints=sorted(joints, key=lambda joint: -joint["rms_error_rad"]),
                note="Servo gain times residual range is a setpoint-force increment before saturation/damping, not measured support torque or a proof of the fall cause.")


def train_seed(args, train, config, experiment, evaluation_experiment, seed, output):
    torch.manual_seed(seed)
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    body = dict(q_indices=runtime.q_indices.tolist(), v_state_indices=(runtime.v_indices + runtime.model.nq).tolist(), nq=runtime.model.nq)
    obs, goal = train.observation.flatten(0, 1), train.goal.flatten(0, 1)
    stats = dict(obs_mean=obs.mean(0), obs_scale=obs.std(0, unbiased=False).clamp_min(.1),
                 goal_mean=goal.mean(0), goal_scale=goal.std(0, unbiased=False).clamp_min(.1),
                 lower=torch.tensor(np.where(runtime.model.actuator_ctrllimited, runtime.model.actuator_ctrlrange[:, 0], -np.inf), dtype=torch.float32),
                 upper=torch.tensor(np.where(runtime.model.actuator_ctrllimited, runtime.model.actuator_ctrlrange[:, 1], np.inf), dtype=torch.float32))
    state_stats = fit_stats(train, .1)
    actor = Actor(stats, config, body)
    critic = Critic(state_stats["state_mean"], state_stats["state_scale"], train.context.shape[-1], config, len(stats["goal_mean"]))
    initialization = dict(mode="zero-residual")
    if args.warm_start_policy:
        prior_path = Path(args.warm_start_policy) / f"actor-seed-{seed}.pt"
        prior = torch.load(prior_path, weights_only=True)
        if prior["body"] != body or prior["model_ref"] != train.layout["model_ref"]:
            raise ValueError("PPO warm-start body differs from current simulator")
        for key in ["action_delta_rad", "hidden_width", "gamma"]:
            if prior["config"][key] != config[key]:
                raise ValueError("PPO warm-start changes policy semantics: " + key)
        actor.load_state_dict(prior["actor"])
        critic.load_state_dict(prior["critic"])
        critic.enforce_input_encoding()
        initialization = dict(mode="weights-only-warm-start", checkpoint=str(prior_path),
                              sha256=hashlib.sha256(prior_path.read_bytes()).hexdigest(),
                              prior_selected_update=prior["selected_update"], optimizer_state_restored=False,
                              critic_encoding_changed=config.get("critic_horizontal_translation_invariant", False) !=
                                  prior["config"].get("critic_horizontal_translation_invariant", False))
    initial_actor = copy.deepcopy(actor.state_dict())
    actor_opt = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
    critic_opt = torch.optim.Adam(critic.parameters(), lr=config["critic_learning_rate"])
    validation, _ = evaluate_physics(runtime, evaluation_experiment, config["validation_seeds"], actor, "validation")
    best_actor, best_critic, best_validation, selected = copy.deepcopy(actor.state_dict()), copy.deepcopy(critic.state_dict()), validation, 0
    history = [dict(update=0, training_steps=0, validation=validation["summary"])]
    cases = [case for case in experiment["cases"] if case["split"] == "train"]
    collection_config = {**config, **{key: experiment[key] for key in ["duration_s", "fall_height_m", "fall_upright_z"]}}
    start = time.perf_counter()
    steps, episodes, falls, last_update, stop_reason = 0, 0, 0, 0, "updates"
    goal_min, goal_max = torch.full_like(stats["goal_mean"], float("inf")), torch.full_like(stats["goal_mean"], -float("inf"))
    # Reserve enough steps for a full collection update; never silently overrun.
    ceiling = config["episodes_per_update"] * round(experiment["duration_s"] / runtime.dt)
    for update in range(1, config["updates"] + 1):
        if steps + ceiling > config["max_training_steps"]:
            stop_reason = "training-step-budget"; break
        if time.perf_counter() - start >= config["max_training_seconds"]:
            stop_reason = "training-time-budget"; break
        batch = collect(runtime, cases, actor, critic, collection_config, update)
        steps += len(batch["obs"]); episodes += batch["episodes"]; falls += batch["falls"]
        goal_min = torch.minimum(goal_min, batch["goal_min"])
        goal_max = torch.maximum(goal_max, batch["goal_max"])
        losses = optimize(actor, critic, actor_opt, critic_opt, batch, config)
        last_update = update
        if update % config["evaluate_every"] == 0 or update == config["updates"]:
            validation, _ = evaluate_physics(runtime, evaluation_experiment, config["validation_seeds"], actor, "validation")
            record = dict(update=update, training_steps=steps, elapsed_seconds=time.perf_counter() - start,
                          mean_reward=batch["mean_reward"], collection_falls=batch["falls"],
                          validation=validation["summary"], **losses)
            history.append(record); print(json.dumps(dict(seed=seed, **record)), flush=True)
            if ranking(validation) > ranking(best_validation):
                best_actor, best_critic, best_validation, selected = copy.deepcopy(actor.state_dict()), copy.deepcopy(critic.state_dict()), validation, update
    elapsed = time.perf_counter() - start
    metadata = dict(format="moonrobo.g1-actor.v1", config=config, body=body, model_ref=train.layout["model_ref"],
                    seed=seed, training_batch_sha256=train.digest, algorithm="ppo-physics",
                    normalization_source="checkpoint-buffers" if args.warm_start_policy else "initial-train-windows-only",
                    initialization=initialization)
    latest = output / f"latest-actor-seed-{seed}.pt"
    torch.save(dict(**metadata, actor=actor.state_dict(), critic=critic.state_dict(), selected_update=last_update), latest)
    changed = any(not torch.equal(value, actor.state_dict()[key]) for key, value in initial_actor.items())
    actor.load_state_dict(best_actor)
    goal_update_norm = (best_actor["net.0.weight"][:, obs.shape[-1]:] - initial_actor["net.0.weight"][:, obs.shape[-1]:]).norm(dim=0)
    goal_coverage = dict(varying_channels=int(((goal_max - goal_min) > 1e-6).sum()),
                         selected_actor_goal_column_update_l2=goal_update_norm.tolist(),
                         minimum_rad=goal_min.tolist(), maximum_rad=goal_max.tolist(), channel_names=runtime.names)
    checkpoint = output / f"actor-seed-{seed}.pt"
    torch.save(dict(**metadata, actor=best_actor, critic=best_critic, selected_update=selected), checkpoint)
    restored, _ = load_actor(checkpoint)
    if not torch.equal(actor(obs[:8], goal[:8]), restored(obs[:8], goal[:8])):
        raise ValueError("PPO checkpoint reload differs")
    baseline, _ = evaluate_physics(runtime, evaluation_experiment, config["test_seeds"])
    candidate, trial_episodes = evaluate_physics(runtime, evaluation_experiment, config["test_seeds"], restored)
    (output / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline, candidate=candidate), indent=2, allow_nan=False))
    (output / f"candidate-data-seed-{seed}.json").write_text(json.dumps(runtime.dataset(trial_episodes, experiment["source_revision"]), allow_nan=False))
    return dict(seed=seed, selected_update=selected, completed_update=last_update, training_seconds=elapsed,
                training_steps=steps, training_episodes=episodes, training_falls=falls, stop_reason=stop_reason,
                baseline=baseline["summary"], candidate=candidate["summary"], qualifies=qualifies(candidate, config), initialization=initialization,
                checkpoint=checkpoint.name, latest_checkpoint=latest.name, history=history,
                actor_changed=changed, reload_matches=True, goal_coverage=goal_coverage)


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    evaluation_experiment = json.loads(Path(args.evaluation_experiment).read_text())
    for field in ["source_revision", "control_dt_s", "duration_s", "fall_height_m", "fall_upright_z"]:
        if experiment[field] != evaluation_experiment[field]:
            raise ValueError("training/evaluation runtime differs: " + field)
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    train = WindowBatch(args.train, "train")
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    diagnostic = baseline_diagnostic(PhysicsRuntime(args.scene, experiment["control_dt_s"]), experiment, config)
    (output / "baseline-diagnostic.json").write_text(json.dumps(diagnostic, indent=2, allow_nan=False))
    runs = [train_seed(args, train, config, experiment, evaluation_experiment, seed, output) for seed in config["seeds"]]
    report = dict(format="moonrobo.g1-ppo-fit.v1", algorithm="ppo-physics", config=config, experiment=evaluation_experiment,
                  collection_experiment=experiment, evaluation_action_noise_std_rad=0.0,
                  evidence_class="physics-simulation", checkpoint_selection="validation-physics-only", runs=runs,
                  normalization_batch_sha256=None if args.warm_start_policy else train.digest,
                  input_batch_sha256=train.digest, provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  normalization_goal_varying_channels=int(((train.goal.amax((0, 1)) - train.goal.amin((0, 1))) > 1e-6).sum()),
                  any_qualified=any(run["qualifies"] for run in runs),
                  comparison_limit="Shared actor/critic architecture and step reward; no matched total-budget, initialization-data-cost or learning-speed claim.")
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(report=str(output / "report.json"), any_qualified=report["any_qualified"])), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["train", "scene", "config", "experiment", "evaluation-experiment", "output"]:
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--warm-start-policy")
    run(parser.parse_args())
