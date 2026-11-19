# Stream-v2 runtime checkpoint

This is an opt-in checkpoint encoding. It preserves Float64 replay values,
sampling order, RNG state, histories, and the existing learner mathematics.
The CLI default remains v1. Existing environment/batch/replay limits and the
conservative admission guard still apply; this change does not admit paper-scale
training or implement distributed/APIC exact resume.

`RuntimeSnapshotV2` stores small metadata and six typed sidecar descriptors:

| File | Type and shape | Order |
| --- | --- | --- |
| `catalog.json` | U8 `[byte_length]`, at most 64 MiB | Ordered names, source hashes, FPS |
| `history.lengths.i32le` | I32 `[N]` | Zero or configured history length |
| `history.values.f64le` | F64 `[N, hist, observation_dim]` | Empty histories have storage padding only |
| `replay.values.f64le` | F64 `[rows, N, 234]` | Chronological row, environment, `s71/s1_71/a29/a_prev29/xi33/reward1` |
| `replay.indices.i32le` | I32 `[rows, N, 2]` | Reference frame, episode step |
| `replay.flags.u8` | U8 `[rows, N, 2]` | Terminated, truncated; each 0 or 1 |

The catalog format is `moonrobo.native-runtime-catalog.v2`, with
`motion_names`, `motion_sha256`, and `source_fps`. `catalog_digest` is the SHA256
of the actual catalog file bytes, equal to its descriptor SHA. Catalog preflight
counts actual JSON-escaped UTF8 bytes incrementally. It does not multiply every
hex digest character by a worst-case Unicode expansion.

Each physical environment also writes its sampler arrays directly as
`sampler.returns.f64le`, `sampler.average.f64le`, and
`sampler.completed.i32le`. MuJoCo adds integration state, previous actions,
context, episode indices, initialization flags and returns. APIC records context
and the sampler only, explicitly preserving the existing warm-reset/refill
contract. It does not claim to persist hidden solver/contact state.

To restore a complete generation, the CLI first verifies its immutable receipt
and every file. Then call `runner.prepare_snapshot_v2(directory, metadata)`,
restore the physical environment, and call `runner.commit_snapshot_v2(token,
exact_physics_resume)`. The opaque token is bound to one runner and can be used
once. Every stream and all transition/history business rules are checked before
runner state changes. The environment similarly stages all decoded arrays before
physical writes. If a physical adapter itself fails while applying a validated
state, abort the process; no transactional rollback of native physics is claimed.

Even warm restore validates and decodes the entire saved replay before discarding
replay/history. Distributed resume is still rejected. Existing v1 APIs remain
available, and the CLI retains its strict executable-identity resume constraint.

Saving never clones the full replay or sampler arrays. Codec chunks contain at
most 64 KiB. Live replay uses lazy primitive slabs, at most 1024 transitions per
slab: 234 Float64 values, two Int32 indices and two U8 flags per transition (1882
payload bytes). `ReplayBuffer::storage_usage()` distinguishes logical, allocated
and capacity payload; it excludes array headers and allocator overhead and does
not measure RSS. The final slab stops at the configured capacity.

Replay methods and the v1/v2 wire schemas retain their signatures/formats. The
former publicly readable `ReplayBuffer.rows` object array and `ptr` field are
now private implementation state: repository callers did not read them, but
external source code that did must use `size`, sampling, explicit `snapshot`, or
`storage_usage`. No duplicate object graph is retained for field compatibility.

Restore first verifies the sidecars, then decodes directly into one isolated
slab replay plus histories, with no full separate index/flag arrays. Each reader
finishes its second hash pass before business validation; validation materializes
at most one compatibility Transition at a time. Commit moves slabs without a
numeric copy and consumes the staging buffer, preventing later writes through
that buffer from changing live replay. Peak memory still includes the old live
replay and the isolated replacement until commit. Explicit v1 snapshots retain
the old object representation; collection, sampling and v2 I/O do not use it.
MuJoCo restore also stages its bounded integration state. Sampler validation
invokes the existing probability formula on staged
arrays before commit, adding its usual temporary logits/probability vectors; it
rejects finite stored returns that overflow that formula or have no eligible
reset mass. Episode counters must permit the next physical increment. The
catalog can temporarily require JSON/string/UTF8 representations up to
its fixed bound. File cache and allocator/native-library overhead remain real
memory costs; this implementation keeps the original conservative guard rather
than treating raw sidecar byte counts as peak RSS.

Tiny CPU regressions cover chunk boundaries, ring order, Float64 negative-zero
bits, two-phase commit, SHA/shape/business-rule rejection without mutation, empty
replay, and synthetic protocol parity with v1 warm restore. A separate deferred
real MuJoCo fixture checks integration-state parity and the following transition.
Synthetic protocol tests do not certify CUDA or APIC numerical equivalence.
