# Optional resident reference table

The original bounded reference gather remains the default. A runner may create
one `ResidentReferences` table and pass it to `sample_policy_batch` or
`policy_batch_from_starts`. Collection may reuse `goals_for_frames`. This table
stores immutable reference flat71 rows and K-frame goals, not replay samples or
any learner state.

Initialization calls the original `MotionLibrary.goal` Float64 scalar formula
and converts each value to the requested tensor dtype at upload. No arithmetic
is moved to GPU, so the implementation keeps the existing rounding, signed zero,
clip-tail padding and operation order. Each policy batch uploads one time-major
Int64 frame-index table and gathers the previously encoded references/goals.
History observations, sample selection, observation noise, imagined noise,
critic permutations, normalizer updates and optimizer steps keep their original
paths and RNG ordering. History source reads only need the selected historical
frames; imagined references no longer need host decoding.

The source catalog must remain immutable throughout the runner lifetime. Tables
are runner-local, validate catalog metadata/preview/device/dtype before drawing
samples, and must be rebuilt for a new catalog. They are not serialized into a
training checkpoint and do not hold autograd graphs. The table is not a partial
cache: if the complete catalog exceeds its explicit cap, initialization fails.
There is no silent eviction or fallback. This is suitable for the current
40-clip LAFAN comparison; a large BONES catalog may require a separate bounded
paging strategy.

`resident_reference_usage(F,K,dtype,max_bytes)` is allocation-free and must be
included in admission **before** table creation. For Float32 the final payload
is `4*F*(71+73*K)` bytes. Construction uploads at most 256 rows at a time; the
chunk tensors and final concatenated table coexist, so the device build bound
is twice the final payload. The host build reserve is
`32*min(F,256)*(71+73*K) + 65536*(min(F,256)+K+1)` bytes, conservatively covering
source rows, preview temporaries and numeric conversion buffers. Existing
allocator, reference-store and process reserves must remain in force.

Per policy batch add `8*(H+1)*B` device bytes and
`32*(H+1)*B+8*B` host bytes for lookup indices. Existing reference/goal output
payload budgets are unchanged; no memory discount is claimed. The default
table cap is 1 GiB. About 441,000 frames with K=10 need 1,412,964,000 bytes, so a
LAFAN benchmark must explicitly allow at least that much, for example 2 GiB.
Construction must be reported separately from steady-state iteration time; it
is not free preprocessing.

CLI configuration uses `resident_reference_cache: true` and the explicit integer
`resident_reference_max_mib: 2048` for that LAFAN example. The default is false,
with a 1024 MiB cap if enabled without a size. Admission conservatively adds
twice the configured cap, host construction reserves, and policy/collection
lookup-index buffers to every phase without subtracting any original envelope.
The runner owns and reuses the table across physical collection and policy
updates, including runtime restore. A `resident-reference-cache-ready` report
records actual usage and runner construction time, separately from iterations.
One scalar readback at the end of CUDA construction completes its queued
uploads/concatenation before that report; no such readback is added per iteration.
MLP BF16 computation does not change the Float32 reference table.

`resident_references_wbtest.mbt` compares every output tensor bit and the next RNG
draws against the retained original route, over two consecutive batches of
1/256/257/4096 samples, Float32/Float64, both observation modes, noise enabled or
disabled, clip tails and repeated collection indices. It also checks admission
overflow and mismatched-table rejection before RNG consumption. Set
`MOONROBO_TENSOR_LIBRARY` to run the native CPU gate; explicitly setting
`MOONROBO_OPTIMIZATION_TEST_DEVICE=cuda:0` selects the GPU gate and fails if the
requested library/device is unavailable. These tests establish identical inputs
to the unchanged learner, not a measured training speedup or full-run checkpoint
equivalence.

A separate tiny runner gate additionally compares collected actions, iteration
metrics, runtime snapshots and the complete parameter/optimizer/normalizer state
digest after three updates with an intervening runtime restore. It verifies that
restore preserves the same immutable cache. This bounded fixture does not
replace production checkpoint or full-catalog performance comparison.
