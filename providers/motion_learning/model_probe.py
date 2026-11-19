"""Compare learned action sensitivities with restored MuJoCo integration states."""

import argparse
import hashlib
import json
from pathlib import Path

import mujoco
import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from dynamics import load_model, imagine
from policy import step_reward, load_actor, gravity


def score(states, actions, previous, goals, q_indices, config):
    survival = torch.ones((), dtype=states.dtype)
    total = torch.zeros((), dtype=states.dtype)
    for t in range(len(actions)):
        reward, continuation = step_reward(states[t], actions[t], previous, goals[t],
                                             q_indices, config["target_height_m"])
        total = total + config["gamma"] ** t * survival * reward
        survival = survival * continuation
        previous = actions[t]
    return total


def physical_rollout(runtime, snapshot, actions, xy_shift=None):
    model = runtime.model
    data = mujoco.MjData(model)
    mujoco.mj_setState(model, data, snapshot, mujoco.mjtState.mjSTATE_INTEGRATION)
    if xy_shift is not None:
        data.qpos[:2] += xy_shift
    states = []
    for action in actions:
        data.ctrl[:] = runtime.clip_control(action)
        mujoco.mj_step(model, data, nstep=runtime.substeps)
        mujoco.mj_forward(model, data)
        states.append(np.concatenate((data.qpos, data.qvel, data.act)))
    return np.array(states)


def summarize(records, horizon, time_group, config):
    subset = [r for r in records if r["horizon"] == horizon and
              (time_group == "all" or (r["start_time_s"] >= 2.0) == (time_group == "after-two-seconds"))]
    summaries = []
    for label in ["initial", "corrected"]:
        selected = [next(m for m in r["models"] if m["model"] == label) for r in subset]
        pairs = [(d[label + "_derivative"], d["physics_derivatives"][0]) for r in subset for d in r["directions"]]
        ascents = [m["ascent_physics"] for m in selected if m["ascent_physics"]]
        translations = [check for m in selected for check in m.get("translation_checks", [])]
        summaries.append(dict(horizon=horizon, model=label, time_group=time_group,
          snapshots=len(subset), directions=len(pairs), ascent_snapshots=len(ascents),
          translation_checks=len(translations),
          maximum_physical_equivariance_error=max((c["physical_equivariance_error"] for c in translations), default=None),
          mean_normalized_model_equivariance_mse=float(np.mean([c["normalized_model_equivariance_mse"] for c in translations])) if translations else None,
          mean_normalized_mse=float(np.mean([m["normalized_mse"] for m in selected])) if selected else None,
          mean_return_absolute_error=float(np.mean([abs(m["predicted_return"] - r["physical_return"]) for m, r in zip(selected, subset)])) if selected else None,
          sign_agreement=sum(a * b > 0 for a, b in pairs) / len(pairs) if pairs else None,
          sign_agreement_by_epsilon=[float(np.mean([d[label + "_derivative"] * d["physics_derivatives"][i] > 0 for r in subset for d in r["directions"]])) if pairs else None for i in range(len(config["epsilons_rad"]))],
          ascent_improves_fraction_by_epsilon=[float(np.mean([a[i]["plus_return_change"] > 0 for a in ascents])) if ascents else None for i in range(len(config["epsilons_rad"]))],
          mean_ascent_return_change_by_epsilon=[float(np.mean([a[i]["plus_return_change"] for a in ascents])) if ascents else None for i in range(len(config["epsilons_rad"]))],
          fd_sign_agreement_between_scales=float(np.mean([d["physics_derivatives"][0] * d["physics_derivatives"][1] > 0 for r in subset for d in r["directions"]])) if pairs else None,
          physical_fd_scale_disagreement=float(np.mean([abs(d["physics_derivatives"][0] - d["physics_derivatives"][1]) for r in subset for d in r["directions"]])) if pairs else None))
    return summaries


def run(args):
    config = json.loads(Path(args.config).read_text())
    experiment = json.loads(Path(args.experiment).read_text())
    torch.set_num_threads(config["cpu_threads"])
    checkpoints = [args.initial, args.corrected]
    models = []
    for path in checkpoints:
        model, _ = load_model(path)
        model.double()
        for parameter in model.parameters():
            parameter.requires_grad_(False)
        models.append(model)
    common_scale = models[0].state_scale
    runtime = PhysicsRuntime(args.scene, experiment["control_dt_s"])
    actor = load_actor(args.actor)[0] if args.actor else None
    def predict(obs, goal):
        with torch.no_grad():
            return actor(torch.tensor(obs, dtype=torch.float32)[None],
                         torch.tensor(goal, dtype=torch.float32)[None])[0].numpy()
    rng = np.random.default_rng(config["seed"])
    records, restore_errors = [], []
    omitted = []
    for case, seed in [(case, seed) for case in experiment["cases"]
                       for seed in config.get("seeds", [config.get("seed", 0)])]:
        snapshots, controls, goals = {}, [], []
        def capture(rt, i, action, goal):
            controls.append(action)
            goals.append(goal)
            if i in config["snapshot_steps"]:
                integration = np.empty(mujoco.mj_stateSize(rt.model, mujoco.mjtState.mjSTATE_INTEGRATION))
                mujoco.mj_getState(rt.model, rt.data, integration, mujoco.mjtState.mjSTATE_INTEGRATION)
                # Collector's previous action is the preceding applied control;
                # at reset it initializes to the keyframe's nominal target.
                previous = controls[i - 1] if i else rt.clip_control(rt.data.qpos[rt.q_indices])
                snapshots[i] = (integration, np.array(rt.state()), previous.copy())
        episode, _ = runtime.rollout(case, seed, "policy" if actor else "position", experiment["duration_s"],
                                     experiment["fall_height_m"], experiment["fall_upright_z"],
                                     policy=predict if actor else None, trace_callback=capture)
        context = torch.tensor([case["friction"], 1.0], dtype=torch.float64)
        for start in config["snapshot_steps"]:
            for horizon in config["horizons"]:
                if start not in snapshots or start + horizon > len(controls):
                    omitted.append(dict(case=case["id"], seed=seed, start_step=start, horizon=horizon,
                                        episode_steps=len(controls), reason="episode-ended-before-complete-window"))
        for start, (snapshot, initial, previous_array) in snapshots.items():
            for horizon in config["horizons"]:
                if start + horizon > len(controls):
                    continue
                action_array = np.array(controls[start:start + horizon])
                truth_array = physical_rollout(runtime, snapshot, action_array)
                recorded = np.array([s["next_state"] for s in episode["steps"][start:start + horizon]])
                restore_error = float(np.max(np.abs(truth_array - recorded)))
                restore_errors.append(restore_error)
                if restore_error > 1e-8:
                    raise ValueError("integration-state replay differs from collected physics")
                truth = torch.tensor(truth_array, dtype=torch.float64)
                goals_tensor = torch.tensor(np.array(goals[start:start + horizon]), dtype=torch.float64)
                previous = torch.tensor(previous_array, dtype=torch.float64)
                actions = torch.tensor(action_array, dtype=torch.float64)
                actual_return = float(score(truth, actions, previous, goals_tensor, runtime.q_indices.tolist(), config))
                model_results = []
                for label, model in zip(["initial", "corrected"], models):
                    variable_actions = actions.clone().requires_grad_(True)
                    lower = torch.tensor(np.where(runtime.model.actuator_ctrllimited, runtime.model.actuator_ctrlrange[:, 0], -np.inf))
                    upper = torch.tensor(np.where(runtime.model.actuator_ctrllimited, runtime.model.actuator_ctrlrange[:, 1], np.inf))
                    applied = torch.maximum(torch.minimum(variable_actions, upper), lower)
                    prediction = imagine(model, torch.tensor(initial, dtype=torch.float64)[None],
                                         applied[None], context[None])[0]
                    predicted_return = score(prediction, applied, previous, goals_tensor, runtime.q_indices.tolist(), config)
                    gradient, = torch.autograd.grad(predicted_return, variable_actions)
                    translations = []
                    for xy_shift in config.get("translation_shifts_m", []):
                        offset = torch.zeros_like(torch.tensor(initial))
                        offset[:2] = torch.tensor(xy_shift)
                        shifted_truth = torch.tensor(physical_rollout(runtime, snapshot, action_array, xy_shift))
                        with torch.no_grad():
                            shifted_prediction = imagine(model, (torch.tensor(initial) + offset)[None],
                                                         actions[None], context[None])[0]
                        translations.append(dict(xy_shift_m=xy_shift,
                            physical_equivariance_error=float((shifted_truth - truth - offset).abs().max()),
                            normalized_model_equivariance_mse=float(((shifted_prediction - prediction.detach() - offset) / common_scale).square().mean())))
                    ascent = []
                    norm = float(gradient.norm())
                    if config.get("model_ascent_probe", False) and norm > 0:
                        direction = gradient.detach().numpy() / norm
                        for epsilon in config["epsilons_rad"]:
                            returns = []
                            for sign in [1, -1]:
                                perturbed = np.array([runtime.clip_control(a) for a in action_array + sign * epsilon * direction])
                                physical = torch.tensor(physical_rollout(runtime, snapshot, perturbed), dtype=torch.float64)
                                returns.append(float(score(physical, torch.tensor(perturbed), previous,
                                                           goals_tensor, runtime.q_indices.tolist(), config)))
                            ascent.append(dict(epsilon_rad=epsilon, plus_return_change=returns[0] - actual_return,
                                               minus_return_change=returns[1] - actual_return,
                                               physics_derivative=(returns[0] - returns[1]) / (2 * epsilon)))
                    model_results.append(dict(model=label, normalized_mse=float(((prediction.detach() - truth) / common_scale).square().mean()),
                                              predicted_return=float(predicted_return.detach()), gradient=gradient.detach().numpy(),
                                              action_gradient_norm=norm, ascent_physics=ascent,
                                              translation_checks=translations,
                                              final_root_height_m=float(prediction[-1, 2].detach()),
                                              final_upright_z=float(-gravity(prediction[-1])[2].detach())))
                directions = []
                for _ in range(config["directions"]):
                    direction = rng.normal(size=action_array.shape)
                    direction /= np.linalg.norm(direction)
                    numerical = []
                    for epsilon in config["epsilons_rad"]:
                        perturbed_scores = []
                        for sign in [1, -1]:
                            perturbed = np.array([runtime.clip_control(a) for a in action_array + sign * epsilon * direction])
                            physical = torch.tensor(physical_rollout(runtime, snapshot, perturbed), dtype=torch.float64)
                            perturbed_scores.append(float(score(physical, torch.tensor(perturbed), previous,
                                                               goals_tensor, runtime.q_indices.tolist(), config)))
                        numerical.append((perturbed_scores[0] - perturbed_scores[1]) / (2 * epsilon))
                    directions.append(dict(physics_derivatives=numerical,
                                           initial_derivative=float(np.sum(model_results[0]["gradient"] * direction)),
                                           corrected_derivative=float(np.sum(model_results[1]["gradient"] * direction))))
                for result in model_results:
                    del result["gradient"]
                records.append(dict(case=case["id"], seed=seed, start_step=start, start_time_s=start * runtime.dt,
                                    horizon=horizon, source_split=case["split"], episode_steps=len(controls),
                                    steps_until_episode_end=len(controls) - start,
                                    final_physics_root_height_m=float(truth[-1, 2]),
                                    final_physics_upright_z=float(-gravity(truth[-1])[2]),
                                    physical_return=actual_return, persistence_mse=float(((torch.tensor(initial)[None] - truth) / common_scale).square().mean()),
                                    models=model_results, directions=directions))
    summaries = []
    time_groups = ["all"] + (["before-two-seconds", "after-two-seconds"] if config.get("stratify_time", False) else [])
    for horizon, time_group in [(h, group) for h in config["horizons"] for group in time_groups]:
        summaries.extend(summarize(records, horizon, time_group, config))
    report = dict(format="moonrobo.model-physics-probe.v1", config=config, experiment=experiment,
                  controller="policy" if actor else "position", actor_sha256=hashlib.sha256(Path(args.actor).read_bytes()).hexdigest() if args.actor else None,
                  metric_scale="initial-model training state scale", maximum_restore_error=max(restore_errors),
                  mujoco_version=mujoco.__version__, torch_version=str(torch.__version__),
                  checkpoints={str(p): hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in checkpoints},
                  provider_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  physical_execution_allowed=False, summaries=summaries, records=records, omitted=omitted)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, allow_nan=False))
    print(json.dumps(dict(report=str(output), summaries=summaries)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["initial", "corrected", "scene", "config", "experiment", "output"]:
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--actor")
    run(parser.parse_args())
