"""Short-horizon actor/critic updates through a frozen learned G1 model."""

import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch
from torch import nn

from cpu_physics import PhysicsRuntime
from dynamics import WindowBatch, load_model


def gravity(state):
    w, x, y, z = state[..., 3:7].unbind(-1)
    return torch.stack((-2 * (x * z - w * y), -2 * (y * z + w * x),
                        -(1 - 2 * (x.square() + y.square()))), dim=-1)


def observation(state, previous, body):
    return torch.cat((state[..., body["q_indices"]],
                      state[..., body["v_state_indices"]], gravity(state),
                      state[..., body["nq"] + 3:body["nq"] + 6], previous), dim=-1)


class Actor(nn.Module):
    def __init__(self, stats, config, body):
        super().__init__()
        self.config, self.body = config, body
        for name, value in stats.items():
            self.register_buffer(name, value.clone())
        width = config["hidden_width"]
        self.net = nn.Sequential(nn.Linear(len(self.obs_mean) + len(self.goal_mean), width),
                                 nn.SiLU(), nn.Linear(width, width), nn.SiLU(),
                                 nn.Linear(width, len(self.goal_mean)))
        nn.init.zeros_(self.net[-1].weight)
        nn.init.zeros_(self.net[-1].bias)

    def latent_mean(self, obs, goal):
        inputs = torch.cat(((obs - self.obs_mean) / self.obs_scale,
                            (goal - self.goal_mean) / self.goal_scale), dim=-1)
        return self.net(inputs)

    def action_from_latent(self, latent, goal):
        request = goal + self.config["action_delta_rad"] * latent.tanh()
        return torch.maximum(torch.minimum(request, self.upper), self.lower)

    def forward(self, obs, goal):
        return self.action_from_latent(self.latent_mean(obs, goal), goal)


class Critic(nn.Module):
    def __init__(self, state_mean, state_scale, n_context, config, n_goal):
        super().__init__()
        self.register_buffer("mean", state_mean.clone())
        self.register_buffer("scale", state_scale.clone())
        self.horizontal_translation_invariant = config.get("critic_horizontal_translation_invariant", False)
        # Each step's positive reward is at most three. An unconstrained
        # bootstrap value can otherwise inflate returns in model-extrapolated
        # states, despite no improvement in the physical simulator.
        self.value_bound = 3.0 / (1.0 - config["gamma"])
        self.net = nn.Sequential(nn.Linear(len(self.mean) + n_goal + n_context, 128),
                                 nn.SiLU(), nn.Linear(128, 64), nn.SiLU(), nn.Linear(64, 1))
        self.enforce_input_encoding()

    def enforce_input_encoding(self):
        if self.horizontal_translation_invariant:
            # Also store zero coefficients, so the saved network represents
            # the same value function for readers using the original inputs.
            with torch.no_grad():
                self.net[0].weight[:, :2].zero_()

    def forward(self, state, goal, context):
        normalized = (state - self.mean) / self.scale
        if self.horizontal_translation_invariant:
            normalized = torch.cat((torch.zeros_like(normalized[..., :2]), normalized[..., 2:]), -1)
        raw = self.net(torch.cat((normalized, goal, context), -1)).squeeze(-1)
        return self.value_bound * torch.tanh(raw / self.value_bound)


def step_reward(state, action, previous, goal, q_indices, target_height):
    upright = -gravity(state)[..., 2]
    tracking = torch.exp(-(state[..., q_indices] - goal).square().mean(-1) / 0.09)
    balance = torch.exp(-((1 - upright) / 0.2).square())
    height = torch.exp(-((state[..., 2] - target_height) / 0.15).square())
    smooth = 0.05 * ((action - previous) / 0.1).square().mean(-1)
    reward = tracking + balance + height - smooth
    continuation = torch.sigmoid((state[..., 2] - 0.35) / 0.02) * torch.sigmoid((upright - 0.5) / 0.05)
    return reward, continuation


def imagined_rollout(dynamics, actor, critic, initial, previous, goal, context, config):
    state = initial
    survival = torch.ones(len(state))
    objective = torch.zeros(len(state))
    states, rewards, continuations = [state], [], []
    for t in range(config["horizon"]):
        action = actor(observation(state, previous, actor.body), goal)
        state = dynamics(state, action, context)
        reward, continuation = step_reward(state, action, previous, goal, actor.body["q_indices"], config["target_height_m"])
        objective = objective + config["gamma"] ** t * survival * reward
        survival = survival * continuation
        states.append(state)
        rewards.append(reward)
        continuations.append(continuation)
        previous = action
    if config.get("actor_critic_bootstrap", True):
        objective = objective + config["gamma"] ** config["horizon"] * survival * critic(state, goal, context)
    return objective.mean(), torch.stack(states, 1), torch.stack(rewards, 1), torch.stack(continuations, 1)


def gae_targets(critic, states, rewards, continuation, goals, contexts, config):
    with torch.no_grad():
        values = critic(states, goals[:, None].expand(-1, states.shape[1], -1),
                        contexts[:, None].expand(-1, states.shape[1], -1))
        advantage = torch.zeros(len(states))
        targets = []
        for t in reversed(range(rewards.shape[1])):
            delta = rewards[:, t] + config["gamma"] * continuation[:, t] * values[:, t + 1] - values[:, t]
            advantage = delta + config["gamma"] * config["gae_lambda"] * continuation[:, t] * advantage
            targets.append(advantage + values[:, t])
        return torch.stack(list(reversed(targets)), dim=1)


def physical_return_targets(rewards, continuation, terminated, tail_value, gamma):
    """Soft-return targets from one real episode; time limits retain a tail."""
    result = torch.empty_like(rewards)
    value = torch.as_tensor(tail_value, dtype=rewards.dtype)
    for i in reversed(range(len(rewards))):
        value = rewards[i] + gamma * continuation[i] * (~terminated[i]) * value
        result[i] = value
    return result.detach()


def fit_physics_critic(runtime, actor, critic, optimizer, experiment, config, seed, actor_update, stream, on_episodes=None):
    cases = [c for c in experiment["cases"] if c["split"] == "train"]
    if not cases or any(c["motion"] not in ["stand", "pose_offset"] for c in cases):
        raise ValueError("physics critic calibration requires constant-goal training cases")
    digest = hashlib.sha256()
    for name, value in actor.state_dict().items():
        digest.update(name.encode())
        digest.update(value.detach().numpy().tobytes())
    reset_seed = config["critic_collect_seed_base"] + 10000 * seed + actor_update // config["critic_physics_refresh_every"]
    def predict(obs, goal):
        with torch.no_grad():
            return actor(torch.tensor(obs, dtype=torch.float32)[None],
                         torch.tensor(goal, dtype=torch.float32)[None])[0].numpy()
    episodes, states, goals, contexts, targets, tails = [], [], [], [], [], []
    start = time.perf_counter()
    for case in cases:
        episode, _ = runtime.rollout(case, reset_seed, "policy", experiment["duration_s"],
            experiment["fall_height_m"], experiment["fall_upright_z"], policy=predict)
        steps = episode["steps"]
        state = torch.tensor([s["state"] for s in steps], dtype=torch.float32)
        next_state = torch.tensor([s["next_state"] for s in steps], dtype=torch.float32)
        action = torch.tensor([s["applied_action"] for s in steps], dtype=torch.float32)
        previous = torch.tensor([s["observation"][-runtime.model.nu:] for s in steps], dtype=torch.float32)
        goal = torch.tensor([s["goal"] for s in steps], dtype=torch.float32)
        context = torch.tensor(episode["context"], dtype=torch.float32)[None].expand(len(steps), -1)
        with torch.no_grad():
            reward, continuation = step_reward(next_state, action, previous, goal,
                                               actor.body["q_indices"], config["target_height_m"])
            tail = float(critic(next_state[-1:], goal[-1:], context[-1:])[0]) if steps[-1]["truncated"] else 0.0
            target = physical_return_targets(reward, continuation,
                torch.tensor([s["terminated"] for s in steps]), tail, config["gamma"])
        states.append(state); goals.append(goal); contexts.append(context); targets.append(target)
        tails.append(tail); episodes.append(episode)
    state, goal, context, target = map(torch.cat, [states, goals, contexts, targets])
    collection_seconds = time.perf_counter() - start
    model_update = on_episodes(episodes) if on_episodes is not None else None
    with torch.no_grad():
        before = float((critic(state, goal, context) - target).abs().mean())
    for p in critic.parameters():
        p.requires_grad_(True)
    for _ in range(config["critic_physics_fit_steps"]):
        indices = torch.randint(len(state), (config["critic_physics_minibatch_size"],))
        loss = (critic(state[indices], goal[indices], context[indices]) - target[indices]).square().mean()
        if not torch.isfinite(loss):
            raise ValueError("nonfinite physical critic loss")
        optimizer.zero_grad(); loss.backward()
        nn.utils.clip_grad_norm_(critic.parameters(), 1.0)
        optimizer.step()
    with torch.no_grad():
        after = float((critic(state, goal, context) - target).abs().mean())
    elapsed = time.perf_counter() - start
    stream.write(json.dumps(dict(format="moonrobo.g1-critic-physics-batch.v1", actor_update=actor_update,
        actor_state_sha256=digest.hexdigest(), reset_seed=reset_seed,
        dataset=runtime.dataset(episodes, experiment["source_revision"]),
        soft_return_targets=target.tolist(), tail_bootstrap_values=tails), allow_nan=False) + "\n")
    return dict(actor_update=actor_update, reset_seed=reset_seed, actor_state_sha256=digest.hexdigest(),
        episodes=len(episodes), transitions=len(state), falls=sum(e["steps"][-1]["terminated"] for e in episodes),
        time_limits=sum(e["steps"][-1]["truncated"] for e in episodes), collection_seconds=collection_seconds,
        total_seconds=elapsed, training_mae_before=before, training_mae_after=after,
        optimizer_steps=config["critic_physics_fit_steps"], model_update=model_update)


def evaluate_physics(runtime, experiment, seeds, actor=None, split=None):
    episodes, trials = [], []
    def predict(obs, goal):
        with torch.no_grad():
            return actor(torch.tensor(obs, dtype=torch.float32)[None],
                         torch.tensor(goal, dtype=torch.float32)[None])[0].numpy()
    for case in experiment["cases"]:
        if split is not None and case["split"] != split:
            continue
        for seed in seeds:
            episode, trial = runtime.rollout(case, seed, "position" if actor is None else "policy",
                                             experiment["duration_s"], experiment["fall_height_m"],
                                             experiment["fall_upright_z"], policy=None if actor is None else predict)
            episodes.append(episode)
            trials.append(trial)
    summary = dict(trials=len(trials), falls=sum(t["failed"] for t in trials),
                   mean_survival_s=sum(t["simulated_seconds"] for t in trials) / len(trials),
                   mean_joint_rmse_rad=sum(t["joint_rmse_rad"] for t in trials) / len(trials))
    return dict(summary=summary, trials=trials), episodes


def ranking(result):
    s = result["summary"]
    return (-s["falls"], s["mean_survival_s"], -s["mean_joint_rmse_rad"])


def qualifies(result, config):
    summary = result["summary"]
    return summary["falls"] == 0 and summary["mean_joint_rmse_rad"] <= config.get("max_mean_joint_rmse_rad", float("inf"))


def load_actor(path):
    checkpoint = torch.load(path, weights_only=True)
    if checkpoint["format"] != "moonrobo.g1-actor.v1":
        raise ValueError("this checkpoint requires its declared policy runner")
    names = ["obs_mean", "obs_scale", "goal_mean", "goal_scale", "lower", "upper"]
    actor = Actor({n: checkpoint["actor"][n] for n in names}, checkpoint["config"], checkpoint["body"])
    actor.load_state_dict(checkpoint["actor"])
    actor.eval()
    return actor, checkpoint


def train_seed(args, train, dynamics, dynamics_meta, config, experiment, seed, output, model_batches=None):
    torch.manual_seed(seed)
    online = None
    if config.get("online_model_updates", 0):
        from online_dynamics import OnlineDynamics
        if config.get("critic_training_source") != "physics-returns":
            raise ValueError("online dynamics requires physical collection")
        dynamics = copy.deepcopy(dynamics)
        online = OnlineDynamics(dynamics, train, config, seed)
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    body = dict(q_indices=runtime.q_indices.tolist(),
                v_state_indices=(runtime.v_indices + runtime.model.nq).tolist(), nq=runtime.model.nq)
    obs, goals = train.observation.flatten(0, 1), train.goal.flatten(0, 1)
    stats = dict(obs_mean=obs.mean(0), obs_scale=obs.std(0, unbiased=False).clamp_min(0.1),
                 goal_mean=goals.mean(0), goal_scale=goals.std(0, unbiased=False).clamp_min(0.1),
                 lower=torch.tensor(np.where(runtime.model.actuator_ctrllimited, runtime.model.actuator_ctrlrange[:, 0], -np.inf), dtype=torch.float32),
                 upper=torch.tensor(np.where(runtime.model.actuator_ctrllimited, runtime.model.actuator_ctrlrange[:, 1], np.inf), dtype=torch.float32))
    actor = Actor(stats, config, body)
    critic = Critic(dynamics.state_mean, dynamics.state_scale, len(dynamics.context_mean), config, len(stats["goal_mean"]))
    initialization = dict(mode="zero-residual")
    if args.warm_start_policy:
        prior_path = Path(args.warm_start_policy) / f"actor-seed-{seed}.pt"
        prior = torch.load(prior_path, weights_only=True)
        if prior["body"] != body or prior["model_ref"] != dynamics_meta["layout"]["model_ref"]:
            raise ValueError("warm-start actor body differs from current simulator")
        actor.load_state_dict(prior["actor"])
        critic.load_state_dict(prior["critic"])
        critic.enforce_input_encoding()
        initialization = dict(mode="weights-only-warm-start", checkpoint=str(prior_path),
                              sha256=hashlib.sha256(prior_path.read_bytes()).hexdigest(),
                              prior_selected_update=prior["selected_update"],
                              critic_encoding_changed=config.get("critic_horizontal_translation_invariant", False) !=
                                  prior["config"].get("critic_horizontal_translation_invariant", False))
    # Reconstructed proprioception must agree with the collector's actual observation.
    reconstructed = observation(train.state[:64, 0], train.observation[:64, 0, -runtime.model.nu:], body)
    if not torch.allclose(reconstructed, train.observation[:64, 0], atol=1e-5):
        raise ValueError("imagined and physics observations disagree")
    initial_weights = copy.deepcopy(actor.state_dict())
    actor_opt = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
    critic_opt = torch.optim.Adam(critic.parameters(), lr=config["critic_learning_rate"])
    critic_source = config.get("critic_training_source", "imagined-gae")
    if critic_source not in ["imagined-gae", "physics-returns", "frozen"]:
        raise ValueError("unknown critic training source")
    frozen_critic = copy.deepcopy(critic.state_dict()) if critic_source == "frozen" else None
    physics_batches, physics_stream, initial_physics_seconds = [], None, 0.0
    if critic_source == "physics-returns":
        collection_experiment = json.loads(Path(config["critic_collection_experiment"]).read_text())
        physics_path = output / f"critic-physics-seed-{seed}.jsonl.gz"
        physics_stream = gzip.open(physics_path, "wt", encoding="utf-8", compresslevel=1)
        initial_start = time.perf_counter()
        physics_batches.append(fit_physics_critic(runtime, actor, critic, critic_opt, collection_experiment,
                                                 config, seed, 0, physics_stream, online.update if online else None))
        initial_physics_seconds = time.perf_counter() - initial_start
    best_validation, _ = evaluate_physics(runtime, experiment, config["validation_seeds"], actor, "validation")
    best_actor, best_critic, selected_update = copy.deepcopy(actor.state_dict()), copy.deepcopy(critic.state_dict()), 0
    best_dynamics = copy.deepcopy(dynamics.state_dict()) if online else None
    best_model_round = online.rounds if online else 0
    history = [dict(update=0, validation=best_validation["summary"])]
    dynamics_weights = copy.deepcopy(dynamics.state_dict())
    start = time.perf_counter()
    for update in range(1, config["updates"] + 1):
        if physics_stream is not None and update > 1 and (update - 1) % config["critic_physics_refresh_every"] == 0:
            physics_batches.append(fit_physics_critic(runtime, actor, critic, critic_opt, collection_experiment,
                                                     config, seed, update - 1, physics_stream, online.update if online else None))
        frozen_step = {k: v.clone() for k, v in dynamics.state_dict().items()} if online else None
        indices = torch.randint(len(train.state), (config["batch_size"],))
        initial, goal, context = train.state[indices, 0], train.goal[indices, 0], train.context[indices]
        previous = train.observation[indices, 0, -runtime.model.nu:]
        for p in critic.parameters():
            p.requires_grad_(False)
        objective, states, rewards, continuation = imagined_rollout(dynamics, actor, critic, initial, previous, goal, context, config)
        if not torch.isfinite(objective):
            raise ValueError("nonfinite imagined policy objective")
        actor_opt.zero_grad()
        (-objective / config["horizon"]).backward()
        actor_grad = float(nn.utils.clip_grad_norm_(actor.parameters(), 1.0))
        if not np.isfinite(actor_grad):
            raise ValueError("nonfinite actor gradient")
        actor_opt.step()
        if frozen_step is not None and any(not torch.equal(v, dynamics.state_dict()[k]) for k, v in frozen_step.items()):
            raise ValueError("actor step changed its frozen world model")
        states, rewards, continuation = states.detach(), rewards.detach(), continuation.detach()
        if critic_source == "imagined-gae":
            targets = gae_targets(critic, states, rewards, continuation, goal, context, config)
            features = states[:, :-1].flatten(0, 1)
            repeated_goals = goal[:, None].expand(-1, config["horizon"], -1).flatten(0, 1)
            repeated_context = context[:, None].expand(-1, config["horizon"], -1).flatten(0, 1)
            for p in critic.parameters():
                p.requires_grad_(True)
            for _ in range(config["critic_epochs"]):
                for mini in torch.randperm(len(features)).chunk(4):
                    predicted = critic(features[mini], repeated_goals[mini], repeated_context[mini])
                    critic_loss = (predicted - targets.flatten()[mini]).square().mean()
                    if not torch.isfinite(critic_loss):
                        raise ValueError("nonfinite critic loss")
                    critic_opt.zero_grad()
                    critic_loss.backward()
                    nn.utils.clip_grad_norm_(critic.parameters(), 1.0)
                    critic_opt.step()
        else:
            critic_loss = None
        if abs(float(objective.detach())) > critic.value_bound + 1e-3:
            raise ValueError("imagined return exceeds the discounted reward bound")
        if update % config["evaluate_every"] == 0 or update in config.get("evaluation_updates", []):
            validation, _ = evaluate_physics(runtime, experiment, config["validation_seeds"], actor, "validation")
            history.append(dict(update=update, imagined_return=float(objective.detach()), actor_gradient_norm=actor_grad,
                                critic_loss=float(critic_loss.detach()) if critic_loss is not None else None,
                                physics_calibration=physics_batches[-1] if physics_batches else None,
                                validation=validation["summary"]))
            if ranking(validation) > ranking(best_validation):
                best_validation, best_actor, best_critic, selected_update = validation, copy.deepcopy(actor.state_dict()), copy.deepcopy(critic.state_dict()), update
                if online:
                    best_dynamics, best_model_round = copy.deepcopy(dynamics.state_dict()), online.rounds
            print(json.dumps(dict(seed=seed, **history[-1])), flush=True)
    elapsed = time.perf_counter() - start + initial_physics_seconds
    physics_payload = None
    if physics_stream is not None:
        physics_stream.close()
        physics_payload = dict(file=physics_path.name, sha256=hashlib.sha256(physics_path.read_bytes()).hexdigest(),
                               batches=physics_batches)
    if online is None and any(not torch.equal(v, dynamics.state_dict()[k]) for k, v in dynamics_weights.items()):
        raise ValueError("policy optimization changed frozen world-model weights")
    if frozen_critic is not None and any(not torch.equal(v, critic.state_dict()[k]) for k, v in frozen_critic.items()):
        raise ValueError("actor optimization changed frozen critic weights")
    online_evidence = None
    if online is not None:
        from dynamics import evaluate, gradient_probe
        fit_output = Path(config["online_dynamics_output"])
        fit_output.mkdir(parents=True, exist_ok=True)
        def save_model(name, weights, model_round):
            path = fit_output / name
            torch.save({**dynamics_meta, "model": weights, "seed": seed,
                        "selected_update": selected_update if name.startswith("dynamics-") else config["updates"],
                        "online_model_round": model_round, "online_physics_sha256": physics_payload["sha256"],
                        "normalization_source": "initial-training-windows-frozen"}, path)
            return hashlib.sha256(path.read_bytes()).hexdigest()
        latest_name = f"latest-dynamics-seed-{seed}.pt"
        latest_sha = save_model(latest_name, dynamics.state_dict(), online.rounds)
        dynamics.load_state_dict(best_dynamics)
        selected_name = f"dynamics-seed-{seed}.pt"
        selected_sha = save_model(selected_name, best_dynamics, best_model_round)
        metrics = {split: evaluate(dynamics, batch) for split, batch in model_batches.items()}
        probe = gradient_probe(dynamics, model_batches["validation"])
        restored_model, _ = load_model(fit_output / selected_name)
        if evaluate(restored_model, model_batches["test"]) != metrics["test"]:
            raise ValueError("selected online model reload changed predictions")
        online_evidence = dict(seed=seed, checkpoint=selected_name, latest_checkpoint=latest_name,
            selected_sha256=selected_sha, latest_sha256=latest_sha, selected_model_round=best_model_round,
            completed_model_rounds=online.rounds, model_optimizer_steps=online.optimizer_steps,
            metrics=metrics, gradient_probe=probe, reload_matches=True,
            normalization_source="initial-training-windows-frozen")
    changed = any(not torch.equal(v, actor.state_dict()[k]) for k, v in initial_weights.items())
    latest_checkpoint = output / f"latest-actor-seed-{seed}.pt"
    torch.save(dict(format="moonrobo.g1-actor.v1", actor=actor.state_dict(), critic=critic.state_dict(),
                    config=config, body=body, model_ref=dynamics_meta["layout"]["model_ref"], seed=seed,
                    selected_update=config["updates"], training_batch_sha256=train.digest,
                    initialization=initialization, online_dynamics=online_evidence,
                    paired_dynamics_sha256=online_evidence["latest_sha256"] if online else None), latest_checkpoint)
    actor.load_state_dict(best_actor)
    checkpoint = output / f"actor-seed-{seed}.pt"
    torch.save(dict(format="moonrobo.g1-actor.v1", actor=best_actor, critic=best_critic, config=config,
                    body=body, model_ref=dynamics_meta["layout"]["model_ref"], seed=seed,
                    selected_update=selected_update, training_batch_sha256=train.digest,
                    initialization=initialization, online_dynamics=online_evidence,
                    paired_dynamics_sha256=online_evidence["selected_sha256"] if online else None), checkpoint)
    restored, _ = load_actor(checkpoint)
    probe_obs, probe_goal = train.observation[:8, 0], train.goal[:8, 0]
    if not torch.equal(actor(probe_obs, probe_goal), restored(probe_obs, probe_goal)):
        raise ValueError("actor reload changed inference")
    baseline, _ = evaluate_physics(runtime, experiment, config["test_seeds"])
    candidate, episodes = evaluate_physics(runtime, experiment, config["test_seeds"], restored)
    (output / f"candidate-data-seed-{seed}.json").write_text(json.dumps(runtime.dataset(episodes, experiment["source_revision"]), allow_nan=False))
    (output / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline, candidate=candidate), indent=2, allow_nan=False))
    return dict(seed=seed, selected_update=selected_update, training_seconds=elapsed, initialization=initialization,
                actor_changed=changed, dynamics_unchanged=online is None, reload_matches=True,
                critic_unchanged=True if frozen_critic is not None else None,
                world_model_frozen_within_actor_updates=True, online_dynamics=online_evidence,
                baseline=baseline["summary"], candidate=candidate["summary"],
                qualifies=qualifies(candidate, config), history=history, checkpoint=checkpoint.name,
                latest_checkpoint=latest_checkpoint.name, critic_training_source=critic_source,
                critic_physics=physics_payload)


def collect(args):
    actor, metadata = load_actor(args.checkpoint)
    torch.set_num_threads(metadata["config"]["cpu_threads"])
    experiment = json.loads(Path(args.experiment).read_text())
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    episodes, trials = [], []
    policy_digest = hashlib.sha256(Path(args.checkpoint).read_bytes()).hexdigest()
    def predict(obs, goal):
        with torch.no_grad():
            return actor(torch.tensor(obs, dtype=torch.float32)[None],
                         torch.tensor(goal, dtype=torch.float32)[None])[0].numpy()
    for case in experiment["cases"]:
        if case["split"] != args.split:
            continue
        for seed in experiment["seeds"]:
            episode, trial = runtime.rollout(case, seed, "policy", experiment["duration_s"],
                                             experiment["fall_height_m"], experiment["fall_upright_z"],
                                             experiment["action_noise_std_rad"], predict)
            episode["id"] += "-" + policy_digest[:12]
            trial["episode_id"] = episode["id"]
            episodes.append(episode)
            trials.append(trial)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    dataset = runtime.dataset(episodes, experiment["source_revision"])
    dataset["provenance"] += "; exploratory policy checkpoint " + policy_digest
    (output / "dataset.json").write_text(json.dumps(dataset, allow_nan=False))
    summary = dict(episodes=len(episodes), transitions=sum(len(e["steps"]) for e in episodes),
                   falls=sum(t["failed"] for t in trials), split=args.split,
                   policy_sha256=policy_digest)
    (output / "report.json").write_text(json.dumps(dict(summary=summary, experiment=experiment, trials=trials), indent=2, allow_nan=False))
    print(json.dumps(summary))


def evaluate_checkpoint(args):
    actor, metadata = load_actor(args.checkpoint)
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    torch.set_num_threads(config["cpu_threads"])
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    body = dict(q_indices=runtime.q_indices.tolist(),
                v_state_indices=(runtime.v_indices + runtime.model.nq).tolist(), nq=runtime.model.nq)
    if body != metadata["body"]:
        raise ValueError("checkpoint body differs from evaluator")
    baseline, _ = evaluate_physics(runtime, experiment, config["test_seeds"])
    candidate, _ = evaluate_physics(runtime, experiment, config["test_seeds"], actor)
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    report = dict(format="moonrobo.g1-checkpoint-evaluation.v1", baseline=baseline, candidate=candidate,
                  checkpoint_sha256=hashlib.sha256(Path(args.checkpoint).read_bytes()).hexdigest(),
                  experiment=experiment, evaluation_seeds=config["test_seeds"], evaluation_action_noise_std_rad=0.0,
                  body=body, policy_config=metadata["config"], model_ref=metadata["model_ref"])
    (output / "physics.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(output=str(output / "physics.json"), candidate=candidate["summary"])))


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    train = WindowBatch(args.train, "train")
    dynamics, metadata = load_model(args.dynamics)
    if train.layout != metadata["layout"] or train.digest != metadata["training_batch_sha256"]:
        raise ValueError("policy data must match the selected dynamics training artifact")
    model_training_digest = train.digest
    if args.policy_replay:
        replay = WindowBatch(args.policy_replay, "train")
        train.compatible(replay, require_dataset_id=False)
        for field in ["observation_axes", "goal_axes"]:
            if train.layout[field] != replay.layout[field]:
                raise ValueError("policy replay schema differs: " + field)
        train = replay
    for parameter in dynamics.parameters():
        parameter.requires_grad_(False)
        parameter.grad = None
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    model_batches = None
    if config.get("online_model_updates", 0):
        model_batches = {"validation": WindowBatch(config["model_validation_batch"], "validation"),
                         "test": WindowBatch(config["model_test_batch"], "test")}
        for batch in model_batches.values():
            train.compatible(batch)
    runs = [train_seed(args, train, dynamics, metadata, config, experiment, seed, output, model_batches) for seed in config["seeds"]]
    if model_batches is not None:
        fit_report = dict(format="moonrobo.dynamics-fit.v1", evidence_class="learned-model-prediction",
            config=config, initial_dynamics_sha256=hashlib.sha256(Path(args.dynamics).read_bytes()).hexdigest(),
            normalization_source="initial-training-windows-frozen", selection_source="paired-policy-validation",
            inputs={split: batch.digest for split, batch in model_batches.items()},
            runs=[r["online_dynamics"] for r in runs],
            all_passed=all(r["online_dynamics"]["gradient_probe"]["passed"] and
                           r["online_dynamics"]["metrics"]["test"]["beats_persistence"] for r in runs))
        (Path(config["online_dynamics_output"]) / "report.json").write_text(json.dumps(fit_report, indent=2, allow_nan=False))
    report = dict(format="moonrobo.g1-policy-fit.v1", config=config, runs=runs,
                  evidence_class="physics-simulation", checkpoint_selection="validation-physics-only",
                  dynamics_sha256=hashlib.sha256(Path(args.dynamics).read_bytes()).hexdigest(),
                  dynamics_training_batch_sha256=model_training_digest,
                  policy_replay_sha256=train.digest,
                  provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  experiment=experiment, any_qualified=any(r["qualifies"] for r in runs))
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(report=str(output / "report.json"), runs=runs)), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    fit_parser = commands.add_parser("fit")
    for name in ["train", "dynamics", "scene", "config", "experiment", "output"]:
        fit_parser.add_argument("--" + name, required=True)
    fit_parser.add_argument("--warm-start-policy")
    fit_parser.add_argument("--policy-replay", help="Compatible explicit actor replay; model training artifact is still verified independently")
    collect_parser = commands.add_parser("collect")
    for name in ["checkpoint", "scene", "experiment", "output"]:
        collect_parser.add_argument("--" + name, required=True)
    collect_parser.add_argument("--split", choices=["train", "validation", "test"], default="train")
    evaluate_parser = commands.add_parser("evaluate")
    for name in ["checkpoint", "scene", "experiment", "config", "output"]:
        evaluate_parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    if args.command == "fit":
        run(args)
    elif args.command == "collect":
        collect(args)
    else:
        evaluate_checkpoint(args)
