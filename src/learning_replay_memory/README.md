# Compact replay memory diagnostics v2

`diagnose_stream_v2(Inputs) -> Plan` is a pure, per-rank calculation for the
current F64 slab replay plus stream-v2 checkpoint path. It allocates no tensors,
files, replay capacity, or simulator state. The report is explicitly
`moonrobo.compact-replay-memory-plan.v2`, `diagnostic_only: true`, and
`admission_eligible: false`. It is **not connected to training admission**.
Default v1 checkpoints, all runtime/CLI limits, the 65% host/CUDA guard and the
24 GiB Isaac reserve remain unchanged.

Pass `runner.replay.storage_usage()`, the runner capacity/environment count,
learner config and canonical observation mode (`paper`, `smc`, `observable`).
`next_collection_steps` projects whole physical rows; `restore_rows` is the
saved chronological row count. `sampler_bins` counts all reset bins.
`environment_payload_bytes` is the sum of environment numeric sidecars
**excluding** sampler arrays. Catalog and state sizes are actual encoded bytes
or explicit preflight upper bounds; the existing 64 MiB/4 MiB maxima still apply.
If available, supply the sum of the three actual `.pt` file sizes. `None` is
reported as unmeasured, never as a known archive bound. The caller must use
stream-v2; legacy v1 snapshots still materialize an object graph and require the
existing legacy budget.

## Exact arithmetic and retained allowances

For `C = capacity × N`, `R = rows × N`, lazy slabs allocate
`A = min(C, ceil(R / 1024) × 1024)` records (zero when empty). Each record stores
234 F64 values, two I32 indices and two U8 flags: **1882 bytes**. The final slab
ends at capacity; a full slab has 1,927,168 payload bytes. The report checks the
observed `storage_usage` against this layout and refuses incompatible storage.
Arithmetic uses checked Int64 and retains the replay's existing Int32 index
ceiling. A 4096 × 1000 diagnostic is arithmetic only; it does not admit that
profile or allocate its replay.

| Item | Accounting |
| --- | --- |
| Replay payload | Exact current, next collection, capacity and isolated restore slabs |
| Actor candidate array | Exact `4 × logical records`; no candidate tuple objects |
| Histories | F64 payload `8 × N × hist × observation_dim`; I32 lengths in checkpoint |
| Sampler | Two F64 plus one I32 array: `20 × bins`; another `32 × bins` temporary payload allowance for probabilities/validation |
| Compatibility samples | At most `max(Bw×W, Bp×(hist+1), N)` Transition objects; retain the old 128 KiB/transition allowance pending measurement |
| Tensor upload | Count world/policy/collection input values, F64 host/FFI/CPU staging, converted CPU/device tensors and concat; 32 B/F32, 40 B/I64, with another 4 B/policy value for concat |
| Models/BPTT/reference/physics | Keep the original planner's parameter count, 16 B/parameter plus 0.5 GiB, BPTT coefficients, 4 GiB reference reserve, 2/24 GiB physics and optional 1 GiB communicator reserve |
| JSON/codec | Retain 16× encoded catalog/state bytes; 1 MiB allowance around the sequential 64 KiB codec chunks |
| LibTorch archives | Retain audit's `6 × max(actual archive bytes, 16 × parameter count) + 1 GiB`; this is an uncalibrated allowance, not a proved maximum |

Four array/record headers, a growing slab directory and allocator overhead are
not payload. The diagnostic adds 256 bytes/slab plus 4 KiB per replay as an
explicit **uncalibrated allowance**. Dynamic histories/sampler objects, allocator
caches, SDK internal buffers and kernel file/writeback cache also require
measurement. The result is combined host/device accounting; it is neither RSS
nor measured CUDA usage and is not a certified upper bound.

`train_after_collection` and `train_at_capacity` retain sampling, upload and
candidate allowances. `save_at_capacity` never adds a full replay object copy.
`restore_into_current` charges the current replay **plus** the isolated saved
replay, histories, sampler, validation vectors and physical sidecars until
commit. `restore_at_capacity` explicitly charges two full-capacity replays. Warm
APIC restore has the same validation/staging cost before clearing replay; this
plan does not make APIC or distributed resume exact. Existing BPTT reserves are
also retained during save/restore rather than assuming allocator caches vanished.

For 4096 × 1000, raw replay payload is 7,708,672,000 bytes (7.1793 GiB), and two
full replays are 15,417,344,000 bytes (14.3585 GiB), before other allocations.
Candidate indices add 16,384,000 bytes. The legacy replay/JSON comparison is
536,870,912,000 bytes (500 GiB). These are arithmetic results, **not a measured
process reduction or a declaration that a device can train this profile**.

## Integration boundaries

1. Initially emit this report alongside the unchanged
   `cmd/memory.mbt::estimate_memory` result, only when checkpoint format is
   stream-v2 and storage reports `moonrobo.replay-f64-slab-storage.v1`. Fetch
   actual usage after collection and final encoded sizes after save; never
   substitute the initial empty allocation for the full-run capacity budget.
2. Compare current/capacity projections with process/cgroup peaks and CUDA free
   memory during collection, world fitting, actor/critic updates, save, exact
   restore and warm restore. Record file-cache residency separately. The
   `uncalibrated` list is intentionally not empty until these are measured.
3. Any later admission change must coordinate
   `cmd/memory.mbt::estimate_memory` **and**
   `cmd/checkpoint.mbt::publish_checkpoint`. Publication currently requires the
   old `host_replay_and_json_checkpoint_envelope + 1 GiB` of fresh host headroom;
   deleting that key or merely changing the startup estimate is incorrect.
   Separate process-baseline/resident accounting from *additional* headroom,
   including cold-start versus replacement restore. Keep the 65% rule, physics
   reserve and legacy-v1 branch until separately authorized/calibrated.

## The independent 512 MiB checkpoint limit

The report projects both saved-row and full-capacity state-plus-sidecar totals
and reports whether each fits the **unchanged** 536,870,912-byte envelope. A
7.18 GiB replay does not fit, even though serialization is streaming. The F64
replay member alone would also exceed the existing 512 MiB per-member checks.
The lower-level stream codec can address files up to 64 GiB, but that is not
permission to bypass the generation reader/writer limits.

A future opt-in large-numeric checkpoint profile should retain bounded state
JSON, catalog, file count and model archive limits, while deriving each numeric
descriptor's exact byte count from the accepted dimensions. It needs a bounded
aggregate numeric-byte budget, checked Int64 accumulation, free-disk admission
for a fresh atomic generation alongside retained generations, and the isolated
restore memory plan **before** any live mutation. Large members can stream in
the existing 64 KiB chunks; sharding is unnecessary for memory safety and would
otherwise require another descriptor schema. Directory publication remains
atomic only after all complete second-pass hashes and semantic validation.

Update the generation publisher/reader, independent audit, inference receipt
verification and deployment validators together under that explicit profile.
Do not quietly relax only `validate_stream_members` or only a file-size check.
Retain v1/small-v2 reads and reject unknown profiles. Tests must cover bounded
large-count arithmetic, truncation/hash mismatch, disk failure retaining the
previous pointer and failed staging leaving live state unchanged. **No numeric
or metadata cap is increased in this package.**

Local tests use tiny CPU fixtures: exact slab accounting through wrap, zero
allocation for the hypothetical 4096 × 1000 projection, restore coexistence,
retained reserves, sidecar limits, monotonic archive charges and overflow/foreign
storage rejection. They do not exercise GPU training or certify peak memory.
