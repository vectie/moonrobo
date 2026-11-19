"""Initialize the existing proprioceptive actor from actual teacher transitions."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from dynamics import WindowBatch
from policy import Actor, Critic, evaluate_physics, load_actor, observation, qualifies, ranking


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    torch.set_num_threads(config["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    train = WindowBatch(args.train, "train")
    if train.horizon != 1:
        raise ValueError("behavior cloning requires the declared point-batch export")
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    body = dict(q_indices=runtime.q_indices.tolist(), v_state_indices=(runtime.v_indices + runtime.model.nq).tolist(), nq=runtime.model.nq)
    obs, goal, target = train.observation[:, 0], train.goal[:, 0], train.action[:, 0]
    if not torch.allclose(observation(train.state[:64, 0], obs[:64, -runtime.model.nu:], body), obs[:64], atol=1e-5):
        raise ValueError("training proprioception differs from physical evaluator")
    stats = dict(obs_mean=obs.mean(0), obs_scale=obs.std(0, unbiased=False).clamp_min(.1),
        goal_mean=goal.mean(0), goal_scale=goal.std(0, unbiased=False).clamp_min(.1),
        lower=torch.tensor(np.where(runtime.model.actuator_ctrllimited, runtime.model.actuator_ctrlrange[:, 0], -np.inf), dtype=torch.float32),
        upper=torch.tensor(np.where(runtime.model.actuator_ctrllimited, runtime.model.actuator_ctrlrange[:, 1], np.inf), dtype=torch.float32))
    early = torch.where(train.start_time_s < 2)[0]
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    runs = []
    for seed in config["seeds"]:
        torch.manual_seed(seed)
        actor = Actor(stats, config, body)
        # Preserved for a later physics-return calibration; cloning trains no value function.
        critic = Critic(train.state[:, 0].mean(0), train.state[:, 0].std(0, unbiased=False).clamp_min(.1),
                        len(train.context[0]), config, len(goal[0]))
        torch.nn.init.zeros_(critic.net[-1].weight)
        torch.nn.init.zeros_(critic.net[-1].bias)
        initial = copy.deepcopy(actor.state_dict())
        optimizer = torch.optim.Adam(actor.parameters(), lr=config["actor_learning_rate"])
        validation, _ = evaluate_physics(runtime, experiment, config["validation_seeds"], actor, "validation")
        selected, best_actor = 0, copy.deepcopy(actor.state_dict())
        history = [dict(update=0, validation=validation["summary"])]
        start = time.perf_counter()
        for update in range(1, config["updates"] + 1):
            half = config["batch_size"] // 2
            indices = torch.cat((torch.randint(len(obs), (half,)), early[torch.randint(len(early), (config["batch_size"] - half,))]))
            loss = ((actor(obs[indices], goal[indices]) - target[indices]) / config["action_delta_rad"]).square().mean()
            if not torch.isfinite(loss):
                raise ValueError("nonfinite cloning loss")
            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(actor.parameters(), 1)
            optimizer.step()
            if update in config["evaluation_updates"]:
                current, _ = evaluate_physics(runtime, experiment, config["validation_seeds"], actor, "validation")
                history.append(dict(update=update, action_loss=float(loss.detach()), validation=current["summary"]))
                if ranking(current) > ranking(validation):
                    validation, selected, best_actor = current, update, copy.deepcopy(actor.state_dict())
                print(json.dumps(dict(seed=seed, **history[-1])), flush=True)
        elapsed = time.perf_counter() - start
        common = dict(format="moonrobo.g1-actor.v1", critic=critic.state_dict(), config=config, body=body,
            model_ref=train.layout["model_ref"], seed=seed, training_batch_sha256=train.digest,
            training_kind="behavior-cloning", critic_status="untrained-zero-output")
        latest_name, name = f"latest-actor-seed-{seed}.pt", f"actor-seed-{seed}.pt"
        torch.save(dict(**common, actor=actor.state_dict(), selected_update=config["updates"]), output / latest_name)
        actor.load_state_dict(best_actor)
        torch.save(dict(**common, actor=best_actor, selected_update=selected), output / name)
        restored, _ = load_actor(output / name)
        if not torch.equal(restored(obs[:8], goal[:8]), actor(obs[:8], goal[:8])):
            raise ValueError("cloned actor reload differs")
        with torch.no_grad():
            action_rmse = float((actor(obs, goal) - target).square().mean().sqrt())
        baseline, _ = evaluate_physics(runtime, experiment, config["test_seeds"])
        candidate, episodes = evaluate_physics(runtime, experiment, config["test_seeds"], restored)
        (output / f"physics-seed-{seed}.json").write_text(json.dumps(dict(baseline=baseline, candidate=candidate), indent=2, allow_nan=False))
        (output / f"candidate-data-seed-{seed}.json").write_text(json.dumps(runtime.dataset(episodes, experiment["source_revision"]), allow_nan=False))
        runs.append(dict(seed=seed, selected_update=selected, training_seconds=elapsed, training_action_rmse_rad=action_rmse,
            actor_changed=any(not torch.equal(v, actor.state_dict()[k]) for k, v in initial.items()),
            checkpoint=name, latest_checkpoint=latest_name, reload_matches=True,
            baseline=baseline["summary"], candidate=candidate["summary"], qualifies=qualifies(candidate, config), history=history))
    report = dict(format="moonrobo.g1-bc-fit.v1", kind="behavior-cloning-initialization", config=config,
        training_batch_sha256=train.digest, provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        critic_status="untrained-zero-output", checkpoint_selection="validation-physics-only", runs=runs,
        experiment=experiment, any_qualified=any(r["qualifies"] for r in runs), physical_execution_allowed=False)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(output=str(output), runs=runs)), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["train", "scene", "config", "experiment", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
