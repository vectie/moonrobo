"""Measure frozen world-model action directions in restored CPU physics."""
import argparse
import hashlib
import json
from pathlib import Path
import time

import mujoco
import numpy as np
import torch

from cpu_physics import PhysicsRuntime
from dynamics import load_model
from policy import observation
from reference_actor import load_reference_actor, load_references
from reference_learning import BODY, state_digest
from reference_task import reference_reward


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def first_action_tape(actions, direction, amplitude, limits):
    result = np.array(actions, dtype=np.float64, copy=True)
    result[0] = np.clip(result[0]+amplitude*direction, limits[:, 0], limits[:, 1])
    return result


def feasible_direction(gradient, action, limits, amplitude):
    margin = len(action)**.5*amplitude
    interior = (action > limits[:, 0]+margin) & (action < limits[:, 1]-margin)
    feasible = gradient*torch.from_numpy(interior)
    scale = float(feasible.square().mean().sqrt())
    if not torch.isfinite(feasible).all() or scale <= 1e-12:
        raise ValueError("nonfinite or zero interior action-response gradient")
    return (feasible/scale).detach().numpy(), scale, int(interior.sum())


def reward_targets(reference, phase, count):
    target = slice(phase+1, phase+count+1)
    # Preserve the learner's target precision while differentiating in float64.
    return [torch.from_numpy(np.asarray(a[target], dtype=np.float32).astype(np.float64)) for a in
        [reference.arrays["body_position"], reference.arrays["state"][:, 3:7], reference.goals[:, :29]]]


def tape_objective(model, geometry, snapshot, targets, horizon, first, gamma):
    state = torch.from_numpy(snapshot["state"])[None]
    controls = torch.from_numpy(snapshot["actions"])
    previous = torch.from_numpy(snapshot["observation"][-29:])[None]
    context = torch.from_numpy(snapshot["context"])[None]
    alive, result = torch.ones(1, dtype=torch.float64), torch.zeros(1, dtype=torch.float64)
    for t in range(horizon):
        action = first[None] if t == 0 else controls[t:t+1]
        state = model(state, action, context)
        reward, fallen, _ = reference_reward(geometry, state, action, previous,
            targets[0][t:t+1], targets[1][t:t+1], targets[2][t:t+1])
        result = result+gamma**t*alive*reward
        alive = alive*(~fallen).double()
        previous = action
    return result[0]


def physics_branch(runtime, snapshot, controls, targets, geometry):
    m, d = runtime.model, runtime.data
    mujoco.mj_resetData(m, d)
    m.opt.disableflags = runtime.base_disable
    m.geom_friction[:, 0] = snapshot["context"][0]
    m.pair_friction[:, :2] = snapshot["context"][0]
    mujoco.mj_setState(m, d, snapshot["integration"], mujoco.mjtState.mjSTATE_INTEGRATION)
    arrays = {k: [] for k in ["state", "observation", "applied_action", "next_state", "reward", "terminated", "truncated"]}
    previous = snapshot["observation"][-m.nu:].copy()
    for i, action in enumerate(controls):
        obs = snapshot["observation"].copy() if i == 0 else np.asarray(runtime.observation(previous))
        before = np.asarray(runtime.state())
        d.ctrl[:] = action
        mujoco.mj_step(m, d, nstep=runtime.substeps)
        mujoco.mj_forward(m, d)
        after = np.asarray(runtime.state())
        with torch.no_grad():
            reward, fallen, _ = reference_reward(geometry, torch.from_numpy(after)[None], torch.from_numpy(action)[None],
                torch.from_numpy(previous)[None], targets[0][i:i+1], targets[1][i:i+1], targets[2][i:i+1])
        fall = bool(fallen[0])
        values = dict(state=before, observation=obs, applied_action=action.copy(), next_state=after,
            reward=float(reward[0]), terminated=fall, truncated=not fall and i == len(controls)-1)
        for key in arrays:
            arrays[key].append(values[key])
        previous = action.copy()
        if fall:
            break
    return {k: np.asarray(v) for k, v in arrays.items()}


def returns(arrays, horizons, gamma):
    discounted = arrays["reward"]*gamma**np.arange(len(arrays["reward"]))
    return {str(h): float(discounted[:h].sum()) for h in horizons}


def replay_snapshots(runtime, reference, case, arrays, offsets, count):
    """Recover solver warm starts from exact source controls, not qpos/qvel alone."""
    m, d = runtime.model, runtime.data
    mujoco.mj_resetData(m, d)
    m.opt.disableflags = runtime.base_disable
    m.geom_friction[:, 0] = case["friction"]
    m.pair_friction[:, :2] = case["friction"]
    mujoco.mj_setState(m, d, reference.arrays["integration"][0], mujoco.mjtState.mjSTATE_INTEGRATION)
    snapshots, verified = {}, 0
    available = [o for o in offsets if o+count <= len(arrays["state"])]
    end = max((o+count for o in available), default=0)
    previous = reference.arrays["observation"][0, -m.nu:].copy()
    for i in range(end):
        actual = np.asarray(runtime.state())
        if not np.array_equal(actual.astype(np.float32), arrays["state"][i]):
            raise ValueError("source control replay differs before snapshot")
        if i in available:
            integration = np.empty(mujoco.mj_stateSize(m, mujoco.mjtState.mjSTATE_INTEGRATION))
            mujoco.mj_getState(m, d, integration, mujoco.mjtState.mjSTATE_INTEGRATION)
            obs = reference.arrays["observation"][0].copy() if i == 0 else np.asarray(runtime.observation(previous))
            snapshots[i] = dict(integration=integration, state=actual, observation=obs,
                actions=arrays["applied_action"][i:i+count].astype(np.float64),
                context=np.asarray([case["friction"], 1.], dtype=np.float64))
        action = arrays["applied_action"][i].astype(np.float64)
        d.ctrl[:] = action
        mujoco.mj_step(m, d, nstep=runtime.substeps)
        mujoco.mj_forward(m, d)
        if not np.array_equal(np.asarray(runtime.state()).astype(np.float32), arrays["next_state"][i]):
            raise ValueError("source control replay differs after snapshot")
        previous = action
        verified += 1
    return snapshots, verified


def save_record(output, ident, arrays, snapshot_path, metadata, config):
    path = output/"physics"/(ident+".npz")
    np.savez_compressed(path, **arrays)
    return dict(episode_id=ident, file=str(path.relative_to(output)), sha256=digest(path), steps=len(arrays["state"]),
        snapshot=str(snapshot_path.relative_to(output)), snapshot_sha256=digest(snapshot_path),
        returns=returns(arrays, config["horizons"], config["gamma"]), **metadata)


def run(args):
    started = time.perf_counter()
    source, output = Path(args.source).resolve(), Path(args.output).resolve()
    config = json.loads((output/"config.json").read_bytes())
    if digest(source/"report.json") != config["source_report_sha256"]:
        raise ValueError("wrong frozen last-cycle source")
    previous = json.loads((source/"report.json").read_bytes())
    torch.set_num_threads(previous["config"]["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    manifest, references = load_references(previous["references"])
    if digest(Path(previous["references"])/"manifest.json") != previous["reference_manifest_sha256"]:
        raise ValueError("reference manifest changed")
    runtime = PhysicsRuntime(args.scene, manifest["layout"]["dt_s"])
    limits = runtime.model.actuator_ctrlrange.copy()
    by_id = {r["episode_id"]: r for r in previous["physical_records"]}
    (output/"physics").mkdir(); (output/"snapshots").mkdir(); (output/"directions").mkdir()
    records, conditions, missing = [], [], []
    replayed = 0
    for method in config["methods"]:
        for seed in config["seeds"]:
            row = next(r for r in previous["runs"] if r["method"]==method and r["seed"]==seed)
            model_path = Path(row["model_checkpoint"])
            if digest(model_path) != row["model_sha256"] or digest(row["before_checkpoint"]) != row["before_sha256"]:
                raise ValueError("frozen model or tape actor changed")
            model, _ = load_model(model_path)
            model.double()
            for p in model.parameters(): p.requires_grad_(False)
            _, geometry, _ = load_reference_actor(row["before_checkpoint"])
            geometry.double()
            model_before = state_digest(model)
            for clip_index in config["probe_clip_indices"]:
                comparison = next(c for c in row["comparisons"] if c["clip_index"]==clip_index)
                record = by_id[comparison["before_episode_id"]]
                path = source/record["file"]
                if digest(path) != record["sha256"] or record["behavior"]["sha256"] != row["before_sha256"]:
                    raise ValueError("source physical control tape changed")
                with np.load(path, allow_pickle=False) as archive: tape = dict(archive)
                clip, reference = references[clip_index]
                snapshots, count = replay_snapshots(runtime, reference, clip["case"], tape,
                    config["offset_steps"], config["maximum_branch_steps"])
                replayed += count
                for offset in config["offset_steps"]:
                    if offset not in snapshots:
                        missing.append(dict(method=method, seed=seed, clip_index=clip_index, offset=offset,
                            reason="source ends before complete maximum-horizon window", source_steps=record["steps"]))
                        continue
                    snapshot = snapshots[offset]
                    label = f"{method}-seed-{seed}-clip-{clip_index}-offset-{offset}"
                    snapshot_path = output/"snapshots"/(label+".npz")
                    np.savez_compressed(snapshot_path, **snapshot)
                    targets = reward_targets(reference, offset, config["maximum_branch_steps"])
                    baseline = physics_branch(runtime, snapshot, snapshot["actions"], targets, geometry)
                    if not np.array_equal(baseline["next_state"].astype(np.float32), tape["next_state"][offset:offset+len(baseline["state"])]):
                        raise ValueError("restoring full solver snapshot changes baseline physics")
                    metadata = dict(method=method, seed=seed, clip_index=clip_index, offset=offset,
                        source_family=clip["source_family"], source_episode_id=record["episode_id"],
                        source_physics_sha256=record["sha256"], source_actor_sha256=row["before_sha256"],
                        geometry_checkpoint=row["before_checkpoint"], context=snapshot["context"].tolist())
                    base_record = save_record(output, label+"-baseline", baseline, snapshot_path,
                        {**metadata, "role": "baseline-replay", "amplitude": 0.}, config)
                    records.append(base_record)
                    condition = dict(**metadata, snapshot=base_record["snapshot"], snapshot_sha256=base_record["snapshot_sha256"],
                        model_checkpoint=str(model_path), model_sha256=digest(model_path), baseline=base_record["episode_id"],
                        exact_float32_source_replay=True, directions=[])
                    for horizon in config["horizons"]:
                        first = torch.from_numpy(snapshot["actions"][0].copy()).requires_grad_(True)
                        objective = tape_objective(model, geometry, snapshot, targets, horizon, first, config["gamma"])
                        gradient, = torch.autograd.grad(objective, first)
                        direction, scale, interior_count = feasible_direction(gradient,
                            snapshot["actions"][0], limits, max(config["action_rms_amplitudes_rad"]))
                        direction_path = output/"directions"/(label+f"-h{horizon}.npz")
                        np.savez_compressed(direction_path, direction=direction, gradient=gradient.detach().numpy())
                        epsilon = config["finite_difference_epsilon_rad"]
                        def predicted(amount):
                            controls = first_action_tape(snapshot["actions"], direction, amount, limits)
                            with torch.no_grad():
                                return float(tape_objective(model, geometry, snapshot, targets, horizon,
                                    torch.from_numpy(controls[0]), config["gamma"]))
                        analytic = float((gradient*torch.from_numpy(direction)).sum())
                        numeric = (predicted(epsilon)-predicted(-epsilon))/(2*epsilon)
                        if abs(analytic-numeric) > 1e-5+1e-3*abs(numeric):
                            raise ValueError(f"model action gradient fails finite difference: {label} H{horizon}, analytic={analytic}, numeric={numeric}, "
                                f"baseline_clip_error={np.max(np.abs(first_action_tape(snapshot['actions'], direction, 0., limits)[0]-snapshot['actions'][0]))}")
                        outcomes = []
                        for amplitude in config["action_rms_amplitudes_rad"]:
                            pair = dict(amplitude_rad=amplitude)
                            for sign, name in [(-1, "minus"), (1, "plus")]:
                                controls = first_action_tape(snapshot["actions"], direction, sign*amplitude, limits)
                                arrays = physics_branch(runtime, snapshot, controls, targets, geometry)
                                extra = dict(role="counterfactual", amplitude=sign*amplitude, direction_horizon=horizon,
                                    direction_file=str(direction_path.relative_to(output)), direction_sha256=digest(direction_path))
                                branch = save_record(output, label+f"-h{horizon}-amp{amplitude}-sign{sign}", arrays,
                                    snapshot_path, {**metadata, **extra}, config)
                                records.append(branch)
                                pair[name] = dict(episode_id=branch["episode_id"], model_return=predicted(sign*amplitude),
                                    physics_return=branch["returns"][str(horizon)],
                                    achieved_first_action_rms_rad=float(np.sqrt(np.mean((controls[0]-snapshot["actions"][0])**2))))
                            pair["physics_directional"] = (pair["plus"]["physics_return"]-pair["minus"]["physics_return"])/(2*amplitude)
                            pair["model_directional"] = (pair["plus"]["model_return"]-pair["minus"]["model_return"])/(2*amplitude)
                            pair["positive_physics_gain"] = pair["plus"]["physics_return"]-base_record["returns"][str(horizon)]
                            outcomes.append(pair)
                        condition["directions"].append(dict(horizon=horizon, gradient_rms=scale,
                            interior_action_coordinates=interior_count,
                            analytic_directional=analytic, model_finite_difference_directional=numeric,
                            finite_difference_error=abs(analytic-numeric), model_baseline_return=float(objective.detach()),
                            physics_baseline_return=base_record["returns"][str(horizon)], outcomes=outcomes))
                    conditions.append(condition)
            if state_digest(model) != model_before:
                raise ValueError("action response changed model tensors")
            print(json.dumps(dict(event="action-response-finished", method=method, seed=seed,
                conditions=sum(c["method"]==method and c["seed"]==seed for c in conditions))), flush=True)
    report = dict(format="moonrobo.g1-reference-action-response.v1", config=config, source_study=str(source),
        source_report_sha256=digest(source/"report.json"), references=previous["references"],
        reference_manifest_sha256=previous["reference_manifest_sha256"], physical_records=records,
        conditions=conditions, missing_conditions=missing, source_transitions_replayed=replayed,
        counterfactual_episodes=sum(r["role"]=="counterfactual" for r in records),
        baseline_replay_episodes=sum(r["role"]=="baseline-replay" for r in records),
        provider_sha256=digest(__file__), provider_seconds=time.perf_counter()-started,
        physical_execution_allowed=False, release_qualified=False, scope=config["scope"])
    (output/"report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


def export(args):
    folder = Path(args.output)
    report = json.loads((folder/"report.json").read_bytes())
    config = report["config"]
    torch.set_num_threads(2)
    manifest, references = load_references(report["references"])
    runtime = PhysicsRuntime(args.scene)
    geometries = {}
    for record in report["physical_records"]:
        if record["geometry_checkpoint"] not in geometries:
            _, geometry, _ = load_reference_actor(record["geometry_checkpoint"])
            geometries[record["geometry_checkpoint"]] = geometry.double()
        geometry = geometries[record["geometry_checkpoint"]]
        path, snapshot_path = folder/record["file"], folder/record["snapshot"]
        if digest(path) != record["sha256"] or digest(snapshot_path) != record["snapshot_sha256"]:
            raise ValueError("physical branch or solver snapshot changed")
        with np.load(path, allow_pickle=False) as archive: a = dict(archive)
        with np.load(snapshot_path, allow_pickle=False) as archive: snapshot = dict(archive)
        direction = np.zeros(29)
        if record["role"]=="counterfactual":
            direction_path = folder/record["direction_file"]
            if digest(direction_path) != record["direction_sha256"]: raise ValueError("saved direction changed")
            with np.load(direction_path, allow_pickle=False) as archive: direction = archive["direction"]
        expected = first_action_tape(snapshot["actions"], direction, record["amplitude"], runtime.model.actuator_ctrlrange)
        n = record["steps"]
        if a["state"].dtype != np.float64 or not np.array_equal(a["state"][0], snapshot["state"]) or not np.array_equal(a["state"][1:], a["next_state"][:-1]):
            raise ValueError("branch precision, initial state or continuity changed")
        if not np.array_equal(expected[:n], a["applied_action"]): raise ValueError("branch is not the frozen one-action perturbation")
        _, reference = references[record["clip_index"]]
        targets = reward_targets(reference, record["offset"], n)
        with torch.no_grad():
            obs = torch.from_numpy(a["observation"])
            rewards, fallen, _ = reference_reward(geometry, torch.from_numpy(a["next_state"]), torch.from_numpy(a["applied_action"]),
                obs[:, -29:], *targets)
            reward_error = float((rewards-torch.from_numpy(a["reward"])).abs().max())
            expected_obs = observation(torch.from_numpy(a["state"]), obs[:, -29:], BODY)
            obs_error = float((expected_obs-obs).abs().max())
        if reward_error > 1e-12 or obs_error > 1e-10 or not np.array_equal(fallen.numpy(), a["terminated"]):
            raise ValueError("branch reward, observation or fall reconstruction differs")
        if not np.array_equal(a["observation"][0], snapshot["observation"]) or not np.array_equal(a["observation"][1:, -29:], a["applied_action"][:-1]):
            raise ValueError("previous action history differs")
        if a["terminated"][:-1].any() or a["truncated"][:-1].any() or not (a["terminated"][-1] or a["truncated"][-1]):
            raise ValueError("branch has invalid episode boundary")
        if not a["terminated"][-1] and n != config["maximum_branch_steps"]: raise ValueError("short unfallen branch")
        steps = [dict(time_s=i*runtime.dt, state=a["state"][i].tolist(), observation=a["observation"][i].tolist(),
            applied_action=a["applied_action"][i].tolist(), next_state=a["next_state"][i].tolist(),
            goal=reference.goals[record["offset"]+i+1].tolist(), reward=float(a["reward"][i]),
            terminated=bool(a["terminated"][i]), truncated=bool(a["truncated"][i])) for i in range(n)]
        episode = dict(id=record["episode_id"], source_family=record["source_family"], split="train", context=record["context"], steps=steps)
        dataset = runtime.dataset([episode], "reference-action-response")
        dataset.update(model_ref=manifest["model_ref"], goal_axes=manifest["layout"]["goal_axes"],
            provenance="Known development-state open-loop physical action branches; float64 archives, one perturbed first control, frozen later controls")
        print(json.dumps(dict(record=record, dataset=dataset, verification=dict(reward_error=reward_error, observation_error=obs_error)),
            allow_nan=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source"); parser.add_argument("--scene", required=True); parser.add_argument("--output", required=True)
    parser.add_argument("--export", action="store_true")
    args = parser.parse_args()
    (export if args.export else run)(args)
