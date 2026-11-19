"""Isolate replay distribution in frozen temporal actor/value parameter directions."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from actor_update_probe import scaled_actor
from cpu_physics import PhysicsRuntime
from dynamics import load_model
from temporal_actor import load_temporal
from temporal_probe import command_schedule, physical_return
from temporal_value import actor_replay, finite_imagination, load_value


def sampled_batches(teacher, current, seed, size):
    half = size // 2
    generator = torch.Generator().manual_seed(seed)
    old = torch.randint(len(teacher[0]), (half,), generator=generator)
    new = torch.randint(len(current[0]), (size - half,), generator=generator)
    # The mixed batch exactly reconstructs the original actor trainer's first draw.
    extra = torch.Generator().manual_seed(seed + 1000000)
    extra_old = torch.randint(len(teacher[0]), (size - half,), generator=extra)
    extra_new = torch.randint(len(current[0]), (half,), generator=extra)
    return dict(teacher=tuple(torch.cat((p[old], p[extra_old])) for p in teacher),
        current=tuple(torch.cat((p[new], p[extra_new])) for p in current),
        mixed=tuple(torch.cat((a[old], b[new])) for a, b in zip(teacher, current)))


def direction(model, actor, value, batch, config):
    candidate = copy.deepcopy(actor)
    optimizer = torch.optim.Adam(candidate.parameters(), lr=config["actor_learning_rate"])
    before = finite_imagination(model, candidate, value, *batch, config)
    optimizer.zero_grad(); (-before / config["horizon"]).backward()
    norm = float(torch.nn.utils.clip_grad_norm_(candidate.parameters(), 1))
    if not np.isfinite(norm):
        raise ValueError("nonfinite replay-direction gradient")
    optimizer.step()
    original = dict(actor.named_parameters())
    delta = {name: p.detach() - original[name].detach() for name, p in candidate.named_parameters()}
    return candidate, delta, float(before.detach()), norm


def cosine(a, b):
    x, y = torch.cat([v.flatten() for v in a.values()]), torch.cat([v.flatten() for v in b.values()])
    denominator = x.norm() * y.norm()
    return float((x @ y) / denominator) if denominator > 0 else None


def run(args):
    original_config = json.loads(Path(args.config).read_bytes())
    collection = json.loads(Path(args.collection).read_bytes())
    teacher_data = json.loads(Path(args.data).read_bytes())
    probe_config = json.loads(Path(args.probe_config).read_bytes())
    torch.set_num_threads(original_config["cpu_threads"]); torch.use_deterministic_algorithms(True)
    runtime = PhysicsRuntime(args.scene, .02)
    model, _ = load_model(args.dynamics)
    for p in model.parameters():
        p.requires_grad_(False); p.grad = None
    initial_model = copy.deepcopy(model.state_dict())
    model_sha = hashlib.sha256(Path(args.dynamics).read_bytes()).hexdigest()
    cases = {c["id"]: c for c in collection["cases"] if c["split"] == "train"}
    teacher = actor_replay(runtime, teacher_data["episodes"], cases, original_config)
    teacher_digest = hashlib.sha256(b"".join(p.numpy().tobytes() for p in teacher)).hexdigest()
    output = Path(args.output); output.mkdir(parents=True, exist_ok=True)
    rows, records, bindings, alignments, saved_origins = [], [], [], [], []
    report = json.loads((Path(args.study) / "policy/report.json").read_bytes())
    maximum_restore_error = 0.0
    if teacher_digest != report["shared_teacher_points_sha256"] or model_sha != report["dynamics_sha256"]:
        raise ValueError("replay/model differ from prior temporal value study")
    for seed in original_config["seeds"]:
        source = report["runs"][seed]
        actor_path = Path(args.policies) / f"actor-seed-{seed}.pt"
        value_path = Path(args.study) / "policy" / source["checkpoint"]
        actor, _ = load_temporal(actor_path)
        value = load_value(value_path)
        metadata = torch.load(value_path, weights_only=True)
        actor_sha = hashlib.sha256(actor_path.read_bytes()).hexdigest()
        if metadata["initialization"]["critic_actor_update"] != 0 or source["initialization"]["sha256"] != actor_sha:
            raise ValueError("probe requires original actor and its initial calibrated critic")
        for p in value.parameters():
            p.requires_grad_(False); p.grad = None
        initial_value = copy.deepcopy(value.state_dict())
        stream_path = Path(args.study) / "policy" / source["critic_physics"]["file"]
        if hashlib.sha256(stream_path.read_bytes()).hexdigest() != source["critic_physics"]["sha256"]:
            raise ValueError("calibration source changed")
        with gzip.open(stream_path, "rt", encoding="utf-8") as stream:
            first = json.loads(next(stream))
        if first["actor_update"] != 0 or first["role"] != "critic-training":
            raise ValueError("missing initial training-only replay")
        current = actor_replay(runtime, first["dataset"]["episodes"], cases, original_config)
        origins = first["probe_origins"]
        tensor = lambda key: torch.tensor([o[key] for o in origins], dtype=torch.float32)
        goals = torch.tensor(np.asarray([command_schedule(runtime, o, original_config["horizon"] + 11) for o in origins]))
        common = tensor("state"), tensor("history"), goals, tensor("context"), torch.tensor([o["remaining_steps"] * .02 for o in origins])
        physical_origins = [{**o, "history": o["history"][-actor.history_length:]} for o in origins]
        baselines = []
        for origin, physical in zip(origins, physical_origins):
            baseline, states, actions = physical_return(runtime, physical, actor, original_config)
            reference = origin["reference"]
            if len(reference) != len(states) or baseline["steps"] != origin["reference_full_steps"]:
                raise ValueError("replay comparison restore length differs")
            error = max(float(np.max(np.abs(np.asarray(v) - np.asarray([s[key] for s in reference]))))
                for v, key in [(states, "next_state"), (actions, "applied_action")])
            if error > 1e-8:
                raise ValueError("replay comparison restore differs")
            maximum_restore_error = max(error, maximum_restore_error)
            baselines.append(baseline)
        saved = {}
        for draw in range(probe_config["draws"]):
            sampling_seed = original_config["sampling_seed"] + seed + draw * 10000
            batches = sampled_batches(teacher, current, sampling_seed, original_config["batch_size"])
            for bootstrap in [False, True]:
                config = {**original_config, "actor_critic_bootstrap": bootstrap}
                directions = {}
                with torch.no_grad():
                    common_before = float(finite_imagination(model, actor, value, *common, config))
                for distribution, batch in batches.items():
                    candidate, delta, fit_before, norm = direction(model, actor, value, batch, config)
                    directions[distribution] = delta
                    saved[f"draw-{draw}-tail-{bootstrap}-{distribution}"] = delta
                    with torch.no_grad():
                        fit_after = float(finite_imagination(model, candidate, value, *batch, config))
                        common_after = float(finite_imagination(model, candidate, value, *common, config))
                    first_update_match = None
                    if draw == 0 and bootstrap and distribution == "mixed" and source["selected_update"] == 1:
                        actual, _ = load_temporal(value_path)
                        first_update_match = all(torch.equal(p, actual.state_dict()[k]) for k, p in candidate.state_dict().items())
                        if not first_update_match:
                            raise ValueError("reconstructed mixed first update differs from saved actor")
                    outcomes = [physical_return(runtime, origin, candidate, config)[0] for origin in physical_origins]
                    for i, (before, after) in enumerate(zip(baselines, outcomes)):
                        records.append(dict(seed=seed, draw=draw, tail=bootstrap, distribution=distribution,
                            origin=i, baseline=before, candidate=after))
                    for subset in ["all", "dynamic", "stand"]:
                        ids = [i for i, o in enumerate(origins) if subset == "all" or
                            subset == "dynamic" and o["case"]["motion"] == "random_joint_sines" or
                            subset == "stand" and o["case"]["motion"] == "stand"]
                        mean = lambda values: float(np.mean(values)) if values else None
                        row = dict(seed=seed, draw=draw, sampling_seed=sampling_seed, tail=bootstrap, distribution=distribution,
                            subset=subset, origins=len(ids), gradient_norm=norm,
                            predicted_fit_change=fit_after - fit_before, predicted_origins_change=common_after - common_before,
                            local_physical_change=mean([outcomes[i]["local_return"] - baselines[i]["local_return"] for i in ids]),
                            full_physical_change=mean([outcomes[i]["full_return"] - baselines[i]["full_return"] for i in ids]),
                            mean_steps_change=mean([outcomes[i]["steps"] - baselines[i]["steps"] for i in ids]),
                            full_improves_fraction=mean([outcomes[i]["full_return"] > baselines[i]["full_return"] for i in ids]),
                            reconstructed_saved_update_matches=first_update_match)
                        rows.append(row)
                        if subset == "all":
                            print(json.dumps(row), flush=True)
                alignments.append(dict(seed=seed, draw=draw, tail=bootstrap,
                    teacher_current_cosine=cosine(directions["teacher"], directions["current"]),
                    teacher_mixed_cosine=cosine(directions["teacher"], directions["mixed"]),
                    current_mixed_cosine=cosine(directions["current"], directions["mixed"])))
        torch.save(dict(directions=saved, actor_sha256=actor_sha, value_sha256=hashlib.sha256(value_path.read_bytes()).hexdigest()),
            output / f"directions-seed-{seed}.pt")
        if any(not torch.equal(v, value.state_dict()[k]) for k, v in initial_value.items()) or any(p.grad is not None for p in value.parameters()):
            raise ValueError("probe changed frozen value model")
        bindings.append(dict(seed=seed, actor_sha256=actor_sha, value_checkpoint_sha256=hashlib.sha256(value_path.read_bytes()).hexdigest(),
            critic_actor_update=0, training_record_sha256=hashlib.sha256(json.dumps(first["dataset"], allow_nan=False).encode()).hexdigest(),
            current_actor_starts=len(current[0]), teacher_actor_starts=len(teacher[0]), origins=len(origins)))
        saved_origins.append(dict(seed=seed, origins=origins))
    if any(not torch.equal(v, model.state_dict()[k]) for k, v in initial_model.items()) or any(p.grad is not None for p in model.parameters()):
        raise ValueError("probe changed frozen dynamics")
    summary = dict(format="moonrobo.g1-replay-direction-probe.v1", config=probe_config, actor_config=original_config,
        dynamics_sha256=model_sha, teacher_points_sha256=teacher_digest, bindings=bindings, summaries=rows,
        parameter_direction_alignment=alignments, maximum_restore_error=maximum_restore_error,
        frozen_models_unchanged=True, physical_execution_allowed=False,
        scope="Same incoming actors, initial calibrated value, world model and physical origins. Teacher/current/mixed distributions at fixed batch size; three coupled draws, both value-tail flags. Draw-zero mixed reconstructs the original first training minibatch. Physical full returns end at actual fall/original task end; correlated origins and repeated actors are not qualification trials.")
    (output / "report.json").write_text(json.dumps(dict(**summary, origins=saved_origins, records=records), indent=2, allow_nan=False))
    (output / "summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["config", "probe-config", "collection", "data", "policies", "study", "dynamics", "scene", "output"]:
        parser.add_argument("--" + name, required=True)
    run(parser.parse_args())
