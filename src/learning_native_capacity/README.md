# Fixed native capacity profiles

This pure package is the shared source of fixed capacity bounds for future
CLI, runtime, checkpoint, audit and producer integration. It performs no IO,
GPU work, corpus allocation or memory admission. Its presence does not enable
larger training. The existing 65% guard, physical reserve and external memory
limits remain separate requirements.

`CapacityProfile::parse` accepts exactly `initial` or `paper-4096`. A caller
with no `capacity_profile` must retain `Initial`, including old checkpoints;
do not infer capacity from a descriptive `profile` string, dimensions, machine
memory or a newer executable. No arbitrary limit record is accepted. Limits
are read-only records created by the enum's `limits()` method and are not
deserializable configuration.

| Bound | Initial | Paper4096 |
| --- | ---: | ---: |
| Environments | 128 | 4096 |
| World batch | 128 | 2048 |
| Policy batch | 128 | 4096 |
| Replay steps per environment | 256 | 1000 |
| Replay F64 value count | 16,777,216 | 958,464,000 |
| Reference gather frames | 131,072 | 135,168 |
| Tensor values per prepared batch | 16,777,216 | 127,016,960 |
| Each stream sidecar | 512 MiB | 8 GiB |
| Stream sidecars plus state.json | 512 MiB | 10 GiB |
| Stream sidecar count | 64 | 64 |
| catalog.json / state.json | 64 MiB / 4 MiB | 64 MiB / 4 MiB |
| APIC numeric union | 512 MiB | 2 GiB |
| APIC producer payload total / each file | 1 GiB / 256 MiB | 4 GiB / 1 GiB |
| APIC payload file count | 4096 | 4096 |
| APIC SDK oracle tape | 4 MiB | 64 MiB |
| APIC manifest JSON | 4 MiB | 64 MiB |

APIC limits are serialization bounds, not runtime memory admission. The
Paper4096 bounds are not measurements of a 4096-environment artifact. Existing
consumer-specific legacy limits (including its separate total-file verification
bound), per-region indexing constraints and strict ABI/layout validation must
remain explicit at integration; the aggregate union limit does not authorize a
single region larger than its index representation.

The Paper4096 tensor cap covers the largest supported observation mode:
`4096 * (133 + 10*102 + 33*(71 + 73*10) + 32*102 + 5*32)`.
Paper93 uses 125,468,672 values and SMC99 uses 126,500,864. These are logical
batch bounds, not peak allocator usage or proof that such batches fit memory.

`validate_dimensions(environments~, world_batch~, policy_batch~, replay_steps~)`
requires positive counts within the selected profile and returns exact replay
payload sizes with checked Int64 arithmetic. Each transition has 234 Float64
values, two Int32 indices and two U8 flags (1,882 bytes). At 4096×1000 the
largest F64 member is **7,667,712,000 bytes** and complete logical replay payload
is **7,708,672,000 bytes**. Slab metadata, allocation growth, sampled batches,
optimizer state and isolated restore copies are excluded; this is not RSS.

`validate_stream_totals(sidecar_bytes, state_bytes~)` receives every numeric
sidecar and catalog.json **once**, plus separate state.json bytes. Zero-length
numeric blobs remain legal. Call `validate_catalog_bytes` separately for the
catalog's decode bound. The total excludes optimizer `.pt` archives and
receipt.json, whose existing independent limits and budget checks still apply.
Filename, dtype/shape/count, member inventory, hashes and isolated restore
commit validation are still required; byte-count validation does not replace
them. This package does not change the stream codec's own descriptor ceiling.

Initial preserves the legacy dimension and stream limits. Integration must
explicitly bind the selected capacity to training/checkpoint identity, require
stream-v2 for a larger profile where appropriate, retain old checkpoint
default behavior, and run resource admission before allocating larger buffers.
This change does not itself connect any consumer or authorize a GPU launch.
