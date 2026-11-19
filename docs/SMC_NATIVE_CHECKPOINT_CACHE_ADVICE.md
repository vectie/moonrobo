# Bounded SMC/native checkpoint page-cache advice

`scripts/advise_smc_native_checkpoint_cache.mbtx` selects generated checkpoint
outputs from explicitly named, successfully completed individual members of
`moonrobo.smc-native-pairs` series. A later failure of another member does not
invalidate an already completed member for cache maintenance, but does still
invalidate that series for performance comparison. A member with `passed=false`
is always rejected by this helper.

The checkpoint modes do not scan directories recursively. Native selection is limited
to the current committed generation's receipt-listed optimizer and numeric
replay/history/environment/sampler payloads. SMC selection is exactly
`logs/last.pt` and `logs/ckpt_000060.pt`, after verifying final arguments and
60 complete CSV rows. Inputs, motion/dataset shards, APIC, assets, ComputeCache,
logs and metadata are not cache-advice targets.

## Usage

Run on idle Linux 179, with no concurrent job launcher or other writer:

```text
moon run --target native scripts/advise_smc_native_checkpoint_cache.mbtx -- \
  --plan FRESH_PLAN_JSON CANONICAL_PASSED_RUN_PATH...

moon run --target native scripts/advise_smc_native_checkpoint_cache.mbtx -- \
  --advise FRESH_ADVICE_JSON SAME_CANONICAL_PASSED_RUN_PATH...
```

Both modes require 1–16 explicit paths of the form
`/home/wlc004s/moonrobo/runs/SERIES/run-N`, with no traversal, partial component,
symlink or noncanonical ancestor. Maximum selection is 1024 regular files,
16 GiB per file and 64 GiB total. Every payload must have exactly one hard link.
Series locks are deduplicated and held; native training locks are also held.
Local Docker must be empty before collection, before advice and at completion.
This idle contract is not an atomic system-wide scheduler lock.

The frozen spec's SHA-256 is recomputed from small metadata. Final successful
Docker/guard state, image identity, actual training arguments and committed
checkpoint identity are checked. Before any data sync or cache advice, the
helper creates and fsyncs `FRESH_REPORT_JSON.selection.json`, listing each
path, size, generation, available receipt digest and stat device/inode/size/
mtime/ctime/link count. Each operation rechecks the file identity. Fresh report
paths use CreateNew; old reports, checkpoints and their receipts are preserved.

In advice mode, each target receives only these GNU coreutils operations:

```text
sync --data -- EXACT_CHECKPOINT_PATH
dd if=EXACT_CHECKPOINT_PATH iflag=nocache,nofollow count=0 status=none
```

GNU coreutils 9.4 [`sync.c`](https://raw.githubusercontent.com/coreutils/coreutils/v9.4/src/sync.c)
uses file-specific `fdatasync` for `--data`; the helper always supplies one
explicit file and never invokes global sync or syncfs. The file was successfully
opened read-only by the helper first. Coreutils normally opens it read-only too,
although its own error path permits a write-only fallback; it does not alter
file content. Flushing previously dirty kernel pages is possible.

GNU coreutils 9.4 [`dd.c`](https://raw.githubusercontent.com/coreutils/coreutils/v9.4/src/dd.c)
opens the input read-only, applies `O_NOFOLLOW`, skips payload reads for zero
count and requests `POSIX_FADV_DONTNEED` to EOF. No output file is supplied.
The helper checks command exit status; `advice_returned_zero` records that
command result, not a measured number of reclaimed pages. This is a cache hint,
not a guaranteed eviction. Recheck CUDA free and rerun normal preflight after
maintenance; file sizes do not predict reclaimed unified-memory availability.

No checkpoint payload is reread or rehashed, avoiding immediately repopulating
the cache. Native receipt hashes are retained as existing identity evidence;
SMC does not publish such checkpoint hashes and records null rather than an
invented digest. Content preservation follows from the operations issued, not
an independently recomputed after-the-fact payload hash. Operator-enforced
immutability remains required: pathname checks cannot exclude arbitrary
concurrent replacement or same-inode writes atomically.

## Local validation and scope

`moon run --target native scripts/advise_smc_native_checkpoint_cache.mbtx --
--self-test` passed bounded scope, payload-name, identity/size/single-link and
committed-checkpoint rejection assertions. Temporary filesystem fixtures passed
regular-file selection, leaf/ancestor symlink rejection, directory rejection,
read-only exclusive locking, and unchanged content/mtime checks. Only those
owned temporary fixtures were removed during cleanup. No Docker command,
remote operation, cache hint or GPU task ran in the local test.

The script uses the existing `async@0.20.2` dependency and GNU coreutils already
confirmed on 179. It requires no new FFI library or training-plugin build.
The older `advise_optimization_checkpoint_cache.mbtx` remains available for its
original native-optimization series format; neither helper changes training
memory admission or numerical behavior.

## Optional private compilation-output mode

`--plan-caches` and `--advise-caches` use the same command shape and completed
individual-member gate. They select only that run's `cuda-cache`,
`inductor-cache` and `triton-cache`, and only regular files at least 1 MiB.
These are completed run-owned outputs; they are not the shared dataset cache,
image cache, input assets, global CUDA ComputeCache or XDG `/pair/cache`.

The original launch must exactly match the frozen plan for that run index.
Its image and command must match the final container. `/pair` must be one
read/write bind of the exact run directory, with no nested mount shadowing it.
Each selected root must be explicitly named by its matching environment variable
in both the launch and final container: `CUDA_CACHE_PATH`,
`TORCHINDUCTOR_CACHE_DIR`, or `TRITON_CACHE_DIR`. A shared or conflicting value
is rejected. The paired runner creates a fresh run directory and refuses to
reuse an existing one; future members therefore receive different private
cache paths. The operator must not separately resume/reuse a completed member
while performing maintenance.

Scanning is limited to those three roots, depth8 and 32,768 entries per run.
All scanned regular-file sizes, including unselected small files, count toward
the 4 GiB per-run limit. Symbolic links and special entries fail the scan;
selected payloads also require a single hard link and unchanged canonical/stat
identity. The unchanged overall bounds are 16 explicit members, 1024 selected
files and 64 GiB. Small files remain untouched and their count/bytes are
reported, keeping per-file command overhead bounded. No directory or file is
deleted or rewritten.

Before cache hints, the durable selection report identifies every selected
file and its proven private output roots. These outputs have no saved payload
digest; their digest field is explicitly null. The same file-specific sync/dd
operations and idle checks apply. `compute_cache_selected=true` in this mode
means these exact private output roots, never a global or shared cache.

Local tests additionally reject shared/duplicate cache environment values,
command changes and nested mounts. Iteration explicitly excludes `.`/`..`
while retaining hidden files; unsafe or partial returned names remain rejected.
Temporary small-file scans verify skip counts, depth/entry/byte limits and
symlink rejection. No remote cache hint is
performed by these tests. Only the run owner executes maintenance after the
active profile process exits, then reads fresh memory telemetry and preserves
the existing admission policy.

## Read-only review of the older container-cache helper

The 2026-10-24 follow-up reviewed
`scripts/advise_optimization_container_cache.mbtx` without running its plan or
advice modes. It accepts the older `native-optimization-pairs` format, not the
new F-series `smc-native-pairs` format. It verifies passed run/config/spec
identities, a complete committed checkpoint, and matching saved/current
container ID, image and overlay2 identity. The owned training container must
still be stopped with exit0/no OOM and the expected 100 GiB/no-extra-swap/12-CPU
resource settings.

Its only target is that stopped container's canonical overlay2 upper directory
under `home/isaaclab/.nv/ComputeCache`. It holds the training lock, rejects
symlinks/special files/hard links, and bounds each selected cache to 1024
inventory entries, 512 regular files, 512 MiB per file and 4 GiB total. The
source is bind-mounted read-only in a separate runc worker with no GPU devices,
network or capabilities, a read-only root, 256 MiB/no-extra-swap and one CPU.
Per-file sync and zero-count dd preserve contents. Stopped-source and idle
checks do not replace the operator's no-concurrent-writer contract.

**Its `--plan` also starts this CPU-only inventory worker.** It is therefore
not a pure read-only command with respect to Docker state. This review did not
invoke either mode, start/stop any container, issue a cache hint or change source.
Read-only Docker inspections confirmed the three historical series' run0
containers still existed and were exited0/no OOM. Direct overlay access required
privilege and was not obtained; no current page-residency measurement was made.

The retained [earlier advice receipt](../output/spark-runtime-20261024/optimization-stage2-20261024-b/optimization-container-cache-advice-a.json)
already records successful hints for all four geometry-A members and all four
critic-normalization-B members: each had 60 files totaling 149,388,490 bytes.
Those eight caches total 1,195,107,920 bytes, but may already be cold; repeating
the hint does not imply that much additional memory becomes available. The
receipt also covered graph A0/B0/C0/C1, not final graph D0–D3. Applying the same
historical file-size layout to D would suggest about 597,553,960 bytes, but this
was only a candidate estimate, not a measured current inventory or reclaimable
resident amount.

The run owner subsequently reported that maintenance of the newly completed
F0/F1 outputs provided enough headroom to start the next fresh F2-series member,
so no additional privileged old-container maintenance was needed. Fresh
post-maintenance CUDA availability and the unchanged per-member preflight,
not historical cache file sizes, determine whether subsequent members may run.
