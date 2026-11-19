"""Full-clip evaluation and explicit accounting for the aligned baseline.

Appendix F.1 specifies deterministic rollouts from frame zero, without domain
randomization or noise. The return denominator is the maximum reward over the
*entire* reference, including the unplayed remainder after a failure. Both the
equal-motion mean and the frame-weighted mean are retained, as in smc's evaluator.
The old strict tracking limits are optional, separate engineering criteria.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import math
from typing import Mapping, Sequence

import torch


STRICT_RMSE_LIMITS = {
    "joint_rmse_rad": 0.03,
    "body_position_rmse_m": 0.05,
    "root_position_rmse_m": 0.05,
    "root_orientation_rmse_rad": 0.1,
}


@dataclass
class ClipEvaluation:
    clip_id: str
    expected_steps: int
    rewards: Sequence[float]
    terminated: bool
    strict_rmse: Mapping[str, float] | None = None
    termination_frame: int | None = None
    metadata: dict = field(default_factory=dict)


def summarize_evaluations(
    trials: Sequence[ClipEvaluation], *, max_step_reward: float = 0.1,
    expected_clip_ids: Sequence[str] | None = None,
) -> dict:
    """Aggregate whole clips without dropping early failures or clipping rewards.

Negative normalized returns are valid: action and joint-limit penalties are
unbounded below. A non-terminal early timeout is a protocol violation rather
than a successful motion. `benchmark_complete` also checks requested coverage.
    """
    if not trials or not math.isfinite(max_step_reward) or max_step_reward <= 0:
        raise ValueError("evaluation needs trials and a finite positive reward maximum")
    names = [trial.clip_id for trial in trials]
    if len(set(names)) != len(names):
        raise ValueError("evaluate each clip exactly once")
    if expected_clip_ids is not None and len(set(expected_clip_ids)) != len(expected_clip_ids):
        raise ValueError("expected clip IDs must be unique")
    rows = []
    for trial in trials:
        rewards = [float(value) for value in trial.rewards]
        if trial.expected_steps < 1 or len(rewards) > trial.expected_steps:
            raise ValueError("invalid full-clip transition count")
        if not all(math.isfinite(value) for value in rewards):
            raise ValueError("nonfinite evaluation reward")
        complete = len(rewards) == trial.expected_steps
        row = {
            "clip_id": trial.clip_id,
            "expected_steps": trial.expected_steps,
            "executed_steps": len(rewards),
            "undiscounted_return": math.fsum(rewards),
            "maximum_full_clip_return": trial.expected_steps * max_step_reward,
            "normalized_return": math.fsum(rewards) / (trial.expected_steps * max_step_reward),
            "failed": bool(trial.terminated),
            "completed_full_duration": complete,
            "protocol_complete": complete or bool(trial.terminated),
            "termination_frame": trial.termination_frame,
            "metadata": dict(trial.metadata),
        }
        if trial.strict_rmse is not None:
            metrics = {key: float(value) for key, value in trial.strict_rmse.items()}
            if not all(math.isfinite(value) and value >= 0 for value in metrics.values()):
                raise ValueError("strict tracking metrics must be finite nonnegative RMSE")
            row["strict_tracking"] = {
                "rmse": metrics,
                "limits": dict(STRICT_RMSE_LIMITS),
                "passed": complete and not trial.terminated and all(
                    key in metrics and metrics[key] <= limit
                    for key, limit in STRICT_RMSE_LIMITS.items()
                ),
            }
        rows.append(row)
    requested = list(expected_clip_ids) if expected_clip_ids is not None else names
    failed = [row["clip_id"] for row in rows if row["failed"]]
    incomplete = [row["clip_id"] for row in rows if not row["protocol_complete"]]
    strict_rows = [row["strict_tracking"] for row in rows if "strict_tracking" in row]
    return {
        "format": "moonrobo.supermimic-full-clip-evaluation.v1",
        "protocol": {
            "start_frame": 0,
            "requested_horizon": "entire clip, no episode time limit",
            "failure": "hard reference-relative training termination",
            "normalization": "sum reward / ((frame_count - 1) * max_step_reward)",
            "max_step_reward": max_step_reward,
            "aggregation": "equal clip mean; separate frame-weighted mean",
            "strict_tracking_is_separate": True,
        },
        "n_clips": len(rows),
        "norm_return": math.fsum(row["normalized_return"] for row in rows) / len(rows),
        "norm_return_framew": math.fsum(row["undiscounted_return"] for row in rows)
        / math.fsum(row["maximum_full_clip_return"] for row in rows),
        "n_failed": len(failed),
        "failed": failed,
        "n_completed": sum(row["completed_full_duration"] for row in rows),
        "incomplete_protocol_clips": incomplete,
        "missing_clips": sorted(set(requested) - set(names)),
        "unexpected_clips": sorted(set(names) - set(requested)),
        "benchmark_complete": not incomplete and set(requested) == set(names),
        "evaluation_physical_steps": sum(row["executed_steps"] for row in rows),
        "strict_tracking": {
            "evaluated_clips": len(strict_rows),
            "passed_clips": sum(row["passed"] for row in strict_rows),
            "all_passed": len(strict_rows) == len(rows) and all(row["passed"] for row in strict_rows),
            "interpretation": "additional engineering gate; not the paper's failure count",
        },
        "per_clip": rows,
    }


def _tracking_squared_errors(env, state, frame: torch.Tensor) -> dict[str, float]:
    if isinstance(state, torch.Tensor):
        from .mdp import unflatten_state

        state = unflatten_state(state)
    p, rotation, velocity, angular_velocity, joints, joint_velocity = state
    motion = env.mdp.motion
    body_position = env.mdp.kin.forward(
        p, rotation, velocity, angular_velocity, joints, joint_velocity
    )[0]
    relative_rotation = rotation.transpose(-1, -2) @ motion.root_R[frame]
    cosine = ((relative_rotation.diagonal(dim1=-2, dim2=-1).sum(-1) - 1) / 2).clamp(-1, 1)
    return {
        "joint_rmse_rad": float((joints - motion.q[frame]).square().mean()),
        "body_position_rmse_m": float((body_position - motion.body_p[frame]).square().sum(-1).mean()),
        "root_position_rmse_m": float((p - motion.root_p[frame]).square().sum(-1).mean()),
        "root_orientation_rmse_rad": float(torch.acos(cosine).square().mean()),
    }


@torch.no_grad()
def evaluate_policy(
    env, policy, *, hist: int = 10, goal_frames: int = 10,
    max_step_reward: float = 0.1, clip_indices: Sequence[int] | None = None,
    strict_tracking: bool = True,
) -> dict:
    """Evaluate a deterministic policy in a single-environment physical adapter.

The environment must expose the same state/MDP/frame interface as the aligned
learner. It must be constructed with `eval_mode=True, auto_reset=False` and
disable its training timeout. Tests of the aggregator alone do not certify those
physical settings; the actual environment supplies them in `evaluation_settings`.
    """
    if not getattr(env, "eval_mode", False) or getattr(env, "auto_reset", True):
        raise ValueError("evaluation requires eval_mode=True and auto_reset=False")
    if env.f.numel() != 1 or hist < 1 or goal_frames < 1:
        raise ValueError("sequential evaluation requires one environment and positive context lengths")
    motion = env.mdp.motion
    selected = list(range(len(motion.names))) if clip_indices is None else list(clip_indices)
    if not selected or len(set(selected)) != len(selected):
        raise ValueError("select distinct, nonempty evaluation clips")
    if any(index < 0 or index >= len(motion.names) for index in selected):
        raise ValueError("evaluation clip index out of range")
    was_training = policy.training
    policy.eval()
    trials = []
    try:
        for index in selected:
            start = int(motion.clip_start[index])
            expected_steps = int(motion.clip_len[index]) - 1
            env.reset(frames=torch.tensor([start], dtype=torch.long, device=env.f.device))
            history = None
            rewards, squared_errors = [], []
            terminated, termination_frame = False, None
            for _ in range(expected_steps):
                observation = env.mdp.obs(env.state(), env.a_prev, env.xi, env.f)
                history = observation.unsqueeze(1).repeat(1, hist, 1) if history is None else torch.cat(
                    (history[:, 1:], observation.unsqueeze(1)), dim=1
                )
                action = policy(history, motion.goal(env.f, goal_frames))
                out = env.step(action)
                rewards.append(float(out["r"].reshape(-1)[0]))
                if strict_tracking:
                    squared_errors.append(_tracking_squared_errors(env, out["s1"], out["f"] + 1))
                terminated = bool(out["term"].reshape(-1)[0])
                if terminated:
                    termination_frame = len(rewards)
                if terminated or bool(out["done"].reshape(-1)[0]):
                    break
            metrics = None
            if squared_errors:
                metrics = {
                    key: math.sqrt(math.fsum(row[key] for row in squared_errors) / len(squared_errors))
                    for key in STRICT_RMSE_LIMITS
                }
            trials.append(ClipEvaluation(
                motion.names[index], expected_steps, rewards, terminated, metrics,
                termination_frame, {"clip_index": index, "start_frame": 0},
            ))
    finally:
        policy.train(was_training)
    report = summarize_evaluations(
        trials, max_step_reward=max_step_reward,
        expected_clip_ids=[motion.names[index] for index in selected],
    )
    settings = dict(getattr(env, "evaluation_settings", {}))
    report["protocol"]["physical_settings"] = settings
    report["evaluation_simulated_physical_steps"] = (
        report["evaluation_physical_steps"] * int(settings.get("simulated_replica_count", 1))
    )
    report["catalog_clip_count"] = len(motion.names)
    report["full_catalog_evaluated"] = len(selected) == len(motion.names) and report["benchmark_complete"]
    return report
