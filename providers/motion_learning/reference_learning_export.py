"""Verify saved RL inputs/actions/rewards and stream typed physical episodes.

The experiment archives training inputs in float32. Original scalar quality
metrics came from float64 MuJoCo and are checked within declared storage
precision, not presented as bit-exact state reconstruction.
"""
import argparse
import hashlib
import json
from pathlib import Path

import mujoco
import numpy as np
import torch
from torch.nn.utils import parameters_to_vector, vector_to_parameters

from balance_features import sequence_features
from cpu_physics import PhysicsRuntime
from dynamics import load_model
from reference_actor import load_reference_actor, load_references, reference_observation
from reference_task import ReferenceSchedule, reference_reward


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_behavior_actor(folder, behavior):
    path = Path(folder)/behavior["checkpoint"]
    if digest(path) != behavior["sha256"]: raise ValueError("behavior checkpoint changed")
    actor = load_reference_actor(path)[0]
    if "direction_file" in behavior:
        direction_path = Path(folder)/behavior["direction_file"]
        if digest(direction_path) != behavior["direction_sha256"]: raise ValueError("behavior direction changed")
        data = torch.load(direction_path, weights_only=True)
        if data["base_actor_sha256"] != behavior["sha256"] or data["parameter_names"] != [n for n, _ in actor.named_parameters()]:
            raise ValueError("parameter direction belongs to another actor")
        base = parameters_to_vector(actor.parameters()).detach()
        vector_to_parameters(base+behavior["coefficient"]*data["direction"], actor.parameters())
    return actor


def run(args):
    folder = Path(args.study)
    report = json.loads((folder/"report.json").read_bytes())
    charter = json.loads((folder/"charter.json").read_bytes())
    config = report["config"]
    torch.set_num_threads(config["cpu_threads"])
    manifest, references = load_references(charter["references"])
    if digest(Path(charter["references"])/"manifest.json") != report["reference_manifest_sha256"]:
        raise ValueError("reference manifest changed after learning")
    _, geometry, _ = load_reference_actor(folder/"initial/actor-zero-output.pt")
    origins = sorted({r["origin_step"] for r in report["physical_records"]})
    schedule = ReferenceSchedule(references, geometry, origins)
    runtime = PhysicsRuntime(args.scene, schedule.dt)
    if config["format"] == "moonrobo.g1-reference-final-route-training-charter.v1":
        from reference_final_route_training import generator_digest, optimizer_digest
        if digest(args.scene) != manifest["scene_sha256"] or mujoco.__version__ != manifest["mujoco_version"]:
            raise ValueError("physics scene/version differs from the frozen reference source")
        state_checks = []
        for result in report["runs"]:
            if result["gradient_route"] != "stop-policy-inputs": continue
            artifact = result["actor_update_state"]
            path = folder/artifact["file"]
            if digest(path) != artifact["sha256"]: raise ValueError("actor-update artifact changed")
            data = torch.load(path, weights_only=True)
            checkpoint = folder/result["checkpoint"]["checkpoint"]
            if (data["format"] != "moonrobo.g1-fixed-model-actor-update-state.v1" or
                digest(checkpoint) != data["paired_actor_sha256"] or data["paired_actor_sha256"] != result["checkpoint"]["sha256"] or
                data["source_report_sha256"] != report["source_report_sha256"] or
                data["config"]["actor_feedback_gradient"] != "stop-policy-inputs"):
                raise ValueError("actor-update artifact pairing differs")
            expected = next(r for r in report["reconstruction"] if r["method"]==result["method"] and r["seed"]==result["seed"])["cycles"][-1]
            if digest(data["fixed_model_checkpoint"]) != data["fixed_model_sha256"] or data["fixed_model_sha256"] != expected["model_sha256"]:
                raise ValueError("actor-update artifact imports another model")
            restored = load_reference_actor(checkpoint)[0]
            optimizer = torch.optim.Adam(restored.parameters(), lr=data["config"]["actor_learning_rate"])
            optimizer.load_state_dict(data["optimizer"])
            generator = torch.Generator().set_state(data["sampler_state"])
            if optimizer_digest(optimizer) != artifact["optimizer_sha256"] or generator_digest(generator) != artifact["sampler_sha256"]:
                raise ValueError("independent actor-update reload differs")
            state_checks.append(dict(method=result["method"], seed=result["seed"], optimizer_sha256=optimizer_digest(optimizer),
                sampler_sha256=generator_digest(generator), actor_sha256=digest(checkpoint), fixed_model_sha256=data["fixed_model_sha256"]))
        (folder/"actor-update-state-verification.json").write_text(json.dumps(dict(
            format="moonrobo.g1-actor-update-state-verification.v1", fixed_model_actor_state_only=True,
            source_report_sha256=digest(folder/"report.json"), checks=state_checks), indent=2))
    if config["format"] in ["moonrobo.g1-reference-tail-training-charter.v1", "moonrobo.g1-reference-state-origin-charter.v1", "moonrobo.g1-reference-extended-training-charter.v1", "moonrobo.g1-reference-replay-anchor-charter.v1"]:
        common_fits = []
        for seed in config["seeds"]:
            paired = []
            for method in config["methods"]:
                run = next(r for r in report["runs"] if r["method"]==method and r["seed"]==seed)
                actor_path = folder/run["cycles"][0]["checkpoint"]["checkpoint"]
                model_path = actor_path.parent/"dynamics-cycle-1.pt"
                model, _ = load_model(model_path)
                value_path = actor_path.parent/"value-cycle-1.pt"
                value = torch.load(value_path, weights_only=True)["state_dict"]
                paired.append((model.state_dict(), value))
            for part in [0, 1]:
                if paired[0][part].keys() != paired[1][part].keys() or any(
                    not torch.equal(v, paired[1][part][k]) for k, v in paired[0][part].items()):
                    raise ValueError("common first model/value tensors differ between tail arms")
            hashes = []
            for part in paired[0]:
                h = hashlib.sha256()
                for key, tensor in part.items(): h.update(key.encode()); h.update(tensor.numpy().tobytes())
                hashes.append(h.hexdigest())
            common_fits.append(dict(seed=seed, first_model_state_sha256=hashes[0], first_value_state_sha256=hashes[1]))
        (folder/"common-fit-verification.json").write_text(json.dumps(dict(
            format="moonrobo.g1-reference-common-fit.v1", paired_first_fits_identical=True,
            seeds=common_fits, source_report_sha256=digest(folder/"report.json")), indent=2))
    if config["format"] in ["moonrobo.g1-reference-extended-training-charter.v1", "moonrobo.g1-reference-replay-anchor-charter.v1"]:
        reconstruction = []
        baseline_method = config["reused_baseline_method"]
        candidate_method = next(m for m in config["methods"] if m!=baseline_method)
        for seed in config["seeds"]:
            baseline = next(r for r in report["runs"] if r["method"]==baseline_method and r["seed"]==seed)
            extended = next(r for r in report["runs"] if r["method"]==candidate_method and r["seed"]==seed)
            for i in range(config.get("reconstruction_cycles", config["baseline_cycles"])):
                states = []
                for result in [baseline, extended]:
                    cycle = result["cycles"][i]
                    path = folder/cycle["checkpoint"]["checkpoint"]
                    if digest(path) != cycle["checkpoint"]["sha256"]: raise ValueError("reconstruction actor bytes changed")
                    actor = load_reference_actor(path)[0].state_dict()
                    model = torch.load(path.parent/f"dynamics-cycle-{i+1}.pt", weights_only=True)["model"]
                    value = torch.load(path.parent/f"value-cycle-{i+1}.pt", weights_only=True)["state_dict"]
                    states.append(dict(actor=actor, model=model, value=value))
                row = dict(seed=seed, cycle=i+1)
                claimed = extended["baseline_reconstruction"][i]
                if claimed["cycle"] != i+1 or not claimed["all_tensors_identical"]: raise ValueError("missing reconstruction check")
                for name in ["actor", "model", "value"]:
                    a, b = states[0][name], states[1][name]
                    if a.keys() != b.keys() or any(not torch.equal(t, b[k]) for k, t in a.items()):
                        raise ValueError(f"independent reconstruction differs: {name}, seed {seed}, cycle {i+1}")
                    h = hashlib.sha256()
                    for k, tensor in b.items(): h.update(k.encode()); h.update(tensor.numpy().tobytes())
                    row[name+"_state_sha256"] = h.hexdigest()
                    if claimed[name+"_state_sha256"] != h.hexdigest(): raise ValueError("reconstruction digest differs")
                reconstruction.append(row)
        (folder/"reconstruction-verification.json").write_text(json.dumps(dict(
            format="moonrobo.g1-reference-reconstruction.v1", all_actor_model_value_tensors_identical=True,
            cycles=reconstruction, source_report_sha256=digest(folder/"report.json")), indent=2))
    if config["format"] == "moonrobo.g1-reference-replay-anchor-charter.v1":
        by_id = {r["episode_id"]: r for r in report["physical_records"]}
        replay_checks = []
        for result in report["runs"]:
            if result["method"] != "replay-prefix-anchor": continue
            generator = torch.Generator().manual_seed(70000+result["seed"])
            total, initial = 0, None
            for cycle in result["cycles"]:
                fresh = sum(max(0, by_id[i]["steps"]-config["model_window"]+1) for i in cycle["training_episode_ids"])
                total += fresh
                if initial is None: initial = fresh
                anchor = initial if cycle["cycle"]>config["model_initial_anchor_after_cycle"] else 0
                windows = min(total, config["model_replay_windows"])
                fit = cycle["model"]
                if (fit["windows"] != windows or fit["anchor_windows"] != anchor or fit["recent_windows"] != windows-anchor or
                    fit["replay_mode"] != ("initial-anchor" if anchor else "recent-fifo")):
                    raise ValueError("retained model pool counts differ from the frozen replay recipe")
                h = hashlib.sha256(); anchor_samples = 0
                for _ in range(config["model_updates_per_cycle"]):
                    ids = torch.randint(windows, (config["model_batch_size"],), generator=generator)
                    h.update(ids.numpy().tobytes()); anchor_samples += int((ids<anchor).sum())
                if fit["sample_indices_sha256"] != h.hexdigest() or fit["anchor_samples"] != anchor_samples:
                    raise ValueError("model replay draws differ from the original seeded uniform stream")
                replay_checks.append(dict(seed=result["seed"], cycle=cycle["cycle"], windows=windows,
                    anchor_windows=anchor, recent_windows=windows-anchor, anchor_samples=anchor_samples,
                    total_samples=config["model_updates_per_cycle"]*config["model_batch_size"], sample_indices_sha256=h.hexdigest()))
        (folder/"model-replay-verification.json").write_text(json.dumps(dict(
            format="moonrobo.g1-reference-model-replay-verification.v1", pool_counts_verified=True,
            seeded_model_draws_verified=True, cycles=replay_checks, source_report_sha256=digest(folder/"report.json")), indent=2))
    if config["format"] in ["moonrobo.g1-reference-state-origin-charter.v1", "moonrobo.g1-reference-extended-training-charter.v1", "moonrobo.g1-reference-replay-anchor-charter.v1"]:
        by_id = {r["episode_id"]: r for r in report["physical_records"]}
        origin_checks = []
        for run in report["runs"]:
            if run["method"] not in ["replay-prefix", "replay-prefix-extended", "replay-prefix-anchor"]: continue
            generator = torch.Generator().manual_seed(23000+run["seed"])
            for cycle in run["cycles"]:
                lengths = [by_id[i]["steps"] for i in cycle["training_episode_ids"]]
                ages = torch.cat([torch.arange(n) for n in lengths])
                torch.randint(len(ages), (config["actor_calibration_batch_size"],), generator=generator)
                actor = cycle["actor"]
                if actor["origin_sampling"] != "trajectory-states": raise ValueError("wrong actor origin mode")
                samples = actor["actor_origin_samples"]
                if len(samples) != actor["actor_steps"]: raise ValueError("missing origin draws")
                all_ages = []
                for sample in samples:
                    expected = torch.randint(len(ages), (config["actor_batch_size"],), generator=generator)
                    if not torch.equal(torch.tensor(sample["replay_indices"]), expected):
                        raise ValueError("actor origin indices differ from uniform seeded draws")
                    selected = ages[expected]; all_ages.append(selected)
                    if (sample["minimum_age_steps"] != int(selected.min()) or sample["maximum_age_steps"] != int(selected.max()) or
                        sample["mean_age_steps"] != float(selected.float().mean()) or sample["nonreset_samples"] != int((selected>0).sum())):
                        raise ValueError("actor origin age summary differs from physical episodes")
                selected = torch.cat(all_ages)
                origin_checks.append(dict(method=run["method"], seed=run["seed"], cycle=cycle["cycle"], samples=len(selected),
                    nonreset_samples=int((selected>0).sum()), mean_age_s=float(selected.float().mean())*schedule.dt,
                    maximum_age_s=float(selected.max())*schedule.dt))
        (folder/"actor-origin-verification.json").write_text(json.dumps(dict(
            format="moonrobo.g1-reference-actor-origin-verification.v1", seeded_uniform_draws_verified=True,
            cycles=origin_checks, source_report_sha256=digest(folder/"report.json")), indent=2))
    models = {}
    trials = {trial["episode_id"]: trial for result in [report["initial"]]+report["runs"] for trial in result["trials"]}
    for record in report["physical_records"]:
        path = folder/record["file"]
        if digest(path) != record["sha256"]: raise ValueError("physical record bytes changed")
        behavior = record["behavior"]
        key = (behavior["checkpoint"], behavior.get("direction_file"), behavior.get("coefficient"))
        if key not in models:
            models[key] = load_behavior_actor(folder, behavior)
        actor = models[key]
        with np.load(path, allow_pickle=False) as archive: a = dict(archive)
        n, origin, c = record["steps"], record["origin_step"], record["clip_index"]
        if a["state"].dtype != np.float32 or not np.array_equal(a["state"][1:], a["next_state"][:-1]):
            raise ValueError("unexpected physical storage dtype or broken state continuity")
        obs = torch.from_numpy(a["observation"])
        state, action = torch.from_numpy(a["next_state"]), torch.from_numpy(a["applied_action"])
        phases, clips = origin+torch.arange(n), torch.full((n,), c, dtype=torch.long)
        current, future, valid = schedule.command(clips, phases, actor.future_length)
        history = obs[(torch.arange(n)[:, None]-torch.arange(actor.history_length-1, -1, -1)[None]).clamp_min(0)]
        with torch.no_grad():
            features = sequence_features(geometry, obs, schedule.dt, window=None)
            desired_features = sequence_features(geometry, reference_observation(schedule.goals[c, origin:origin+n]), schedule.dt, window=None)
            actual_error = float((features-torch.from_numpy(a["actual_features"])).abs().max())
            reference_error = float((desired_features-torch.from_numpy(a["reference_features"])).abs().max())
            if max(actual_error, reference_error) > config["maximum_feature_alignment_error"]:
                raise ValueError("saved causal features do not match actual/reference histories")
            means, actions = [], []
            for first in range(0, n, 256):
                ids = slice(first, first+256)
                means.append(actor.latent_mean(history[ids], current[ids], future[ids], valid[ids]))
                actions.append(actor.action_from_latent(torch.from_numpy(a["latent"])[ids], history[ids], current[ids], features[ids], desired_features[ids]))
            mean = torch.cat(means); expected_action = torch.cat(actions)
            mean_error = float((mean-torch.from_numpy(a["old_mean"])).abs().max())
            action_error = float((expected_action-action).abs().max())
            if mean_error > 8e-5 or action_error > config["maximum_action_alignment_error_rad"]:
                raise ValueError("offline actor logits/actions do not match collected behavior")
            generator = torch.Generator().manual_seed(config["noise_seed_base"]+record["seed"]*1000000+
                record["cycle"]*1000+c+origin*config.get("noise_seed_origin_stride", 0)+
                (50000 if record["role"]=="model-diagnostic" else 0))
            noise = torch.cat([torch.randn(1, actor.nu, generator=generator) for _ in range(n)])
            expected_latent = torch.from_numpy(a["old_mean"])+record["action_std"]*noise
            if not torch.equal(expected_latent, torch.from_numpy(a["latent"])):
                raise ValueError("saved latent samples disagree with the frozen exploration law")
            reward, fallen, _ = reference_reward(geometry, state, action, obs[:, -29:],
                schedule.positions[clips, phases+1], schedule.quaternions[clips, phases+1], schedule.goals[clips, phases+1, :29], schedule.dt)
            reward_error = float((reward-torch.from_numpy(a["reward"])).abs().max())
            if reward_error > 1e-6 or not torch.equal(fallen, torch.from_numpy(a["terminated"])):
                raise ValueError("stored shared reward/termination differs from recorded states")
        clip, reference = references[c]
        if record["reference_sha256"] != clip["sha256"]: raise ValueError("record references another clip")
        metric_difference = 0.
        if record["episode_id"] in trials:
            source_trial = trials[record["episode_id"]]
            target = reference.arrays["state"][origin+1:origin+n+1]
            joint = float(np.sqrt(np.mean((a["next_state"][:, 7:36].astype(np.float64)-target[:, 7:36])**2)))
            body, root, angles = [], [], []
            for i, saved in enumerate(a["next_state"]):
                runtime.data.qpos[:] = saved[:36]
                runtime.data.qpos[3:7] /= np.linalg.norm(runtime.data.qpos[3:7])
                mujoco.mj_kinematics(runtime.model, runtime.data)
                desired = reference.arrays["body_position"][origin+i+1]
                body.append(float(np.mean(np.sum((runtime.data.xpos[1:]-desired)**2, -1))))
                root.append(float(np.sum((runtime.data.xpos[runtime.root]-desired[runtime.root-1])**2)))
                rotation = runtime.data.xmat[runtime.root].reshape(3, 3)
                desired_r = reference.arrays["body_rotation"][origin+i+1, runtime.root-1]
                angles.append(float(np.arccos(np.clip((np.trace(desired_r @ rotation.T)-1)/2, -1, 1)))**2)
            metrics = dict(joint_rmse_rad=joint, body_position_rmse_m=float(np.sqrt(np.mean(body))),
                root_position_rmse_m=float(np.sqrt(np.mean(root))), root_orientation_rmse_rad=float(np.sqrt(np.mean(angles))))
            metric_difference = max(abs(value-source_trial[key]) for key, value in metrics.items())
            if metric_difference > 1e-5: raise ValueError("quality metrics exceed float32 archive reconstruction tolerance")
        steps = [dict(time_s=i*schedule.dt, state=a["state"][i].tolist(), observation=a["observation"][i].tolist(),
            applied_action=a["applied_action"][i].tolist(), next_state=a["next_state"][i].tolist(),
            goal=reference.goals[origin+i+1].tolist(), reward=float(a["reward"][i]),
            terminated=bool(a["terminated"][i]), truncated=bool(a["truncated"][i])) for i in range(n)]
        episode = dict(id=record["episode_id"], source_family=record["source_family"], split="train", context=record["context"], steps=steps)
        dataset = runtime.dataset([episode], "reference-learning-comparison")
        dataset.update(model_ref=manifest["model_ref"], goal_axes=manifest["layout"]["goal_axes"],
            provenance="New on-policy physics, float32 training archives; original reference motion bytes retained separately")
        verification = dict(storage_dtype="float32", feature_error=actual_error, reference_feature_error=reference_error,
            actor_mean_error=mean_error, applied_action_error_rad=action_error, reward_error=reward_error,
            maximum_quality_metric_reconstruction_difference=metric_difference)
        print(json.dumps(dict(record=record, dataset=dataset, verification=verification), allow_nan=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--study", required=True); parser.add_argument("--scene", required=True)
    run(parser.parse_args())
