"""Cross complete control-tape directions with open-loop and feedback execution."""
import argparse
import copy
import json
from pathlib import Path
import time

import mujoco
import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from dynamics import load_model
from policy import observation
from reference_action_response import digest, physics_branch, returns, reward_targets
from reference_actor import load_reference_actor, load_references
from reference_learning import BODY, state_digest
from reference_task import ReferenceSchedule, observer_advance, observer_memory, reference_reward


def controller_memory(inputs):
    history = torch.from_numpy(inputs["history"]).clone()
    features = torch.from_numpy(inputs["actual_features"]).clone()
    return history, features, observer_memory(history[:, -1], features)


def policy_action(actor, schedule, inputs, history, features, step):
    clips, origins = torch.tensor([int(inputs["clip"])]), torch.tensor([0])
    phases = torch.tensor([int(inputs["phase"])+step])
    current, future, valid = schedule.command(clips, phases, actor.future_length)
    planned = torch.from_numpy(inputs["reference_features"]) if step == 0 else schedule.features(clips, origins, phases)
    return actor(history, current, future, valid, features, planned)


def control_direction(gradient, baseline_controls, limits, amplitude):
    margin = gradient.numel()**.5*amplitude
    interior = np.ones(gradient.shape, dtype=bool)
    for controls in baseline_controls:
        interior &= (controls > limits[None, :, 0]+margin) & (controls < limits[None, :, 1]-margin)
    feasible = gradient*torch.from_numpy(interior)
    scale = float(feasible.square().mean().sqrt())
    if not torch.isfinite(feasible).all() or scale <= 1e-12:
        raise ValueError("invalid feasible control-tape gradient")
    return (feasible/scale).detach().numpy(), int(interior.sum())


def model_rollout(model, actor, geometry, schedule, inputs, targets, perturbation, mode, limits, gamma):
    state = torch.from_numpy(inputs["state"])[None]
    context = torch.from_numpy(inputs["context"])[None]
    history, features, memory = controller_memory(inputs)
    previous = torch.from_numpy(inputs["observation"][-29:])[None] if mode == "open-tape" else history[:, -1, -29:]
    lower, upper = torch.from_numpy(limits[:, 0]), torch.from_numpy(limits[:, 1])
    alive = torch.ones(1, dtype=torch.float64)
    result = torch.zeros(1, dtype=torch.float64)
    controls, active = [], 0
    for t in range(len(perturbation)):
        base = torch.from_numpy(inputs["actions"][t])[None] if mode == "open-tape" else policy_action(actor, schedule, inputs, history, features, t)
        action = (base+perturbation[t:t+1]).maximum(lower).minimum(upper)
        predicted = model(state, action, context)
        reward, fallen, error = reference_reward(geometry, predicted, action, previous,
            targets[0][t:t+1], targets[1][t:t+1], targets[2][t:t+1])
        result = result+gamma**t*alive*reward
        active += int(alive.detach().sum())
        state = torch.where(alive[:, None] > 0, predicted, state)
        if mode == "feedback":
            obs = observation(state, action, BODY)
            next_features, next_memory = observer_advance(geometry, obs, memory, schedule.dt, error=error)
            features = torch.where(alive[:, None] > 0, next_features, features)
            memory = torch.where(alive[:, None] > 0, next_memory, memory)
            history = torch.where(alive[:, None, None] > 0, torch.cat((history[:, 1:], obs[:, None]), 1), history)
        controls.append(action[0])
        previous = action
        alive = alive*(~fallen).double()
    return result[0], torch.stack(controls), active


@torch.no_grad()
def feedback_physics(runtime, actor, geometry, schedule, inputs, targets, perturbation):
    m, d = runtime.model, runtime.data
    mujoco.mj_resetData(m, d)
    m.opt.disableflags = runtime.base_disable
    m.geom_friction[:, 0] = inputs["context"][0]
    m.pair_friction[:, :2] = inputs["context"][0]
    mujoco.mj_setState(m, d, inputs["integration"], mujoco.mjtState.mjSTATE_INTEGRATION)
    history, features, memory = controller_memory(inputs)
    previous = history[0, -1, -29:].numpy().copy()
    arrays = {k: [] for k in ["state", "observation", "applied_action", "next_state", "reward", "terminated", "truncated"]}
    for t in range(len(perturbation)):
        base = policy_action(actor, schedule, inputs, history, features, t)[0].numpy()
        action = runtime.clip_control(base+perturbation[t])
        obs = inputs["observation"].copy() if t == 0 else np.asarray(runtime.observation(previous))
        obs[-29:] = previous
        before = np.asarray(runtime.state())
        d.ctrl[:] = action
        mujoco.mj_step(m, d, nstep=runtime.substeps)
        mujoco.mj_forward(m, d)
        after = np.asarray(runtime.state())
        reward, fallen, error = reference_reward(geometry, torch.from_numpy(after)[None], torch.from_numpy(action)[None],
            torch.from_numpy(previous)[None], targets[0][t:t+1], targets[1][t:t+1], targets[2][t:t+1])
        next_obs = observation(torch.from_numpy(after)[None], torch.from_numpy(action)[None], BODY)
        features, memory = observer_advance(geometry, next_obs, memory, schedule.dt, error=error)
        history = torch.cat((history[:, 1:], next_obs[:, None]), 1)
        fall = bool(fallen[0])
        row = dict(state=before, observation=obs, applied_action=action.copy(), next_state=after,
            reward=float(reward[0]), terminated=fall, truncated=not fall and t == len(perturbation)-1)
        for key in arrays: arrays[key].append(row[key])
        previous = action
        if fall: break
    return {k: np.asarray(v) for k, v in arrays.items()}


def double_schedule(references, geometry):
    schedule = ReferenceSchedule(references, copy.deepcopy(geometry).float(), [0])
    for name in ["goals", "positions", "quaternions"]: setattr(schedule, name, getattr(schedule, name).double())
    schedule.reference_features = {key: value.double() for key, value in schedule.reference_features.items()}
    return schedule


def run(args):
    started = time.perf_counter()
    source, output = Path(args.source).resolve(), Path(args.output).resolve()
    config = json.loads((output/"config.json").read_bytes())
    if digest(source/"report.json") != config["source_report_sha256"]: raise ValueError("action-response source changed")
    prior = json.loads((source/"report.json").read_bytes())
    old_source = Path(prior["source_study"])
    if digest(old_source/"report.json") != prior["source_report_sha256"]: raise ValueError("physical tape source changed")
    old_report = json.loads((old_source/"report.json").read_bytes())
    old_records = {r["episode_id"]: r for r in old_report["physical_records"]}
    prior_records = {r["episode_id"]: r for r in prior["physical_records"]}
    torch.set_num_threads(2); torch.use_deterministic_algorithms(True)
    manifest, references = load_references(prior["references"])
    runtime = PhysicsRuntime(args.scene)
    limits = runtime.model.actuator_ctrlrange.copy()
    for name in ["physics", "inputs", "directions"]: (output/name).mkdir()
    records, conditions = [], []
    for condition in prior["conditions"]:
        model_path, actor_path = Path(condition["model_checkpoint"]), Path(condition["geometry_checkpoint"])
        if digest(model_path) != condition["model_sha256"] or digest(actor_path) != condition["source_actor_sha256"]:
            raise ValueError("frozen actor/model changed")
        model, _ = load_model(model_path); model.double()
        actor, geometry, _ = load_reference_actor(actor_path); actor.double(); geometry.double()
        for module in [model, actor]:
            for parameter in module.parameters(): parameter.requires_grad_(False)
        frozen = [state_digest(model), state_digest(actor)]
        schedule = double_schedule(references, geometry)
        source_snapshot = source/condition["snapshot"]
        if digest(source_snapshot) != condition["snapshot_sha256"]: raise ValueError("solver snapshot changed")
        with np.load(source_snapshot, allow_pickle=False) as archive: inputs = dict(archive)
        original = old_records[condition["source_episode_id"]]
        tape_path = old_source/original["file"]
        if digest(tape_path) != original["sha256"]: raise ValueError("controller history source changed")
        with np.load(tape_path, allow_pickle=False) as archive:
            offset = condition["offset"]
            ids = np.maximum(offset-np.arange(actor.history_length-1, -1, -1), 0)
            inputs.update(history=archive["observation"][ids][None].astype(np.float64),
                actual_features=archive["actual_features"][offset:offset+1].astype(np.float64),
                reference_features=archive["reference_features"][offset:offset+1].astype(np.float64),
                clip=np.asarray(condition["clip_index"]), phase=np.asarray(offset))
        label = Path(condition["snapshot"]).stem
        input_path = output/"inputs"/(label+".npz"); np.savez_compressed(input_path, **inputs)
        _, reference = references[condition["clip_index"]]
        targets = reward_targets(reference, offset, config["horizon"])
        zero = torch.zeros_like(torch.from_numpy(inputs["actions"]))
        feedback_baseline = feedback_physics(runtime, actor, geometry, schedule, inputs, targets, zero.numpy())
        metadata = {key: condition[key] for key in ["method", "seed", "clip_index", "offset", "source_family", "source_episode_id", "source_actor_sha256", "geometry_checkpoint", "context"]}
        metadata.update(inputs=str(input_path.relative_to(output)), inputs_sha256=digest(input_path))
        baselines = {}
        for mode in config["execution_modes"]:
            if mode == "open-tape":
                record = copy.deepcopy(prior_records[condition["baseline"]])
                record["file"] = str(source/record["file"])
                record.update(**metadata, execution_mode=mode, reused_baseline=True,
                    snapshot=str(source/record["snapshot"]))
                baselines[mode] = record
            else:
                path = output/"physics"/(label+"-feedback-baseline.npz")
                np.savez_compressed(path, **feedback_baseline)
                baselines[mode] = dict(**metadata, episode_id=label+"-feedback-baseline", file=str(path.relative_to(output)),
                    sha256=digest(path), steps=len(feedback_baseline["state"]), role="feedback-baseline",
                    execution_mode=mode, amplitude=0., reused_baseline=False,
                    returns=returns(feedback_baseline, [8, 32], config["gamma"]))
            records.append(baselines[mode])
        objectives, gradients, baseline_controls, active = {}, {}, {}, {}
        for mode in config["execution_modes"]:
            perturbation = zero.clone().requires_grad_(True)
            value, controls, steps = model_rollout(model, actor, geometry, schedule, inputs, targets, perturbation, mode, limits, config["gamma"])
            gradients[mode], = torch.autograd.grad(value, perturbation)
            objectives[mode], baseline_controls[mode], active[mode] = float(value.detach()), controls.detach().numpy(), steps
        result = dict(**metadata, model_checkpoint=str(model_path), model_sha256=digest(model_path),
            baselines={mode: value["episode_id"] for mode, value in baselines.items()}, directions=[])
        for direction_source in config["direction_sources"]:
            direction, interior = control_direction(gradients[direction_source],
                [inputs["actions"], baseline_controls["feedback"], feedback_baseline["applied_action"]], limits,
                max(config["action_rms_amplitudes_rad"]))
            direction_path = output/"directions"/(label+"-"+direction_source+".npz")
            np.savez_compressed(direction_path, direction=direction, gradient=gradients[direction_source].numpy())
            for mode in config["execution_modes"]:
                def predicted(amount):
                    with torch.no_grad():
                        return float(model_rollout(model, actor, geometry, schedule, inputs, targets,
                            torch.from_numpy(amount*direction), mode, limits, config["gamma"])[0])
                analytic = float((gradients[mode]*torch.from_numpy(direction)).sum())
                checks = []
                for epsilon in config["model_finite_difference_epsilons_rad"]:
                    numeric = (predicted(epsilon)-predicted(-epsilon))/(2*epsilon)
                    error = abs(analytic-numeric)
                    checks.append(dict(epsilon_rad=epsilon, numeric_directional=numeric, absolute_error=error,
                        passed=bool(error <= 1e-5+1e-3*abs(numeric))))
                outcomes = []
                for amplitude in config["action_rms_amplitudes_rad"]:
                    pair = dict(amplitude_rad=amplitude)
                    for sign, name in [(-1, "minus"), (1, "plus")]:
                        perturbation = sign*amplitude*direction
                        if mode == "open-tape":
                            controls = np.clip(inputs["actions"]+perturbation, limits[None, :, 0], limits[None, :, 1])
                            arrays = physics_branch(runtime, inputs, controls, targets, geometry)
                        else:
                            arrays = feedback_physics(runtime, actor, geometry, schedule, inputs, targets, perturbation)
                        ident = label+f"-direction-{direction_source}-execute-{mode}-amp{amplitude}-sign{sign}"
                        path = output/"physics"/(ident+".npz"); np.savez_compressed(path, **arrays)
                        record = dict(**metadata, episode_id=ident, file=str(path.relative_to(output)), sha256=digest(path),
                            steps=len(arrays["state"]), role="counterfactual", reused_baseline=False,
                            direction_source=direction_source, execution_mode=mode, amplitude=sign*amplitude,
                            direction_file=str(direction_path.relative_to(output)), direction_sha256=digest(direction_path),
                            returns=returns(arrays, [8, 32], config["gamma"]))
                        records.append(record)
                        pair[name] = dict(episode_id=ident, model_return=predicted(sign*amplitude),
                            physics_return=record["returns"]["32"])
                    pair["model_directional"] = (pair["plus"]["model_return"]-pair["minus"]["model_return"])/(2*amplitude)
                    pair["physics_directional"] = (pair["plus"]["physics_return"]-pair["minus"]["physics_return"])/(2*amplitude)
                    pair["positive_physics_gain"] = pair["plus"]["physics_return"]-baselines[mode]["returns"]["32"]
                    outcomes.append(pair)
                result["directions"].append(dict(direction_source=direction_source, execution_mode=mode,
                    interior_action_coordinates=interior, analytic_directional=analytic,
                    finite_difference_error=checks[0]["absolute_error"], model_finite_difference_checks=checks,
                    smallest_epsilon_verified=checks[-1]["passed"], model_baseline_return=objectives[mode],
                    model_active_steps=active[mode], physics_baseline_return=baselines[mode]["returns"]["32"], outcomes=outcomes))
        if frozen != [state_digest(model), state_digest(actor)]: raise ValueError("feedback diagnostic changed learned tensors")
        conditions.append(result)
        print(json.dumps(dict(event="feedback-response-condition", completed=len(conditions), method=condition["method"],
            seed=condition["seed"], clip=condition["clip_index"], offset=offset)), flush=True)
    report = dict(format="moonrobo.g1-reference-feedback-response.v1", config=config, source_study=str(source),
        source_report_sha256=digest(source/"report.json"), references=prior["references"], reference_manifest_sha256=prior["reference_manifest_sha256"],
        physical_records=records, conditions=conditions, provider_sha256=digest(__file__), provider_seconds=time.perf_counter()-started,
        physical_execution_allowed=False, release_qualified=False, scope=config["scope"])
    (output/"report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["source", "scene", "output"]: parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
