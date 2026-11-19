# Optional one-step imagined-noise staging

`noise_staging_batch=false` preserves the existing per-256-sample noise upload
path. The optional runner/API request is `noise_staging_max_bytes=Some(cap)`;
the CLI owns the Boolean and MiB-cap wiring. The default cap is 16 MiB.
This candidate changes only imagined observation-noise preparation, after
history noise and before critic permutations. It changes neither sampling nor
learner/normalizer/GAE/optimizer operations. Resident reference code is untouched.

For B4096, H32 and Smc99, the old route uploads 16 chunks per time step and
concatenates them. The candidate still generates at most 256 samples in a
temporary block, copies into one full B×99 Double array, and uploads it once.
Thus **512 noise uploads and 32 concatenations become 32 uploads and no
concatenations**. The 51,904,512-byte Float32 noise payload and all RNG draws
are unchanged. These counts are source-level operations, not kernel timings.
No speed benefit has yet been established by a paired GPU benchmark.

Generation order remains time, then sample, then observation component. Every
complete 256-sample block is generated before finite validation, matching the
old `Array::makei` followed by upload. An invalid value therefore consumes the
same current block's draws and stops before the following block, later time
steps, or permutations. Checking each value before finishing its block would
be incorrect. The candidate uploads only already-validated private data, using
the original Float64-to-requested-Float32/Float64 conversion. A failure can
leave fewer temporary GPU tensors than the old route; it must not advance RNG
further or produce a batch. Explicit invalid caps/shapes/dtype fail before noise
draws; public batch constructors prevalidate before replay/history RNG too.

Let V=B×D and C=min(B,256)×D. The additional conservative reserve is
**32V + 8C + 65,536 bytes**: full Double array, FFI FixedArray copy, CPU Float64
tensor, dtype conversion/device tensor, one Double generation block, and fixed
metadata allowance. Float64 skips the conversion and uses eight device bytes,
so the same bound applies. Only one time step's host staging is live; the
already-admitted H-step device tensors remain in the original envelope.
No removed GPU concatenation is credited, and the extra reserve is charged to
every phase for allocator retention. No guard or existing cap is reduced.

At B4096/D99: V=405,504, full host payload=3,244,032 B, block payload=202,752 B,
and additional reserve=**13,244,416 B**, below the 16 MiB cap. At or below 256
samples the candidate reduces no upload calls and may only add copy overhead.

The focused test file is `noise_staging_wbtest.mbt`. Its gates cover cap/shape
rejection before RNG, independent legacy per-block upload comparison, NaN
failure boundaries including both sides of a 256-block boundary, signed zero,
Float32/Float64, all policy fields/noise/permutations and subsequent RNG draws,
the full B4096/H32/Smc99 noise sequence, resident-reference composition, and
actual learner updates with full B257 and
logical B4096/micro512 (eight chunks), using small fixture networks. It does not
claim paper-size convergence or cross-runtime equivalence.

Local CPU result: **4/4 tests passed**, using the existing
`target/learning-tensor-perf-checked-norm/libmoonrobo_learning_tensor.dylib`.
Receipt: `/tmp/moonrobo-noise-staging-cpu-final.log`; generated interfaces and
formatting completed (`/tmp/moonrobo-noise-staging-info.log`, zero errors).
No GPU, plugin rebuild, remote build or throughput experiment was run here.

Run only when scheduled, with an existing tensor plugin:

```text
MOONROBO_TENSOR_LIBRARY=<plugin> MOONROBO_OPTIMIZATION_TEST_DEVICE=cpu moon test src/learning_aligned_gpu/runtime/noise_staging_wbtest.mbt --target native --release --warn-list -a
```

The same file accepts explicit `cuda:0`; a missing plugin/device or insufficient
headroom fails that request instead of silently skipping. GPU runs and complete
paired throughput comparisons remain owned by the root run coordinator.
