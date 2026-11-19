# Optional native training memory diagnostic

Add `--cuda-memory-telemetry` to the native trainer's `train` invocation. The
flag defaults to off. An enabled run requires a CUDA learner and the optional
allocator telemetry symbols in the loaded ABI-2 tensor plugin; a missing
symbol is an error. `preflight` can check this capability without creating a
measurement window. Evaluation and export do not accept the flag.

The diagnostic does not change the training configuration, precision,
microbatch schedule, 65% admission fraction, 24 GiB APIC reserve, or container
limits. Existing frozen launchers deliberately reject a newly built trainer or
plugin until their new hashes are explicitly pinned. The flag belongs to the
distributed launch signature, so both ranks must agree, but is excluded from
the durable training identity. With the same executable and plugin, enabling
or disabling it does not invalidate a checkpoint. Normal executable/plugin
identity checks still apply.

## Window and synchronization

After the learner, physical environment and any checkpoint restore have
completed, the diagnostic synchronizes CUDA and reads the pre-reset allocator
peak. It then synchronizes and resets allocator peaks exactly once, and reads
the window baseline. Each later sample synchronizes before collecting current
and peak counters. Phases are warmup, collection (including readiness refill),
all world-model updates, actor plus critic updates or their scheduled skip,
checkpoint begin, checkpoint completion, and final training completion.

Peaks are cumulative across this single window; they are not separate reset
peaks for each phase. Even an allocation freed before a phase boundary can
contribute to its allocator peak. CUDA free memory is a boundary observation,
so its minimum is not a continuous minimum. A resumed process creates a new
window after restore; allocator counters are not checkpoint state. The initial
pre-reset sample separately retains the allocator peak visible after setup and
restore. Environment teardown and report serialization are outside the window.

Synchronization changes timing. Do not compare the reported elapsed time with
an uninstrumented run as a performance benchmark. The diagnostic never calls
`empty_cache`, changes the memory admission calculation, or adjusts the
container's memory limit.

## Meaning and bounds

The four allocator counters describe the active CUDA allocator or pool. They
exclude allocations outside that allocator or pool. A shared asynchronous CUDA
pool can include allocations from other libraries using that pool. They are
not total device usage, and must not be added to CUDA used/free memory or host
memory to manufacture a total peak. CUDA free/total comes from the same plugin
and device; actual APIC or other allocations outside the allocator are only
indirectly reflected in free memory.

The process must keep its allocator enabled and must not externally reset
peaks or change cache configuration during measurement. Known environment
settings disabling the cache are rejected by the plugin. Its generic ABI
cannot detect a programmatic `enable(false)` call, so the report explicitly
records `programmatic_cache_disable_checked: false` rather than claiming to
detect every way to disable caching.

Linux host observations use a fixed whitelist of `/proc/meminfo`,
`/proc/self/cgroup`, and seven files at the visible `/sys/fs/cgroup` mount root.
Each read is at most 16 KiB. Cgroup metrics are raw decimal or kernel text; the
report includes their paths, the process's unified cgroup path, and whether it
is `/`. If the process is in a child cgroup, root metrics are not presented as
that child group's metrics. Ancestor limits are not enumerated. Missing files
or malformed MemAvailable produce `null` plus an error, never zero. Host and
CUDA observations are sequential, not an atomic snapshot. Kernel cgroup peaks
are never reset by this feature and can predate the diagnostic window.

Only the first 128 sample events, each at most 16 KiB, are retained and printed.
Later samples still update cumulative allocator peaks, the observed CUDA free
minimum, and the latest sample without extending the log or retained array.
The report includes retained, total and omitted counts. One bounded error
event may also be emitted. JSON encoding expands the bounded event prefix by
a fixed formatting factor; no per-iteration array grows after the prefix is
full.

## Publication and failure

Successful runs put the bounded window into both `report.json` and a separate
`cuda-memory-<time>-rank-<rank>-iteration-<start>.json`. The separate file uses
CreateNew and is synchronized before writing `report.json`. It cannot replace
`current.json` or an earlier diagnostic window.

A CUDA query/reset failure, malformed snapshot, decreasing cumulative peak,
or oversized event stops subsequent training work and aborts an active
collective. A bounded failed-window report is attempted without masking the
original exception. Host procfs/cgroup unavailability alone is recorded as
missing data; it does not fabricate a CUDA measurement or abort learning.

Checkpoint publication retains its existing atomic boundary. A diagnostic
failure before publication leaves the previous valid pointer unchanged. A
failure after publication preserves the newly published valid generation;
the diagnostic does not roll it back. Already completed physical transitions
or optimizer updates are likewise not undone. If final `report.json` writing
fails after the separate diagnostic file was saved, that immutable file's
`complete` status describes the training/checkpoint measurement window, not
successful completion of all process output. The process still exits with
the output error; the CreateNew window is not overwritten during cleanup.

## Validation and bounded N128 trial

CPU regression tests cover opt-in parsing, capability refusal, unchanged
admission and training settings, one reset, bounded sampling, fail-closed peak
validation, unavailable host metrics, native reader bounds and checkpoint
pointer isolation. The tiny CPU learner regression checks real callback
ordering and that a callback failure stops subsequent optimizer updates.
These tests do not validate CUDA phase measurements.

The parent-run N128 gate can use the existing one-iteration, 40-LAFAN config
and genuine N128 APIC bundle, with a fresh output directory, the newly pinned
trainer/plugin, and the existing 64 GiB/no-swap/4-CPU container constraint:

```text
TRAINER train --tensor-library TENSOR_PLUGIN --library MUJOCO_LIBRARY
  --scene /workspace/moonrobo/data/g1_description/scene-no-self-collision.xml
  --manifest /workspace/moonrobo/data/manifest.json
  --config /workspace/moonrobo/examples/learning/g1-native-tensor-apic-n128-scale-gate.json
  --physics-library /opt/moonrobo/apic-runtime/libmoonrobo_aligned_apic.so
  --physics-artifact /workspace/moonrobo/runs/apic-n128-20261024-a/g1-128env-apic/manifest.json
  --output /gate/train --checkpoint-format stream-v2 --iterations 1
  --cuda-memory-telemetry
```

The plugin capability check should also run in preflight. Actual admission
must still succeed; this feature provides observations for future budgeting,
not an override of present memory bounds.

## Actual N128 diagnostic gate

The 2026-10-24 `native-n128-telemetry-20261024-b` run on 178 completed one real
N128 CUDA/APIC iteration and all nine synchronized observations, followed by a
separate successful CPU decode of its saved learner. Its post-initialization
allocator window reached 341,745,664 allocated bytes and 434,110,464 reserved
bytes; minimum sampled CUDA free was 86,754,131,968 bytes. The observed cgroup
peak was 2,346,942,464 bytes, with no observed OOM. These have separate scopes:
the cgroup watcher lost its final sample after container exit and does not
certify a complete-lifetime peak; allocator counters exclude outside
allocations and are not total device memory.

The [execution record](../../../scripts/RUN_SPARK_NATIVE_N128_TELEMETRY_GATE.md#recorded-execution-on-178-2026-10-24)
links the original inside/phase/Docker/watcher/readback evidence, records the
preceding input-validation failure, exact binary/source hashes, unchanged
64 GiB/four-CPU/no-swap/65%/24 GiB bounds and the source-overlay boundary.
This validates one bounded measurement and checkpoint-readback path, not
convergence, a completed training study, sustained memory requirements or
weight equality with an older run. Frozen source archives retain their
pre-execution documentation; this paragraph is a later documentation update.
