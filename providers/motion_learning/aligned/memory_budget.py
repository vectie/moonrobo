"""Fail-fast memory planning for the optional aligned CUDA trainer.

These are deliberately conservative *planning envelopes*, not measured PyTorch
peaks. GB10 uses one pool of system/GPU memory, and Warp/Newton allocations are
outside PyTorch's allocator. A full-scale run must be promoted after measured
smaller runs; it must never be inferred safe merely because ``mem_get_info``
looks large before the scene is built.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
from pathlib import Path

GIB = 1 << 30
CONTROL_DT = 0.02
OBS_DIMS = {"paper": 93, "smc": 99, "observable": 102}

# See buffer.FIELDS. The three one-byte fields are done/terminated/truncated.
REPLAY_BYTES_PER_TRANSITION = 2 * 71 * 4 + 2 * 29 * 4 + 33 * 4 + 4 + 8 + 4 + 3
# MotionLib eager fields: root p/R/v/w/q/qd, 14 tracked p/R/v/w,
# local root v/w and projected gravity, plus clip_id/frame_bin int64 indexes.
EAGER_REFERENCE_BYTES_PER_FRAME = (76 + 14 * 18 + 7) * 4 + 2 * 8
# The mmap implementation stores root values on disk. Count all mapped pages
# as resident anyway; Linux can reclaim them, but that is not a safe promise.
MMAP_REFERENCE_BYTES_PER_FRAME = 332 + 2 * 8


class MemoryBudgetError(RuntimeError):
    """Configuration is unsafe to start on the currently available memory."""


@dataclass(frozen=True)
class MotionSize:
    source_frames: int
    resampled_frames: int
    largest_source_clip: int
    clips: int


@dataclass(frozen=True)
class MemoryEstimate:
    motion: MotionSize
    reference_storage: str
    free_bytes: int
    budget_bytes: int
    peak_bytes: int
    components: dict[str, int]

    def as_dict(self) -> dict:
        return {
            "motion": vars(self.motion), "reference_storage": self.reference_storage,
            "free_gib": round(self.free_bytes / GIB, 2),
            "budget_gib": round(self.budget_bytes / GIB, 2),
            "peak_planning_gib": round(self.peak_bytes / GIB, 2),
            "components_gib": {k: round(v / GIB, 2) for k, v in self.components.items()},
            "estimate_only": True,
        }


def _csv_rows(path: Path) -> int:
    rows = 0
    last = b""
    with path.open("rb") as stream:
        while chunk := stream.read(4 * 1024 * 1024):
            rows += chunk.count(b"\n")
            last = chunk[-1:]
    return rows + (last not in (b"", b"\n"))


def _resampled_frames(source_frames: int, fps: float) -> int:
    if source_frames < 2 or not math.isfinite(fps) or fps <= 0:
        raise MemoryBudgetError("motion clips need at least two rows and finite positive FPS")
    return int(math.floor(((source_frames - 1) / fps) / CONTROL_DT)) + 1


def motion_size(motion_dir: str | Path, *, manifest_path: str | Path | None = None) -> MotionSize:
    """Count actual CSV rows without loading tensors; manifest counts are not trusted."""
    root = Path(motion_dir)
    if manifest_path is None:
        files = sorted(root.glob("*.csv"))
        fps = 30.0  # MotionLib.from_dir default
    else:
        path = Path(manifest_path)
        manifest = json.loads(path.read_text())
        if manifest.get("format") != "moonrobo.aligned-motion-catalog.v1":
            raise MemoryBudgetError("unsupported motion manifest")
        by_id = {row["id"]: row for row in manifest["clips"]}
        files = [path.parent / by_id[name]["path"] for name in manifest["splits"]["train"]]
        fps = float(manifest["source_fps"])
    if not files:
        raise MemoryBudgetError("no G1 CSV motion clips available for memory preflight")
    source_counts = [_csv_rows(path) for path in files]
    return MotionSize(sum(source_counts), sum(_resampled_frames(n, fps) for n in source_counts),
                      max(source_counts), len(files))


def host_available_memory_bytes() -> int | None:
    """Linux MemAvailable, bounded by an active cgroup memory limit."""
    path = Path("/proc/meminfo")
    if not path.is_file():
        return None
    fields = {parts[0].rstrip(":"): int(parts[1]) * 1024
              for line in path.read_text().splitlines() if len(parts := line.split()) >= 2}
    available = fields.get("MemAvailable")
    if available is None:
        return None
    max_path, used_path = Path("/sys/fs/cgroup/memory.max"), Path("/sys/fs/cgroup/memory.current")
    if max_path.is_file() and used_path.is_file():
        raw = max_path.read_text().strip()
        if raw != "max":
            available = min(available, max(0, int(raw) - int(used_path.read_text().strip())))
    else:
        max_path = Path("/sys/fs/cgroup/memory/memory.limit_in_bytes")
        used_path = Path("/sys/fs/cgroup/memory/memory.usage_in_bytes")
        if max_path.is_file() and used_path.is_file():
            limit = int(max_path.read_text().strip())
            if limit < (1 << 60):  # cgroup v1's effectively-unlimited sentinel
                available = min(available, max(0, limit - int(used_path.read_text().strip())))
    return available


def host_memory_observation() -> dict:
    """Read cgroup/host evidence without equating it with total CUDA usage."""
    evidence = {"host_available_bytes": host_available_memory_bytes()}
    for key, name in (("cgroup_current_bytes", "memory.current"),
                      ("cgroup_peak_bytes", "memory.peak")):
        path = Path("/sys/fs/cgroup") / name
        if path.is_file():
            raw = path.read_text().strip()
            if raw.isdecimal():
                evidence[key] = int(raw)
    events = Path("/sys/fs/cgroup/memory.events")
    if events.is_file():
        evidence["cgroup_events"] = {key: int(value) for key, value in
                                     (line.split() for line in events.read_text().splitlines())}
    evidence["scope"] = "host/cgroup accounting; not a complete unified GPU memory peak"
    return evidence


def _mlp_params(input_dim: int, hidden: list[int] | tuple[int, ...], output_dim: int,
                layer_norm: bool = False) -> int:
    dims = [input_dim, *hidden, output_dim]
    return sum((left + 1) * right for left, right in zip(dims, dims[1:])) + (
        sum(2 * width for width in hidden) if layer_norm else 0)


def estimate_training_memory(config: dict, size: MotionSize, *, device_free_bytes: int,
                             host_free_bytes: int, reference_storage: str = "eager") -> MemoryEstimate:
    if device_free_bytes <= 0 or host_free_bytes <= 0:
        raise MemoryBudgetError("memory availability is unknown or exhausted; refuse CUDA training")
    if reference_storage not in ("eager", "mmap"):
        raise MemoryBudgetError(f"unknown reference storage mode: {reference_storage}")
    free = min(device_free_bytes, host_free_bytes)
    n, replay_steps = int(config["num_envs"]), int(config.get("buffer_steps", 1000))
    pi_batch, wm_batch = int(config.get("pi_batch", 4096)), int(config.get("wm_batch", 2048))
    horizon, wm_window = int(config.get("horizon", 32)), int(config.get("wm_window", 8))
    hist, goals = int(config.get("hist", 10)), int(config.get("goal_frames", 10))
    if min(n, replay_steps, pi_batch, wm_batch, horizon, wm_window, hist, goals) < 1:
        raise MemoryBudgetError("all training dimensions must be positive")
    obs_dim = OBS_DIMS[config.get("observation_mode", "paper")]
    wm_hidden = config.get("wm_hidden", (2048, 2048, 2048))
    pi_hidden = config.get("pi_hidden", (2048, 1024, 512, 256))
    critic_hidden = config.get("critic_hidden", (256, 128))
    goal_dim = goals * 73
    params = (_mlp_params(133, wm_hidden, 70, True)
              + _mlp_params(goal_dim, pi_hidden, 32)
              + _mlp_params(32 + obs_dim * hist, pi_hidden, 29)
              + _mlp_params(71 + 113 + goal_dim, critic_hidden, 1))
    reference = size.resampled_frames * (EAGER_REFERENCE_BYTES_PER_FRAME if reference_storage == "eager"
                                         else MMAP_REFERENCE_BYTES_PER_FRAME)
    replay = replay_steps * n * REPLAY_BYTES_PER_TRANSITION
    components = {
        "reference_resident_envelope": reference,
        "replay_plus_checkpoint_copies": 3 * replay,
        "parameters_gradients_adam_and_allocator": params * 16 + 512 * 1024**2,
        "history_and_live_environment": n * hist * obs_dim * 4 + n * 1024**2,
        # Planning envelopes include saved MLP activations, recurrent state,
        # rotations, analytic FK/reward, and PyTorch autograd bookkeeping.
        "actor_bptt_envelope": horizon * pi_batch * 256 * 1024,
        "world_model_bptt_envelope": wm_window * wm_batch * 128 * 1024,
        # Newton/Warp allocations are not visible to torch's allocator. This
        # reserve is a lower bound to be refined from staged measurements.
        "newton_warp_scene_reserve": 24 * GIB,
    }
    steady = sum(components.values())
    construction_extra = (448 * size.resampled_frames + 768 * size.largest_source_clip
                          if reference_storage == "eager" else max(1 * GIB, 768 * size.largest_source_clip))
    components["reference_construction_extra"] = construction_extra
    peak = max(steady, reference + construction_extra + components["newton_warp_scene_reserve"])
    return MemoryEstimate(size, reference_storage, free, int(free * 0.65), peak, components)


def check_training_memory(config: dict, motion_dir: str | Path, *, device_free_bytes: int | None,
                          host_free_bytes: int | None = None, manifest_path: str | Path | None = None,
                          reference_storage: str = "eager") -> MemoryEstimate:
    """Refuse unmeasured scale or estimated >65% of available unified memory.

    Call before constructing MotionLib, ReplayBuffer, networks or the GPU scene.
    ``device_free_bytes`` must come from CUDA's free-memory query, not total
    physical memory. Each distributed rank performs its own check.
    """
    if device_free_bytes is None:
        raise MemoryBudgetError("CUDA free-memory query is required for safe training")
    if host_free_bytes is None:
        host_free_bytes = host_available_memory_bytes()
    if host_free_bytes is None:
        raise MemoryBudgetError("host available-memory query is required for safe training")
    size = motion_size(motion_dir, manifest_path=manifest_path)
    result = estimate_training_memory(config, size, device_free_bytes=device_free_bytes,
                                      host_free_bytes=host_free_bytes,
                                      reference_storage=reference_storage)
    if reference_storage == "mmap":
        gather_cap = int(config.get("max_reference_gather_frames", 131072))
        required = max(int(config["num_envs"]),
                       (int(config.get("horizon", 32)) + 1) * int(config.get("pi_batch", 4096)))
        if gather_cap < required:
            raise MemoryBudgetError(
                f"max_reference_gather_frames={gather_cap} is below required batch {required}")
    # We have no measured Isaac/Newton memory slope for these machines yet.
    # Promotion beyond this stage needs a later change backed by actual peaks.
    if (int(config["num_envs"]) > 512 or int(config.get("pi_batch", 4096)) > 512
            or int(config.get("wm_batch", 2048)) > 512):
        raise MemoryBudgetError(
            "unmeasured >512 environment/actor/model batch scale is disabled; "
            f"stage at <=512 first; estimate={result.as_dict()}")
    if result.peak_bytes > result.budget_bytes:
        raise MemoryBudgetError(f"memory planning budget exceeded: {result.as_dict()}")
    return result
