# Native training optimization pairs

The two `.mbtx` tools preserve the original implementation and compare explicit,
single-option candidates in independent processes. They do not select a winner,
increase a batch, relax a numerical tolerance, or establish paper convergence.

Implementation order is timing decomposition, reference/robot geometry reuse,
critic normalization reuse and native LayerNorm; graph replay and two-node
communication follow after these have measured evidence. The current launcher
supports the first group and an isolated critic CUDA-graph candidate on the
verified N256 setup. Whole actor/world capture and two-node training are separate
contracts; this launcher does not implement them.
Use the dedicated coordinated DDP launcher for two-rank experiments; launching
two independent single-node processes does not test DDP.

## Frozen experiment spec

`run_native_optimization_pairs.mbtx --prepare SPEC_JSON FRESH_ABSOLUTE_DIR`
validates the spec and writes an immutable `spec.json` plus `plan.json`. It does
not touch Docker or the GPU. `--plan ROOT` displays the saved plan.

The scripts pin the deployed `moonbitlang/async@0.20.2`. Run the launcher with
`--target native` because that dependency's canonical-path API is native-only.
Process launch uses direct argv, bounded pipes and async timeouts; it does not
depend on the newer `async/shell` package.

The spec has this structure (replace every `PIN` with the actual frozen hash):

```json
{
  "format": "moonrobo.native-optimization-pairs.spec.v1",
  "stage": "geometry",
  "repo": "/home/wlc004s/moonrobo",
  "image_id": "sha256:PIN",
  "motion_cache_relative_path": "private/native-paper-tf32-reference-cache-20261024-a",
  "mujoco_library": "/opt/isaaclab-venv/lib/python3.12/site-packages/mujoco/libmujoco.so.3.15.0",
  "mujoco_library_sha256": "PIN",
  "files": {
    "trainer": {"relative_path": "private/FROZEN_NEW_BUILD/trainer", "sha256": "PIN"},
    "tensor_library": {"relative_path": "private/FROZEN_NEW_BUILD/libmoonrobo_learning_tensor.so", "sha256": "PIN"},
    "physics_library": {"relative_path": "private/apic-paper-capacity-runtime-20261024-a/libmoonrobo_aligned_apic.so", "sha256": "PIN"},
    "scene": {"relative_path": "data/g1_description-paper-self-collision/scene.xml", "sha256": "PIN"},
    "manifest": {"relative_path": "data/manifest.json", "sha256": "PIN"},
    "physics_artifact": {"relative_path": "runs/apic-paper-n256-20261024-c/g1-paper-n256-self-collision-apic/manifest.json", "sha256": "PIN"}
  },
  "baseline_config": {},
  "candidate_config": {},
  "warmup_iterations": 1,
  "abba_blocks": 1,
  "timeout_seconds": 600,
  "execution_profile": false
}
```

Use the complete
`examples/learning/g1-native-tensor-paper-n256-b2048-b4096-util80-wm2048-pi512.json`
as `baseline_config`, with all implementation switches absent or explicitly
off/expanded. Copy that object into `candidate_config` and change exactly one:

Alternatively save only the `repo`, `image_id`, cache/MuJoCo fields and `files`
object as a pins JSON, then generate a validated spec without a GPU operation:

```text
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --make-spec BASE_CONFIG_JSON STAGE PINS_JSON FRESH_SPEC_JSON
```

The generator defaults to one ABBA block, one excluded initial iteration and a
600-second per-process deadline. `timing` sets `profile_max_spans: 65536` in both
configs and enables the separate diagnostic flag; other stages leave profiling
off. A caller may edit the fresh spec before `--prepare` freezes it.

| Stage | Candidate change |
|---|---|
| `timing` | No config change; use `execution_profile: true` for a diagnostic series |
| `geometry` | `reuse_geometry: true` |
| `critic-normalization` | `reuse_critic_normalization: true` |
| `layer-norm` | `layer_norm_mode: "native"` |
| `critic-cuda-graph` (alias `critic_cuda_graph`) | `critic_cuda_graph: true` |

The validator treats omitted switches as `false`, `false`, `"expanded"`, and
`critic_cuda_graph: false`.
All other fields, including seed, learning rate, environment count, physical
parameters, batches/microbatches, precision, model shape and schedule must match
exactly. N256, world batch/microbatch 2048, actor batch4096/microbatch512, ten
world updates, twenty critic updates, 32 imagined steps and 8 world-model steps
are fixed in this launcher. Iterations may be 4–30, with only one checkpoint at
the end. Use identical iteration counts for both variants; warmup exclusion must
be at least one iteration and smaller than the iteration count.

Freeze **one new trainer and tensor library for both sides**. The old measured
`native-paper-batch-20261024-d` result is historical context, not one side of the
new comparison. This isolates the selected execution option from unrelated
source changes. Physics/data/image/binary hashes are pinned; runtime report
identities are verified again by the summarizer.

For the critic graph stage, supply fresh **stage-2 trainer and tensor-library
pins** supporting graph capture. Both sides must use those same binaries, with
all other execution options off. Before training, the launcher reads the bounded
preflight JSON and requires `critic_cuda_graph_capability.available: true` and
the matching `requested` flag, including the eager baseline. It retains a hashed
`graph-preflight-evidence.json`. Earlier stages remain compatible with their
original preflight reports, which need not contain this new field.

```text
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --make-spec BASE_CONFIG_JSON critic-cuda-graph STAGE2_PINS_JSON FRESH_GRAPH_SPEC_JSON
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --prepare FRESH_GRAPH_SPEC_JSON FRESH_GRAPH_ROOT
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --plan FRESH_GRAPH_ROOT
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --run-range FRESH_GRAPH_ROOT 0 4
moon run --target native scripts/summarize_native_optimization_pairs.mbtx -- FRESH_GRAPH_ROOT FRESH_GRAPH_SUMMARY_JSON
```

The current isolated protocol expects zero captures/replays on the baseline,
one capture per candidate iteration and one replay per critic minibatch update
(10 captures and 200 replays for the ten-iteration recipe). Runtime counters must
show that the route actually executed; private graph-pool reservation must stay
within its 1 GiB budget, in addition to the unchanged admission and 16 GiB reserve.
The summary records static/gradient/private-pool peaks and still requires separate
gradient/parameter/Adam-state equivalence evidence. Adam remains outside capture.
No graph speedup or DDP-training claim follows from preparation or capability.

## One bounded run at a time

```text
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --prepare SPEC_JSON FRESH_ABSOLUTE_DIR
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --plan ROOT
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --run ROOT 0
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --run ROOT 1
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --run ROOT 2
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --run ROOT 3
```

`abba_blocks: 1` produces baseline, candidate, candidate, baseline; two blocks
produce eight runs. Run another block when needed to assess noise, not to discard
an unfavorable first block. Each `--run` starts one fresh preflight container,
then one fresh training container only if preflight succeeds. No checkpoint is
resumed and no process inherits the previous run's model or optimizer. The fixed
seed repeats initialization/sampling, but GPU floating-point equality is a
separate verification, not assumed here.

To run an explicit remaining range sequentially after run 0 completes:

```text
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --run-range ROOT 1 4
```

`END` is exclusive and cannot exceed `4 * abba_blocks`. The launcher checks that
every requested run directory is fresh before starting the range, then calls
the same `--run` implementation sequentially. It stops on the first failure and
never skips, resumes, overwrites, retries, or launches two training processes
concurrently. Keep the literal `--` separator: script flags such as `--profile`
otherwise collide with Moon's own command-line options.

The trainer runs through direct argv, never through a shell. Each container has
100 GiB memory, equal memory+swap limits (zero container swap allowance), 12 CPU,
1024 PID limit and no network. The repo and source dataset remain read-only. The
motion cache is a separate read-write mount because the existing validated cache
reader creates/acquires each `.f64.lock`, even for pre-populated shards. The fresh
run directory is also writable. Existing actual-free admission at 80% and the 16 GiB
CUDA reserve remain enabled. These are limits and sampled checks, not an absolute
guarantee against an OOM caused by unmodeled allocations or external load.

The launcher hashes inputs before starting. The image pins the bundled MuJoCo
library; the training identity verifies its expected SHA. Preflight runs again
for every repetition. A failed or incomplete run prevents the next index from
launching. There is no automatic retry, batch expansion, fallback option or cache
eviction. Failure logs, Docker inspection, exit/OOM state, and stopped containers
are retained. An attach timeout stops that container, preserving its identity.
Inspect actual free memory and enforce a single training owner before invoking a
run; the script does not coordinate with unrelated jobs on the machine.

The cache must already contain all required reference shards. Populate
it separately with the existing bounded cache preparation path. Do not turn
cache generation into an uncontrolled part of a throughput run. Cache validation
and locking remain enabled. A previous read-only mount failed at the lock-file
open before training; retain that failed series and use a fresh series for this
launcher revision rather than rewriting its evidence.

## Idle, targeted checkpoint cache advice

If accumulated completed checkpoints reduce actual available memory enough to
reject a later preflight, preserve that rejected series. Do not raise the budget.
The separate `advise_optimization_checkpoint_cache.mbtx` helper can advise clean
file-cache pages belonging only to explicitly named, successfully completed
optimization runs on 179:

```text
moon run --target native scripts/advise_optimization_checkpoint_cache.mbtx -- --plan FRESH_PLAN_JSON /home/wlc004s/moonrobo/runs/SERIES/run-0 /home/wlc004s/moonrobo/runs/SERIES/run-1
moon run --target native scripts/advise_optimization_checkpoint_cache.mbtx -- --advise FRESH_ADVICE_JSON /home/wlc004s/moonrobo/runs/SERIES/run-0 /home/wlc004s/moonrobo/runs/SERIES/run-1
```

Both modes validate successful `result.json`, complete training report, stopped
non-OOM Docker evidence, and identical published `current.json`/generation
`receipt.json`/report checkpoint metadata. Training locks remain held throughout.
Every selected file comes from that current generation's receipt inventory;
older generations, failed runs, partial directories, source datasets, motion
reference cache and CUDA ComputeCache are excluded. At most 16 run paths,
1,024 files and 64 GiB of existing file sizes may be selected.

The helper requires an idle local Docker daemon and rechecks before each
file-specific operation. It first runs GNU `sync --data -- FILE` with a 30-second
timeout, then GNU `dd iflag=nocache,nofollow count=0`. Sync flushes any previously
dirty file data to storage so cache advice can act on clean pages; it does not
change file content. Successful data-sync and advice operations are recorded
separately, including when a later operation fails. The helper reads only bounded
metadata and file sizes, not model/replay payloads or their hashes. It does not
delete or modify payload contents, lower guards, or invoke global sync/cache
operations.
The report distinguishes advised file sizes from actual reclaim, which is not
guaranteed. Keep the advice report and require fresh actual-free admission before
starting a new series. Apply the same cache-control protocol to both variants;
this helper does not coordinate or change the active ABBA schedule.

The explicit `--plan-completed-postvalidation-failure` and
`--advise-completed-postvalidation-failure` modes additionally admit a completed
training run whose paired result failed only with the exact historical
`run_native_optimization_pairs.mbtx:17:5-17:34` missing-`format` parser error.
All complete-training, committed-checkpoint, stopped/non-OOM Docker and lock
checks still apply. Ordinary modes continue to reject every `passed: false`
result. The exception records `paired_run_passed: false` and separate cache
eligibility; it never changes the failed paired result or makes it usable for a
performance comparison. Unrelated errors and incomplete training remain rejected.

For cache left in a completed training container's writable layer, the separate
`advise_optimization_container_cache.mbtx` accepts only explicit passed run paths:

```text
moon run --target native scripts/advise_optimization_container_cache.mbtx -- --plan /home/wlc004s/moonrobo/runs/FRESH_PLAN.json /home/wlc004s/moonrobo/runs/SERIES/run-0
moon run --target native scripts/advise_optimization_container_cache.mbtx -- --advise /home/wlc004s/moonrobo/runs/FRESH_ADVICE.json /home/wlc004s/moonrobo/runs/SERIES/run-0
```

The host must be able to verify the canonical source directory under Docker's
`overlay2/<64-hex-id>/diff/home/isaaclab/.nv/ComputeCache`. If ordinary user access
is denied, compile this fixed helper as that user and run the compiled executable
under sudo with the same arguments; do not grant broad directory access. Existing
run locks are opened without truncation or creation and are not changed. Only a
fresh audit JSON is written, so a sudo invocation creates a root-owned report.

It checks spec/config hashes, passed run/training evidence, committed checkpoint,
exact stopped container ID/image/command and run bind ownership. Each cache is
mounted read-only into a separate CPU-only audit container using the same pinned
image, explicit `runc`, uid/gid 1000, no network, no capabilities, read-only root,
256 MiB memory, zero swap and one CPU. No other host directory is mounted. Bounded
GNU find metadata rejects symlinks, special files, hard-linked payloads, unsafe
names, excessive depth and more than 512 files/4 GiB per cache. Operations have
30-second timeouts; the worker has an 1,800-second lifetime. File-specific data
sync precedes advice and both are recorded. The workers are stopped and retained
for inspection. No files are deleted or content-modified, no GPU is requested,
and no global cache/sync operation is used. Reclaim is not guaranteed; admission
must use fresh actual memory measurements afterward. This tool does not broaden
the checkpoint helper's scope or make any failed performance run pass.

## Reporting and acceptance

```text
moon run --target native scripts/summarize_native_optimization_pairs.mbtx -- ROOT FRESH_SUMMARY_JSON
```

The report validates every planned record, both Docker budgets/exit statuses,
runtime identities, configs, complete iteration count and complete synchronized
telemetry. A missing, failed, OOM or mismatched run writes a rejection report and
exits nonzero. It does not report a speedup from the surviving subset.

It reports per-iteration collection, world and actor/critic wall-time, per-run
and pooled median/p90 (nearest rank), adjacent AB/BA mean-time ratios, allocator
peaks and observed CUDA-free minima. Initial training iterations are excluded
according to the frozen spec. Replay warmup, final checkpoint and process attach
elapsed time are separate; initialization before the telemetry window is unknown
and is never inferred as pure GPU time. The phase timing includes existing
synchronization/telemetry overhead. Docker limits do not reveal actual cgroup
lifetime peak; collect the existing independent memory watcher if that evidence
is required and retain its sampling limitations.

The summary separately extracts the maximum observed `memory.peak`,
`memory.current`, `memory.swap.current`, and cumulative `memory.events`
`max`/`oom`/`oom_kill`/`oom_group_kill` counters from retained telemetry samples
plus `last_sample` (an identical last row is counted once). These appear in each
run's `container` and `timing.observed_cgroup` records and the aggregate
`memory_by_run` entries. Missing metrics remain null, with observation counts;
they are not silently reported as zero. The existing
`actual_cgroup_memory_peak_bytes: null` remains unchanged because phase-boundary
observations do not certify the whole container lifetime or activity after the
final sample. These values also do not measure combined host/GPU UMA usage.

Profiling runs use a separate spec with `execution_profile: true`, identically on
both sides. Their timing is explicitly ineligible for unprofiled throughput
claims. Use the raw execution profile/Nsight timeline to inspect CPU submission,
CUDA stream intervals and gaps. Inclusive nested spans cannot be added together
as independent costs; a CUDA stream interval is not a measurement of active
kernel time.

A single deliberately selected diagnostic training run is sufficient to inspect
the profile. It does not need a completed ABBA series. Use the independent report
entrypoint instead of submitting an incomplete series to the paired summarizer:

```text
moon run --target native scripts/summarize_native_optimization_pairs.mbtx -- --profile PROFILE_JSON FRESH_OUTPUT_JSON
```

This reads at most 64 MiB and 65,536 spans, accepts the runtime's actual `schema`
field, and records the source SHA. It reports inclusive CPU/GPU label counts,
sums, median/p90, and preserves span/parent IDs and observed leaf counts. CPU
exclusive time subtracts direct-child host durations only when the recording has
no dropped, open or cancelled spans and the single-threaded intervals are
properly nested. GPU exclusive time is deliberately not inferred. NVTX availability
is copied from the runtime, including `false`. The output is explicitly a
single-run diagnostic, with no performance-comparison or kernel-active-time claim.

When enabled, `train/execution-profile.json` is required. The summary reports
per-label CPU-inclusive and completed GPU stream-interval median/p90, plus
pending/cancelled/dropped counts. A truncated recording remains explicitly
partial. These diagnostic label statistics cover all recorded spans, including
warmup; they are distinct from the steady-state iteration report.

Before adopting a candidate, separately compare losses, gradients, parameter
updates, Adam moments and normalization state under the agreed tolerances. Check
the complete memory lifecycle, including persistent graph or FK caches, and
compare whole-iteration throughput beyond noise. Do not change physical/data
conditions or optimizer order merely to pass the performance gate. The tools
deliberately leave `numerical_equivalence_verified: false`.

## CPU-only tool verification

```text
moon run --target native scripts/run_native_optimization_pairs.mbtx -- --self-test
moon run --target native scripts/summarize_native_optimization_pairs.mbtx -- --self-test
```

These checks exercise strict option drift rejection, ABBA ordering, path bounds,
the read-write cache/read-only repository mount distinction,
quantiles and missing/reversed timing boundaries. They do not run a trainer or
claim candidate speedups.
