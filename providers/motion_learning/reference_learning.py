"""Matched full-reference physics collection, value fitting and policy updates."""
import copy
import hashlib
from pathlib import Path
import time

import numpy as np
import torch
from torch.distributions import Normal

from dynamics import ResidualDynamics, imagine
from full_body_reference import replay_reference
from policy import observation
from reference_actor import ReferenceRunner
from reference_task import observer_advance, observer_memory, reference_reward


BODY = dict(q_indices=list(range(7, 36)), v_state_indices=list(range(42, 71)), nq=36)


def state_digest(module):
    digest = hashlib.sha256()
    for name, value in module.state_dict().items():
        digest.update(name.encode()); digest.update(value.detach().cpu().numpy().tobytes())
    return digest.hexdigest()


def value_at(value, batch, schedule):
    c, s = batch["clip"], batch["step"]
    return value(batch["state"], batch["history"], batch["current"], batch["actual_features"],
        batch["reference_features"], batch["context"], c, s, batch["remaining"],
        schedule.positions[c, s, 0], schedule.quaternions[c, s])


def take(batch, ids):
    return {key: values[ids] for key, values in batch.items() if isinstance(values, torch.Tensor)}


def finite_returns(reward, gamma):
    result = torch.empty_like(reward)
    tail = 0.
    for i in reversed(range(len(reward))):
        tail = reward[i]+gamma*tail; result[i] = tail
    return result


def collect_episode(runtime, references, schedule, actor, geometry, config, clip_index, origin, seed, cycle, role, output, behavior):
    clip, reference = references[clip_index]
    runner = ReferenceRunner(actor, geometry, runtime.dt)
    noise = torch.Generator().manual_seed(config["noise_seed_base"]+seed*1000000+cycle*1000+clip_index+
        origin*config.get("noise_seed_origin_stride", 0)+(50000 if role=="model-diagnostic" else 0))
    captured = {key: [] for key in ["latent", "old_mean", "actual_features", "reference_features"]}
    std = config["raw_action_std"] if role in ["training", "common-first-collection", "model-diagnostic"] else 0.
    def predict(obs, current, future, valid):
        runner(obs, current, future, valid)
        with torch.no_grad():
            h, cur, fut, mask, a, r = runner.last_inputs
            mean = actor.latent_mean(h, cur, fut, mask)
            latent = mean + std*torch.randn(mean.shape, generator=noise)
            captured["latent"].append(latent[0].clone()); captured["old_mean"].append(mean[0].clone())
            captured["actual_features"].append(a[0].clone()); captured["reference_features"].append(r[0].clone())
            return actor.action_from_latent(latent, h, cur, a, r)[0].numpy()
    episode, trial = replay_reference(runtime, reference, clip["case"], origin, "policy", policy=predict,
        preview_length=actor.future_length)
    episode["id"] += f"-{Path(output).parent.name}-{role}-seed-{seed}-cycle-{cycle}"
    trial["episode_id"] = episode["id"]
    steps = episode["steps"]; n = len(steps)
    data = {key: torch.tensor([s[key] for s in steps], dtype=torch.float32) for key in ["state", "observation", "applied_action", "next_state"]}
    data.update({key: torch.stack(values) for key, values in captured.items()})
    phases = origin+torch.arange(n)
    clips = torch.full((n,), clip_index, dtype=torch.long)
    current, future, valid = schedule.command(clips, phases, actor.future_length)
    histories = (torch.arange(n)[:, None]-torch.arange(actor.history_length-1, -1, -1)[None]).clamp_min(0)
    with torch.no_grad():
        reward, fallen, _ = reference_reward(geometry, data["next_state"], data["applied_action"], data["observation"][:, -29:],
            schedule.positions[clips, phases+1], schedule.quaternions[clips, phases+1], schedule.goals[clips, phases+1, :29], runtime.dt)
        action = actor.action_from_latent(data["latent"], data["observation"][histories], current,
            data["actual_features"], data["reference_features"])
        alignment = float((action-data["applied_action"]).abs().max())
        if alignment > config["maximum_action_alignment_error_rad"]:
            raise ValueError("collected latent and applied control disagree")
        expected_reference = schedule.features(clips, torch.full_like(phases, origin), phases)
        feature_error = float((expected_reference-data["reference_features"]).abs().max())
        if feature_error > config["maximum_feature_alignment_error"]:
            raise ValueError("precomputed planned observer differs from physical runner")
        if not torch.equal(fallen, torch.tensor([s["terminated"] for s in steps])):
            raise ValueError("shared fall test differs from physical harness")
    done = torch.zeros(n, dtype=torch.bool); done[-1] = True
    for i, step in enumerate(steps):
        step["reward"] = float(reward[i])
    folder = Path(output)/"physics"/role
    folder.mkdir(parents=True, exist_ok=True)
    path = folder/(episode["id"]+".npz")
    np.savez_compressed(path, **{key: value.numpy() for key, value in data.items()}, reward=reward.numpy(),
        terminated=np.asarray([s["terminated"] for s in steps]), truncated=np.asarray([s["truncated"] for s in steps]))
    record = dict(file=str(path.relative_to(output)), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        episode_id=episode["id"], reference_id=clip["id"], reference_sha256=clip["sha256"],
        source_family=clip["source_family"], split="train", context=episode["context"],
        clip_index=clip_index, origin_step=origin, seed=seed, cycle=cycle, role=role, steps=n,
        behavior=behavior, action_std=std, maximum_action_alignment_error=alignment,
        maximum_reference_feature_error=feature_error)
    batch = dict(state=data["state"], next_state=data["next_state"], history=data["observation"][histories],
        current=current, future=future, valid=valid, actual_features=data["actual_features"],
        reference_features=data["reference_features"], action=data["applied_action"], previous=data["observation"][:, -29:],
        latent=data["latent"], old_mean=data["old_mean"], reward=reward, done=done,
        returns=finite_returns(reward, config["gamma"]), clip=clips, step=phases,
        origin=torch.full_like(phases, origin), remaining=schedule.length-phases,
        context=torch.tensor(episode["context"], dtype=torch.float32)[None].expand(n, -1))
    return batch, record, trial


def join_batches(batches):
    result = {key: torch.cat([batch[key] for batch in batches]) for key in batches[0]}
    result["episode_lengths"] = [len(batch["state"]) for batch in batches]
    return result


def restore_collected_batch(folder, record, actor, schedule, config):
    """Restore the exact causal learning inputs from one physical archive."""
    path = Path(folder)/record["file"]
    if hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
        raise ValueError("reused physical archive changed")
    with np.load(path, allow_pickle=False) as archive:
        data = {key: torch.from_numpy(archive[key]) for key in archive.files}
    n, origin = record["steps"], record["origin_step"]
    phases = origin+torch.arange(n)
    clips = torch.full((n,), record["clip_index"], dtype=torch.long)
    current, future, valid = schedule.command(clips, phases, actor.future_length)
    indices = (torch.arange(n)[:, None]-torch.arange(actor.history_length-1, -1, -1)[None]).clamp_min(0)
    done = torch.zeros(n, dtype=torch.bool); done[-1] = True
    return dict(state=data["state"], next_state=data["next_state"], history=data["observation"][indices],
        current=current, future=future, valid=valid, actual_features=data["actual_features"],
        reference_features=data["reference_features"], action=data["applied_action"], previous=data["observation"][:, -29:],
        latent=data["latent"], old_mean=data["old_mean"], reward=data["reward"], done=done,
        returns=finite_returns(data["reward"], config["gamma"]), clip=clips, step=phases,
        origin=torch.full_like(phases, origin), remaining=schedule.length-phases,
        context=torch.tensor(record["context"], dtype=torch.float32)[None].expand(n, -1))


def actor_origin_indices(replay, config, generator):
    mode = config.get("actor_origin_sampling", "reset-starts")
    count = config["actor_batch_size"]
    if mode == "trajectory-states":
        return torch.randint(len(replay["state"]), (count,), generator=generator)
    if mode != "reset-starts": raise ValueError("unknown actor origin distribution")
    starts = torch.tensor([0]+list(np.cumsum(replay["episode_lengths"])[:-1]))
    return starts[torch.randint(len(starts), (count,), generator=generator)]


def fit_value(value, optimizer, batch, schedule, config, generator):
    for p in value.parameters(): p.requires_grad_(True)
    start = time.perf_counter()
    for _ in range(config["critic_updates_per_cycle"]):
        ids = torch.randint(len(batch["state"]), (config["critic_batch_size"],), generator=generator)
        loss = ((value_at(value, take(batch, ids), schedule)-batch["returns"][ids])/6).square().mean()
        if not torch.isfinite(loss): raise ValueError("nonfinite reference value fit")
        optimizer.zero_grad(); loss.backward(); torch.nn.utils.clip_grad_norm_(value.parameters(), 1.); optimizer.step()
    for p in value.parameters(): p.requires_grad_(False); p.grad = None
    return dict(updates=config["critic_updates_per_cycle"], loss=float(loss.detach()), seconds=time.perf_counter()-start,
        state_sha256=state_digest(value))


class ReferenceModelReplay:
    def __init__(self, initial, config, seed):
        self.config = config
        self.generator = torch.Generator().manual_seed(70000+seed)
        self.parts = None
        self.initial_parts, self.recent_parts = None, None
        self.append_count, self.anchor_windows = 0, 0
        self.append(initial)
        stats = {}
        for key, values in [("state", initial["state"]), ("action", initial["action"]), ("context", initial["context"])]:
            stats[key+"_mean"] = values.mean(0)
            stats[key+"_scale"] = values.std(0, unbiased=False).clamp_min(config["model_normalization_floor"])
        self.model = ResidualDynamics(stats, config["model_width"], horizontal_translation_invariant=True)
        self.optimizer = torch.optim.Adam(self.model.parameters(), lr=config["model_learning_rate"])

    def append(self, batch):
        parts = {key: [] for key in ["state", "action", "target", "context"]}
        start, horizon = 0, self.config["model_window"]
        for length in batch["episode_lengths"]:
            if length >= horizon:
                for dest, source in [("state", "state"), ("action", "action"), ("target", "next_state")]:
                    parts[dest].append(batch[source][start:start+length].unfold(0, horizon, 1).movedim(-1, 1))
                parts["context"].append(batch["context"][start:start+1].expand(length-horizon+1, -1))
            start += length
        if not parts["state"]: raise ValueError("no complete model windows in collected physics")
        fresh = {key: torch.cat(value) for key, value in parts.items()}
        self.append_count += 1
        capacity = self.config["model_replay_windows"]
        anchor_after = self.config.get("model_initial_anchor_after_cycle")
        if anchor_after is not None:
            if self.initial_parts is None:
                self.initial_parts = {key: value.clone() for key, value in fresh.items()}
                if len(self.initial_parts["state"]) >= capacity: raise ValueError("initial anchor leaves no recent-window capacity")
            else:
                self.recent_parts = {key: (torch.cat((self.recent_parts[key], value)) if self.recent_parts is not None else value)[-capacity:]
                    for key, value in fresh.items()}
        self.parts = {key: (torch.cat((self.parts[key], value)) if self.parts is not None else value)[-self.config["model_replay_windows"]:]
            for key, value in fresh.items()}
        if anchor_after is not None and self.append_count > anchor_after:
            self.anchor_windows = len(self.initial_parts["state"])
            recent_capacity = capacity-self.anchor_windows
            self.parts = {key: torch.cat((value, self.recent_parts[key][-recent_capacity:]))
                for key, value in self.initial_parts.items()}

    def fit(self):
        start = time.perf_counter()
        samples = hashlib.sha256(); anchor_samples = 0
        for p in self.model.parameters(): p.requires_grad_(True)
        for _ in range(self.config["model_updates_per_cycle"]):
            ids = torch.randint(len(self.parts["state"]), (self.config["model_batch_size"],), generator=self.generator)
            samples.update(ids.numpy().tobytes()); anchor_samples += int((ids < self.anchor_windows).sum())
            prediction = imagine(self.model, self.parts["state"][ids, 0], self.parts["action"][ids], self.parts["context"][ids])
            loss = ((prediction-self.parts["target"][ids])/self.model.state_scale).square().mean()
            if not torch.isfinite(loss): raise ValueError("nonfinite reference world-model fit")
            self.optimizer.zero_grad(); loss.backward(); torch.nn.utils.clip_grad_norm_(self.model.parameters(), 1.); self.optimizer.step()
        for p in self.model.parameters(): p.requires_grad_(False); p.grad = None
        return dict(updates=self.config["model_updates_per_cycle"], windows=len(self.parts["state"]), loss=float(loss.detach()), seconds=time.perf_counter()-start,
            replay_mode="initial-anchor" if self.anchor_windows else "recent-fifo", anchor_windows=self.anchor_windows,
            recent_windows=len(self.parts["state"])-self.anchor_windows, anchor_samples=anchor_samples,
            sample_indices_sha256=samples.hexdigest())


def imagined_objective(model, actor, value, batch, geometry, schedule, config):
    feedback_gradient = config.get("actor_feedback_gradient", "full")
    if feedback_gradient not in ["full", "stop-policy-inputs"]:
        raise ValueError("unknown actor feedback-gradient route")
    state, history = batch["state"], batch["history"]
    features = batch["actual_features"]
    memory = observer_memory(history[:, -1], features)
    clips, phases, origins = batch["clip"], batch["step"], batch["origin"]
    reference_features = batch["reference_features"]
    alive = torch.ones(len(state)); objective = torch.zeros(len(state)); active_steps = 0
    for t in range(config["imagination_horizon"]):
        current, future, valid = schedule.command(clips, phases, actor.future_length)
        # Only the policy-input edge changes. Forward observations/EMA remain
        # intact, as do plant BPTT and the previous-action reward derivative.
        policy_history = history.detach() if feedback_gradient=="stop-policy-inputs" else history
        policy_features = features.detach() if feedback_gradient=="stop-policy-inputs" else features
        action = actor(policy_history, current, future, valid, policy_features, reference_features)
        predicted = model(state, action, batch["context"])
        next_phase = (phases+1).clamp_max(schedule.length)
        reward, fallen, error = reference_reward(geometry, predicted, action, history[:, -1, -29:],
            schedule.positions[clips, next_phase], schedule.quaternions[clips, next_phase], schedule.goals[clips, next_phase, :29], schedule.dt)
        objective = objective + config["gamma"]**t*alive*reward
        active_steps += int(alive.detach().sum())
        mask = alive[:, None] > 0
        state = torch.where(mask, predicted, state)
        obs = observation(state, action, BODY)
        next_features, next_memory = observer_advance(geometry, obs, memory, schedule.dt, error=error)
        features = torch.where(mask, next_features, features); memory = torch.where(mask, next_memory, memory)
        history = torch.where(mask[:, None], torch.cat((history[:, 1:], obs[:, None]), 1), history)
        phases = next_phase
        reference_features = schedule.features(clips, origins, phases)
        alive = alive*(~fallen).float()*(phases < schedule.length).float()
    if config.get("actor_critic_tail", True):
        current, _, _ = schedule.command(clips, phases, actor.future_length)
        tail = value(state, history, current, features, reference_features, batch["context"], clips, phases,
            schedule.length-phases, schedule.positions[clips, phases, 0], schedule.quaternions[clips, phases])
        objective = objective + config["gamma"]**config["imagination_horizon"]*alive*tail
    return objective.mean(), active_steps


def optimize_model_actor(model, actor, value, optimizer, replay, geometry, schedule, config, generator):
    before = {key: value.clone() for key, value in model.state_dict().items()}
    start = time.perf_counter(); total_active = 0
    cap = config.get("actor_logit_rms_cap")
    calibration = None
    step_scales = []
    origin_samples = []
    if cap is not None:
        if cap <= 0: raise ValueError("positive logit step cap required")
        ids = torch.randint(len(replay["state"]), (config["actor_calibration_batch_size"],), generator=generator)
        calibration = take(replay, ids)
    for _ in range(config["maximum_actor_steps_per_cycle"]):
        ids = actor_origin_indices(replay, config, generator)
        ages = replay["step"][ids]-replay["origin"][ids]
        origin_samples.append(dict(replay_indices=ids.tolist(), minimum_age_steps=int(ages.min()),
            maximum_age_steps=int(ages.max()), mean_age_steps=float(ages.float().mean()), nonreset_samples=int((ages>0).sum())))
        objective, active = imagined_objective(model, actor, value, take(replay, ids), geometry, schedule, config)
        if not torch.isfinite(objective): raise ValueError("nonfinite reference imagined objective")
        optimizer.zero_grad(); (-objective).backward(); norm = torch.nn.utils.clip_grad_norm_(actor.parameters(), 1.)
        if not torch.isfinite(norm): raise ValueError("nonfinite reference policy gradient")
        if calibration is not None:
            with torch.no_grad():
                base = torch.nn.utils.parameters_to_vector(actor.parameters()).clone()
                old_mean = actor.latent_mean(calibration["history"], calibration["current"], calibration["future"], calibration["valid"])
        optimizer.step()
        if calibration is not None:
            with torch.no_grad():
                delta = torch.nn.utils.parameters_to_vector(actor.parameters())-base
                def rms():
                    new_mean = actor.latent_mean(calibration["history"], calibration["current"], calibration["future"], calibration["valid"])
                    return float((new_mean-old_mean).square().mean().sqrt())
                raw_rms = rms()
                if not np.isfinite(raw_rms): raise ValueError("nonfinite proposed policy step")
                scale, applied = 1., raw_rms
                if applied > cap:
                    scale = .99*cap/applied
                    torch.nn.utils.vector_to_parameters(base+scale*delta, actor.parameters())
                    applied = rms()
                    while applied > cap:
                        scale *= .5
                        torch.nn.utils.vector_to_parameters(base+scale*delta, actor.parameters())
                        applied = rms()
                if not np.isfinite(applied): raise ValueError("nonfinite calibrated policy step")
                step_scales.append(dict(proposed_logit_rms=raw_rms, applied_logit_rms=applied, parameter_step_scale=scale))
        total_active += active
    if any(not torch.equal(v, model.state_dict()[k]) for k, v in before.items()) or any(p.grad is not None for p in model.parameters()):
        raise ValueError("world model changed during policy optimization")
    return dict(actor_steps=config["maximum_actor_steps_per_cycle"], imagined_tensor_steps=config["maximum_actor_steps_per_cycle"]*config["actor_batch_size"]*config["imagination_horizon"],
        active_imagined_steps=total_active, last_objective=float(objective.detach()), last_gradient_norm=float(norm), frozen_model_unchanged=True,
        seconds=time.perf_counter()-start, critic_tail_used=config.get("actor_critic_tail", True),
        logit_step_calibration=step_scales, origin_sampling=config.get("actor_origin_sampling", "reset-starts"),
        actor_origin_samples=origin_samples)


def ppo_advantages(value, batch, schedule, config):
    with torch.no_grad():
        values = value_at(value, batch, schedule)
        following = torch.cat((values[1:], torch.zeros_like(values[:1])))
        delta = batch["reward"]+config["gamma"]*(~batch["done"])*following-values
        advantage = torch.empty_like(delta); carry = 0.
        for i in reversed(range(len(delta))):
            carry = delta[i]+config["gamma"]*config["gae_lambda"]*(~batch["done"][i])*carry
            advantage[i] = carry
        return advantage/advantage.std(unbiased=False).clamp_min(1e-6)


def optimize_ppo_actor(actor, optimizer, batch, advantages, config, generator):
    std = config["raw_action_std"]
    old_log = Normal(batch["old_mean"], std).log_prob(batch["latent"]).sum(-1)
    start = time.perf_counter(); updates = 0; maximum_kl = 0.; stopped = False
    visitation = config["gamma"]**(batch["step"]-batch["origin"]).float()
    visitation = visitation/visitation.mean().clamp_min(1e-8)
    for _ in range(config["ppo_epochs"]):
        for ids in torch.randperm(len(batch["state"]), generator=generator).split(config["ppo_minibatch_size"]):
            mean = actor.latent_mean(batch["history"][ids], batch["current"][ids], batch["future"][ids], batch["valid"][ids])
            ratio = (Normal(mean, std).log_prob(batch["latent"][ids]).sum(-1)-old_log[ids]).exp()
            loss = -(visitation[ids]*torch.minimum(ratio*advantages[ids], ratio.clamp(1-config["ppo_clip"], 1+config["ppo_clip"])*advantages[ids])).mean()
            if not torch.isfinite(loss): raise ValueError("nonfinite reference PPO loss")
            optimizer.zero_grad(); loss.backward(); torch.nn.utils.clip_grad_norm_(actor.parameters(), 1.); optimizer.step(); updates += 1
            with torch.no_grad():
                kls = []
                for first in range(0, len(batch["state"]), 512):
                    b = take(batch, slice(first, first+512))
                    new = actor.latent_mean(b["history"], b["current"], b["future"], b["valid"])
                    kls.append(.5*((new-b["old_mean"])/std).square().sum(-1))
                kl = float(torch.cat(kls).mean()); maximum_kl = max(maximum_kl, kl)
            if kl > config["ppo_target_kl"] or updates >= config["maximum_actor_steps_per_cycle"]:
                stopped = kl > config["ppo_target_kl"]; break
        if stopped or updates >= config["maximum_actor_steps_per_cycle"]: break
    return dict(actor_steps=updates, maximum_kl=maximum_kl, kl_early_stopped=stopped, last_policy_loss=float(loss.detach()), seconds=time.perf_counter()-start)
