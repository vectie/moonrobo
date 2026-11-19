# Optional logical-batch world staging

`world_staging_batch=false` preserves the original 256-window decode/pack/upload
route. With `world_staging_batch=true`, five preallocated arrays hold the logical
batch fields `s`, `s1`, `actions`, `xi`, `mask`; decoding still holds at most 256
`ReplayWindow` objects. The same replay calls make the same start/environment
draws in the same order. Rows are written in batch-major, then time order;
finite checks, binary masks and the original Float64→requested-dtype upload
remain enforced. Finite checks run while copying each decoded block, before
drawing the next block; validated private arrays are not rescanned at upload.
No replay mirror, cross-update cache, extra sampling or
normalizer/learner change is introduced.

For a world batch of 2048 with window 8, the old route uses eight blocks, 40
uploads and five final GPU concatenations per update. The candidate uses five
uploads and no GPU concatenation. The full tensor shapes and amount of data
uploaded are unchanged. This removes submissions/copies, not the sequential
eight-step world-model dependency. At or below 256 windows it offers no upload
count benefit. Speed is unmeasured; it may lose on CPU packing/validation.

Configuration:

```json
{
  "world_staging_batch": true,
  "world_staging_max_mib": 128
}
```

The default cap is 128 MiB when enabled and accepts integers 1..4096. It limits
the **additional reserve**, not only useful payload. Let `V=B×window×205`.
The five Float64 arrays contain `8V` bytes. Admission adds `32V+65536` bytes to
**every original phase**, including allocator-retention phases, and never
credits the removed concatenations. The reserve covers the preallocated arrays,
FFI FixedArray copy, CPU Float64 upload copy, dtype conversion and device storage
plus headers; it supports both Float32 and Float64 without treating BF16 MLP
compute as smaller reference/replay storage. The already-admitted 256-window
decoder envelope remains in place.

| Shape | Array payload | Additional reserve | Suitable explicit cap |
| --- | ---: | ---: | ---: |
| B2048, window8 | 26,869,760 B | 107,544,576 B | 128 MiB |
| B4096, window8 | 53,739,520 B | 215,023,616 B | 256 MiB |

`world_staging_usage` validates shapes, tensor-value limits and the cap before
staging allocation or RNG draws. CLI settings and runner construction both
enforce it; explicit undersized caps fail without silently falling back. The
runner holds only the option between updates and keeps it after resume.
Distributed setup identity includes an enabled cap; ordinary checkpoint config
identity records the request. New preflight reports include usage only when
enabled. CUDA/process guards and the original profile limits remain unchanged.

Local CPU validation: all 26 runtime-package tests (including the three new
staging tests) and one focused config/admission test passed
using `target/learning-tensor-perf-checked-norm/libmoonrobo_learning_tensor.dylib`.
Coverage includes bitwise field/dtype/mask and RNG equality at batches
1/256/257/2048/4096, FP32/FP64, wrapped multi-environment replay, rejected bounds,
and actual learner full/128-microbatch updates. The learner test includes three
iterations, runtime resume, action/noise/sampling continuity, metric equality,
and complete parameter/Adam/normalizer digests; resident-reference caching is
enabled on both sides to check composition. It is a correctness gate, not a
throughput result or a full paper-sized optimizer-state test.

Final local receipts: `/tmp/moonrobo-world-staging-runtime-final.log`,
`/tmp/moonrobo-world-staging-config-final.log`, and
`/tmp/moonrobo-world-staging-info.log`. `moon info` and `moon fmt` completed.
After folding finite validation into packing, the three staging tests passed
again; receipt: `/tmp/moonrobo-world-staging-runtime-freeze.log`.

Run the same test file with `MOONROBO_TENSOR_LIBRARY` set and
`MOONROBO_OPTIMIZATION_TEST_DEVICE=cpu` (default) or explicit `cuda:0`:

```text
moon test src/learning_aligned_gpu/runtime/world_staging_wbtest.mbt --target native --release --warn-list -a
```

An explicit CUDA request fails on missing library/device/headroom rather than
skipping. Only the run owner launches GPU tests. Next compare this flag alone
using the same frozen data/indices, batch shapes and precision, retaining
`world.sample_prepare_upload`, `batch.world.pack`, `batch.upload`, complete
iteration time and memory through checkpoint completion. The previous original
path and its frozen benchmark artifacts remain the baseline.
