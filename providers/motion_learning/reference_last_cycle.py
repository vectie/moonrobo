"""Compare the last saved policy update's imagined and actual physical outcomes."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import torch

from cpu_physics import PhysicsRuntime
from dynamics import imagine, load_model
from reference_actor import load_reference_actor, load_references
from reference_learning import collect_episode, imagined_objective, join_batches, restore_collected_batch, state_digest, take
from reference_task import ReferenceSchedule


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inherited_record(record, source):
    record = copy.deepcopy(record)
    record["file"] = str(source/record["file"])
    record["behavior"]["checkpoint"] = str(source/record["behavior"]["checkpoint"])
    return record


def window_starts(length, horizon):
    """Overlapping windows remain within one episode and include its last window."""
    if length < horizon:
        return []
    starts = list(range(0, length-horizon+1, max(1, horizon//2)))
    if starts[-1] != length-horizon:
        starts.append(length-horizon)
    return starts


def discounted_returns(rewards, gamma, horizon):
    rewards = torch.as_tensor(rewards, dtype=torch.float64)
    weights = gamma**torch.arange(len(rewards), dtype=torch.float64)
    discounted = rewards*weights
    return dict(prefix_return=float(discounted[:horizon].sum()), full_return=float(discounted.sum()),
        prefix_observed_steps=min(horizon, len(rewards)), full_observed_steps=len(rewards))


@torch.no_grad()
def prediction_metrics(model, batch, horizons):
    results = []
    for horizon in horizons:
        starts = window_starts(len(batch["state"]), horizon)
        sums = torch.zeros(6, dtype=torch.float64)
        for first in range(0, len(starts), 128):
            ids = torch.tensor(starts[first:first+128])
            positions = ids[:, None]+torch.arange(horizon)[None]
            state = batch["state"][ids]
            truth = batch["next_state"][positions]
            prediction = imagine(model, state, batch["action"][positions], batch["context"][ids])
            # Sum window means, so the last short batch has its actual weight.
            errors = [((prediction-truth)/model.state_scale).square().mean((1, 2)),
                ((state[:, None]-truth)/model.state_scale).square().mean((1, 2)),
                (prediction[..., :3]-truth[..., :3]).square().mean((1, 2)),
                (prediction[..., 7:36]-truth[..., 7:36]).square().mean((1, 2)),
                (prediction[..., 36:39]-truth[..., 36:39]).square().mean((1, 2))]
            dot = (torch.nn.functional.normalize(prediction[..., 3:7], dim=-1)*
                torch.nn.functional.normalize(truth[..., 3:7], dim=-1)).sum(-1).abs().clamp(0, 1)
            errors.append((2*torch.acos(dot)).square().mean(1))
            sums += torch.stack([e.double().sum() for e in errors])
        n = len(starts)
        result = dict(horizon=horizon, windows=n, last_window_offset=starts[-1] if starts else None,
            normalized_state_mse=float(sums[0]/n) if n else None,
            persistence_mse=float(sums[1]/n) if n else None)
        for i, name in enumerate(["root_position_component_rmse_m", "joint_rmse_rad",
            "root_velocity_component_rmse_m_per_s", "root_orientation_rmse_rad"], 2):
            result[name] = float((sums[i]/n).sqrt()) if n else None
        results.append(result)
    return results


@torch.no_grad()
def predicted_return(model, actor, batch, geometry, schedule, learning):
    objective, active = imagined_objective(model, actor, None, batch, geometry, schedule,
        {**learning, "actor_critic_tail": False})
    return dict(return_mean=float(objective), active_imagined_steps=active, origins=len(batch["state"]))


def run(args):
    started = time.perf_counter()
    output, source = Path(args.output).resolve(), Path(args.source).resolve()
    charter = json.loads((output/"config.json").read_bytes())
    if digest(source/"report.json") != charter["source_report_sha256"]:
        raise ValueError("last-cycle source study changed")
    previous = json.loads((source/"report.json").read_bytes())
    original_charter = json.loads((source/"charter.json").read_bytes())
    learning = previous["config"]
    config = {**learning, **charter}
    torch.set_num_threads(learning["cpu_threads"])
    torch.use_deterministic_algorithms(True)
    _, references = load_references(original_charter["references"])
    if digest(Path(original_charter["references"])/"manifest.json") != previous["reference_manifest_sha256"]:
        raise ValueError("reference manifest changed")
    _, geometry, _ = load_reference_actor(output/"initial/actor-zero-output.pt")
    schedule = ReferenceSchedule(references, geometry, [0, 500, 1000])
    runtime = PhysicsRuntime(args.scene, schedule.dt)
    source_records = {r["episode_id"]: r for r in previous["physical_records"]}
    records, runs = [], []
    for method in charter["methods"]:
        for seed in charter["seeds"]:
            original = next(r for r in previous["runs"] if r["method"]==method and r["seed"]==seed)
            cycles = {c["cycle"]: c for c in original["cycles"]}
            before_meta = cycles[charter["before_cycle"]]["checkpoint"]
            after_meta = cycles[charter["after_cycle"]]["checkpoint"]
            before_path, after_path = source/before_meta["checkpoint"], source/after_meta["checkpoint"]
            for path, metadata in [(before_path, before_meta), (after_path, after_meta)]:
                if digest(path) != metadata["sha256"]:
                    raise ValueError("saved actor changed")
            before, _, _ = load_reference_actor(before_path)
            after, _, _ = load_reference_actor(after_path)
            model_path = after_path.parent/f"dynamics-cycle-{charter['after_cycle']}.pt"
            model, _ = load_model(model_path)
            frozen = {"before": state_digest(before), "after": state_digest(after), "model": state_digest(model)}
            train_ids = cycles[charter["after_cycle"]]["training_episode_ids"]
            training = join_batches([restore_collected_batch(source, source_records[i], before, schedule, learning) for i in train_ids])
            generator = torch.Generator().manual_seed(charter["training_origin_seed_base"]+seed)
            ids = torch.randint(len(training["state"]), (charter["training_origin_samples"],), generator=generator)
            sampled = take(training, ids)
            on_training = dict(before=predicted_return(model, before, sampled, geometry, schedule, learning),
                after=predicted_return(model, after, sampled, geometry, schedule, learning),
                episode_ids=train_ids, origin_indices_sha256=hashlib.sha256(ids.numpy().tobytes()).hexdigest(),
                distinct_origins=len(torch.unique(ids)), origins_after_reset=int((sampled["step"]>sampled["origin"]).sum()))
            on_training["predicted_change"] = on_training["after"]["return_mean"]-on_training["before"]["return_mean"]
            comparisons, trials = [], []
            for clip_index in charter["probe_clip_indices"]:
                clip, _ = references[clip_index]
                old_trial = next(t for t in original["trials"] if t["case_id"]==clip["case"]["id"] and
                    t["reference_start_step"]==charter["reference_origin_step"])
                final_record = inherited_record(source_records[old_trial["episode_id"]], source)
                if final_record["behavior"]["sha256"] != after_meta["sha256"]:
                    raise ValueError("reused final physics belongs to another actor")
                final_batch = restore_collected_batch(output, final_record, after, schedule, learning)
                behavior = dict(checkpoint=str(before_path), sha256=digest(before_path))
                before_batch, record, trial = collect_episode(runtime, references, schedule, before, geometry, learning,
                    clip_index, charter["reference_origin_step"], seed, charter["before_cycle"],
                    "last-cycle-before", output/method/f"seed-{seed}", behavior)
                record["file"] = str(output/method/f"seed-{seed}"/record["file"])
                # Both closed-loop predictions and both physics trials begin at
                # the same restored reference state and causal controller memory.
                for key in ["state", "history", "actual_features", "reference_features"]:
                    if not torch.equal(before_batch[key][0], final_batch[key][0]):
                        raise ValueError("paired initial state or controller memory differs")
                initial = take(before_batch, torch.tensor([0]))
                predicted_before = predicted_return(model, before, initial, geometry, schedule, learning)
                predicted_after = predicted_return(model, after, initial, geometry, schedule, learning)
                actual_before = discounted_returns(before_batch["reward"], learning["gamma"], learning["imagination_horizon"])
                actual_after = discounted_returns(final_batch["reward"], learning["gamma"], learning["imagination_horizon"])
                comparisons.append(dict(clip_index=clip_index, reference_id=clip["id"],
                    before_episode_id=record["episode_id"], after_episode_id=final_record["episode_id"],
                    predicted_before=predicted_before, predicted_after=predicted_after,
                    predicted_prefix_change=predicted_after["return_mean"]-predicted_before["return_mean"],
                    actual_before=actual_before, actual_after=actual_after,
                    actual_prefix_change=actual_after["prefix_return"]-actual_before["prefix_return"],
                    actual_full_change=actual_after["full_return"]-actual_before["full_return"],
                    before_prediction=prediction_metrics(model, before_batch, charter["prediction_horizons"]),
                    after_prediction=prediction_metrics(model, final_batch, charter["prediction_horizons"]),
                    before_trial=trial, after_trial=old_trial, paired_initial_state_and_memory=True))
                records += [record, final_record]
                trials += [trial, old_trial]
            if frozen != {"before": state_digest(before), "after": state_digest(after), "model": state_digest(model)}:
                raise ValueError("diagnostic changed frozen learned tensors")
            row = dict(method=method, seed=seed, before_checkpoint=str(before_path), before_sha256=digest(before_path),
                after_checkpoint=str(after_path), after_sha256=digest(after_path),
                model_checkpoint=str(model_path), model_sha256=digest(model_path),
                training_origin_prediction=on_training, comparisons=comparisons, trials=trials,
                frozen_weights_unchanged=True)
            runs.append(row)
            print(json.dumps(dict(event="last-cycle-finished", method=method, seed=seed,
                training_prediction_change=on_training["predicted_change"],
                changes=[dict(reference=c["reference_id"], predicted=c["predicted_prefix_change"],
                    prefix=c["actual_prefix_change"], full=c["actual_full_change"]) for c in comparisons])), flush=True)
    report = dict(format="moonrobo.g1-reference-last-cycle.v1", config=config, source_study=str(source),
        source_report_sha256=digest(source/"report.json"), reference_manifest_sha256=previous["reference_manifest_sha256"],
        references=original_charter["references"], initial=dict(trials=[]), runs=runs, physical_records=records,
        new_physical_records=18, reused_physical_records=18, provider_sha256=digest(__file__),
        provider_seconds=time.perf_counter()-started, physical_execution_allowed=False,
        release_qualified=False, scope=charter["selection"])
    (output/"report.json").write_text(json.dumps(report, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["source", "scene", "output"]:
        parser.add_argument("--"+name, required=True)
    run(parser.parse_args())
