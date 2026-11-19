"""Compare learned critic values with recorded physics returns and XY shifts."""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from policy import Critic, load_actor, step_reward


def recorded_returns(episode, body, config):
    steps = episode["steps"]
    states = torch.tensor([s["next_state"] for s in steps], dtype=torch.float32)
    actions = torch.tensor([s["applied_action"] for s in steps], dtype=torch.float32)
    previous = torch.tensor([s["observation"][-len(body["q_indices"]):] for s in steps], dtype=torch.float32)
    goals = torch.tensor([s["goal"] for s in steps], dtype=torch.float32)
    rewards, continuation = step_reward(states, actions, previous, goals, body["q_indices"], config["target_height_m"])
    hard, soft = torch.zeros(len(steps)), torch.zeros(len(steps))
    h, s = 0.0, 0.0
    for i in reversed(range(len(steps))):
        h = float(rewards[i]) + config["gamma"] * (not steps[i]["terminated"]) * h
        s = float(rewards[i]) + config["gamma"] * float(continuation[i]) * s
        hard[i], soft[i] = h, s
    return hard, soft


def load_critic(path):
    metadata = torch.load(path, weights_only=True)
    weights = metadata["critic"]
    critic = Critic(weights["mean"], weights["scale"], 2, metadata["config"], len(metadata["actor"]["goal_mean"]))
    critic.load_state_dict(weights)
    return critic.eval(), metadata


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    torch.set_num_threads(config["cpu_threads"])
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    records, digests = [], {}
    for policy_seed in config["policy_seeds"]:
        selected_path = Path(args.policies) / f"actor-seed-{policy_seed}.pt"
        actor, selected_meta = load_actor(selected_path)
        critics = []
        for label, path in [("selected", selected_path),
                            ("latest", Path(args.policies) / f"latest-actor-seed-{policy_seed}.pt")]:
            critic, meta = load_critic(path)
            critics.append((label, critic))
            digests[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
        def predict(obs, goal):
            with torch.no_grad():
                return actor(torch.tensor(obs, dtype=torch.float32)[None],
                             torch.tensor(goal, dtype=torch.float32)[None])[0].numpy()
        for case in experiment["cases"]:
            for seed in config["reset_seeds"]:
                episode, trial = runtime.rollout(case, seed, "policy", experiment["duration_s"],
                  experiment["fall_height_m"], experiment["fall_upright_z"], policy=predict)
                hard, soft = recorded_returns(episode, actor.body, selected_meta["config"])
                for start in config["snapshot_steps"]:
                    if start >= len(episode["steps"]):
                        continue
                    step = episode["steps"][start]
                    state = torch.tensor(step["state"], dtype=torch.float32)[None].requires_grad_(True)
                    goal = torch.tensor(step["goal"], dtype=torch.float32)[None]
                    context = torch.tensor(episode["context"], dtype=torch.float32)[None]
                    for label, critic in critics:
                        value = critic(state, goal, context)
                        gradient, = torch.autograd.grad(value.sum(), state)
                        shifted = []
                        for xy in config["translation_shifts_m"]:
                            offset = torch.zeros_like(state)
                            offset[:, :2] = torch.tensor(xy)
                            with torch.no_grad():
                                shifted.append(float(critic(state + offset, goal, context) - value.detach()))
                        records.append(dict(policy_seed=policy_seed, critic=label, case=case["id"],
                          reset_seed=seed, start_step=start, time_s=start * runtime.dt,
                          episode_terminated=trial["failed"], value=float(value.detach()),
                          hard_physics_return=float(hard[start]), soft_physics_return=float(soft[start]),
                          xy_gradient=gradient[0, :2].tolist(), shifted_value_changes=shifted,
                          near_bound=abs(float(value.detach())) >= .99 * critic.value_bound))
    summaries = []
    for seed in config["policy_seeds"]:
        for label in ["selected", "latest"]:
            rows = [r for r in records if r["policy_seed"] == seed and r["critic"] == label]
            uncensored = [r for r in rows if r["episode_terminated"]]
            shifts = [abs(v) for r in rows for v in r["shifted_value_changes"]]
            summaries.append(dict(policy_seed=seed, critic=label, states=len(rows), uncensored_states=len(uncensored),
              mean_value=float(np.mean([r["value"] for r in rows])),
              mean_soft_physics_return=float(np.mean([r["soft_physics_return"] for r in uncensored])) if uncensored else None,
              mean_absolute_soft_return_error=float(np.mean([abs(r["value"] - r["soft_physics_return"]) for r in uncensored])) if uncensored else None,
              mean_absolute_translation_change=float(np.mean(shifts)), maximum_absolute_translation_change=max(shifts),
              near_bound_fraction=float(np.mean([r["near_bound"] for r in rows]))))
    report = dict(format="moonrobo.g1-critic-probe.v1", config=config, experiment=experiment,
      checkpoint_sha256=digests, summaries=summaries, records=records, physical_execution_allowed=False,
      scope="Both critics scored on the selected actor's trajectories; latest critic is not an on-policy value test for that actor. Soft returns use analytic continuation with zero tail only after true falls; censored episodes excluded from return-error summaries.")
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False))
    (output / "summary.json").write_text(json.dumps({k: v for k, v in report.items() if k != "records"}, indent=2, allow_nan=False))
    print(json.dumps(summaries))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["policies", "scene", "config", "experiment", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
