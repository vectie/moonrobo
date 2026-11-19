"""Compare initial/adapted actor gradients against paired restored physics."""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from actor_update_probe import adam_direction, collect_origins, physical_window, scaled_actor
from cpu_physics import PhysicsRuntime
from critic_probe import load_critic
from dynamics import WindowBatch, load_model
from policy import imagined_rollout, load_actor


def predicted_changes(model, actor, candidate, critic, batch, settings):
    values = {}
    with torch.no_grad():
        for bootstrap in [False, True]:
            config = {**settings, "actor_critic_bootstrap": bootstrap}
            before = float(imagined_rollout(model, actor, critic, *batch, config)[0])
            after = float(imagined_rollout(model, candidate, critic, *batch, config)[0])
            values["bootstrapped" if bootstrap else "reward"] = after - before
    return values


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    replay = WindowBatch(args.train, "train")
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    records, summaries, saved_origins, bindings, restore_errors = [], [], [], [], []
    for seed in config["policy_seeds"]:
        checkpoint = Path(args.policies) / f"actor-seed-{seed}.pt"
        actor, actor_meta = load_actor(checkpoint)
        critic, _ = load_critic(checkpoint)
        for p in critic.parameters():
            p.requires_grad_(False)
        settings = {**actor_meta["config"], **config, "actor_critic_bootstrap": True}
        full_settings = {**settings, "horizon": config["full_horizon"], "actor_critic_bootstrap": False}
        origins, omitted = collect_origins(runtime, actor, experiment, settings)
        if not origins:
            raise ValueError("no physical origins")
        tensor = lambda name: torch.tensor([o[name] for o in origins], dtype=torch.float32)
        recent = (tensor("state"), tensor("previous"), tensor("goal"), tensor("context"))
        generator = torch.Generator().manual_seed(config["sampling_seed"] + seed)
        indices = torch.randint(len(replay.state), (config["direction_batch_size"],), generator=generator)
        offline = (replay.state[indices, 0], replay.observation[indices, 0, -runtime.model.nu:],
                   replay.goal[indices, 0], replay.context[indices])
        baselines, full_baselines = [], []
        for origin in origins:
            result, states, actions = physical_window(runtime, origin, actor, critic, settings)
            reference = origin.pop("reference")
            if len(states) != len(reference):
                raise ValueError("restored closed-loop length differs")
            error = max(float(np.max(np.abs(np.array(values) - np.array([s[key] for s in reference]))))
                        for values, key in [(states, "next_state"), (actions, "applied_action")])
            if error > 1e-8:
                raise ValueError("restored closed-loop trajectory differs")
            restore_errors.append(error)
            baselines.append(result)
            full_baselines.append(physical_window(runtime, origin, actor, critic, full_settings)[0])
        directions = {}
        paths = {"initial": Path(args.initial), "adapted": Path(args.adapted) / f"dynamics-seed-{seed}.pt"}
        for label, path in paths.items():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if label == "adapted" and digest != actor_meta["paired_dynamics_sha256"]:
                raise ValueError("actor is not paired with this adapted model")
            model, metadata = load_model(path)
            if metadata["training_batch_sha256"] != replay.digest or metadata["layout"] != replay.layout:
                raise ValueError("probe replay differs from model training artifact")
            for p in model.parameters():
                p.requires_grad_(False)
            bindings.append(dict(policy_seed=seed, model=label, dynamics_sha256=digest,
                policy_sha256=hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
                selected_update=actor_meta["selected_update"], model_round=metadata.get("online_model_round", 0)))
            for bootstrap in config["direction_bootstrap"]:
                direction_settings = {**settings, "actor_critic_bootstrap": bootstrap}
                delta, objective, norm = adam_direction(model, actor, critic, offline, direction_settings)
                directions[f"{label}-bootstrap-{bootstrap}"] = delta
                for multiplier in config["multipliers"]:
                    candidate = scaled_actor(actor, delta, multiplier)
                    predicted = predicted_changes(model, actor, candidate, critic, recent, settings)
                    outcomes, full_outcomes = [], []
                    for i, origin in enumerate(origins):
                        result = baselines[i] if multiplier == 0 else physical_window(runtime, origin, candidate, critic, settings)[0]
                        full = full_baselines[i] if multiplier == 0 else physical_window(runtime, origin, candidate, critic, full_settings)[0]
                        outcomes.append(result)
                        full_outcomes.append(full)
                        records.append(dict(policy_seed=seed, model=label, direction_bootstrap=bootstrap,
                            multiplier=multiplier, case=origin["case"], reset_seed=origin["reset_seed"],
                            start_step=origin["start_step"], baseline=baselines[i], candidate=result,
                            full_baseline=full_baselines[i], full_candidate=full))
                    change = lambda key: float(np.mean([r[key] - b[key] for r, b in zip(outcomes, baselines)]))
                    summaries.append(dict(policy_seed=seed, model=label, direction_bootstrap=bootstrap,
                        multiplier=multiplier, origins=len(origins), omitted_origins=len(omitted),
                        direction_batch_size=len(indices), gradient_norm=norm, fit_objective=objective,
                        predicted_recent_reward_change=predicted["reward"], predicted_recent_bootstrapped_change=predicted["bootstrapped"],
                        physical_reward_change=change("reward_return"), physical_bootstrapped_change=change("bootstrapped_return"),
                        full_physical_reward_change=float(np.mean([r["reward_return"] - b["reward_return"] for r, b in zip(full_outcomes, full_baselines)])),
                        full_reward_improves_fraction=float(np.mean([r["reward_return"] > b["reward_return"] for r, b in zip(full_outcomes, full_baselines)])),
                        mean_full_steps_change=float(np.mean([r["steps"] - b["steps"] for r, b in zip(full_outcomes, full_baselines)])),
                        full_baseline_falls=sum(b["failed"] for b in full_baselines), full_candidate_falls=sum(r["failed"] for r in full_outcomes),
                        window_baseline_falls=sum(b["failed"] for b in baselines), window_candidate_falls=sum(r["failed"] for r in outcomes)))
        torch.save(dict(actor=actor.state_dict(), critic=critic.state_dict(), directions=directions,
                        config=settings, bindings=[b for b in bindings if b["policy_seed"] == seed]),
                   output / f"directions-seed-{seed}.pt")
        saved_origins.append(dict(policy_seed=seed, origins=origins, omitted=omitted))
    summary = dict(format="moonrobo.g1-paired-model-probe.v1", config=config, experiment=experiment,
        bindings=bindings, training_batch_sha256=replay.digest, maximum_restore_error=max(restore_errors),
        summaries=summaries, physical_execution_allowed=False,
        scope="One fresh-Adam replay step with/without critic-tail gradients. Same actor, critic, replay batch and restored training origins for initial/adapted models. Window returns use the same critic; full physical reward has no critic tail and ends at actual fall or the declared cap. No release selection.")
    (output / "report.json").write_text(json.dumps(dict(**summary, origins=saved_origins, records=records), indent=2, allow_nan=False))
    (output / "summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False))
    print(json.dumps(dict(report=str(output / "report.json"), maximum_restore_error=max(restore_errors))))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["train", "initial", "adapted", "policies", "scene", "config", "experiment", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
