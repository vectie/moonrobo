# Optional bounded gradient buckets

Implemented 2026-10-24; GPU correctness and throughput evidence must be recorded
by the paired-run owner before a speedup is claimed. The original
`Collective::average_gradients` and required ABI symbol remain unchanged.

`Backend::has_gradient_buckets()` checks the additive ABI-2 symbol only. It is
safe on CPU builds and old plugins. `Collective::average_gradients_bucketed`
requires `bucket_bytes` in **1–64 MiB** and 1–4096 parameters. The initial
candidate is 16 MiB, while the bounded differential probe uses 1 MiB to exercise
boundaries with a small allocation. An explicitly requested unavailable route
fails; it never silently runs the original route under a bucket label.

The new operation validates the entire local list before communication. Every
parameter must be a distinct contiguous floating leaf on the communicator's
device. Existing gradients must match its shape/device/dtype and be contiguous.
Missing gradients become zeros, matching the original distributed semantics.
Parameters keep their original order; a dtype change flushes a partial bucket.
Large parameters span buckets, while consecutive small parameters share one.
Each bucket performs SUM, division by world size in the original dtype, then
copies back into actual `parameter.grad`. No clipping or optimizer operation is
inside this function. The caller must finish all local chunk backwards before
averaging, then perform the unchanged finite check, clipping and Adam update.

Each rank must supply the **same ordered shapes/dtypes and byte capacity**.
Include this route/capacity in the existing learner execution signature and
joint launch identity. A rank-specific missing gradient never skips a bucket.
The low-level operation retains the base API's collective-order contract; it
does not add extra shape-signature collectives on every optimizer update.

One UInt8 backing tensor of exactly `bucket_bytes` payload is reused through
typed contiguous views. Each dtype view uses `floor(bucket_bytes / itemsize)`
elements; no uninitialized padding is reduced. At most 4096 slice descriptors
hold tensor references, not clones. Additional payload is **one bucket**, plus
any previously missing gradient buffers also required by the baseline, allocator
rounding and bounded host metadata. No full-model flattening allocation exists.
The memory admission calculation must add the bucket to any phase that performs
gradient averaging and retain the current reserve/percentage limits.

The initial implementation deliberately reuses the deadline-bound synchronous
`Collective::communicate`: it waits for the compute stream's pack operations,
then waits for NCCL completion. Division, scatter and the next pack use the same
compute stream, so reusing the backing storage is ordered. A communication
failure retains pending storage and requires terminating all ranks, as before.
This reduces launches/waits when several parameters fit a bucket; it **does not
overlap backward and communication**. Packing/scattering also adds work, so an
end-to-end paired measurement is required.

Loader integration is one trailing include in `loader.c`, after its existing
`valid_collective` and `handles` definitions:

```c
#include "collective_bucket_loader.inc"
```

There are no `Backend` layout changes or new required symbols. Rebuild the plugin
from the changed `collective.inc` and the normal adapter sources, and rebuild the
MoonBit executable with the new loader include. Keep frozen old binaries for
comparison.

## Differential probe

Build `src/learning_tensor/bucket_probe` for native release. On two CUDA ranks,
run the following with a fresh session, fresh ID paths and an external watchdog:

Use a bounded container with **`--ulimit memlock=1073741824:1073741824`**
for RDMA registration. The probe records `/proc/self/limits` and requires finite
memlock soft/hard limits between 1 and 8 GiB before opening CUDA/NCCL. Docker's
default 8 MiB caused an `ibv_reg_mr_iova2: Cannot allocate memory` initialization
failure without a cgroup/GPU OOM. Native failures include rank, operation stage
and the original library error payload. All numerical assertions remain enabled.

```text
bucket_probe /absolute/plugin.so 0 /absolute/fresh-id.json fresh-session-at-least-16-chars
bucket_probe /absolute/plugin.so 1 /absolute/copied-id.json fresh-session-at-least-16-chars
```

Rank zero publishes its ticket and remains alive in the live NCCL handshake.
Copy that ticket to rank one's requested path. Both ranks write exclusive
consumption records, enforce a 60-second rendezvous/collective timeout, and
require at least 16 GiB CUDA free before allocation. Keep transport/NCCL logs
and both rank outputs. This binary is a correctness probe, not a benchmark.

The probe compares original and bucketed reductions from deterministic identical
parameters, including element counts 0, 1, C−1, C and C+1, dtype changes,
rank-specific missing gradients, and three norm/value-clipped Adam updates.
All gradient elements are checked against analytic SUM/world. Parameters and
both Adam moments are compared through bounded 4096-element CPU reads, with
fixed `atol=2e-7`, `rtol=2e-6`; step/hyperparameter metadata must match exactly.
NaN and Inf cases verify rejection leaves parameters and Adam state unchanged.

CPU integration coverage uses `MOONROBO_TENSOR_BUCKET_LIBRARY` for a newly built
plugin and `MOONROBO_TENSOR_BUCKET_LEGACY_LIBRARY` for a frozen plugin without the
extension, then runs the tensor test named `gradient bucket capability ...`.
It checks capability discovery and continued CPU tensor execution, not NCCL
numerics. Keep CPU validation distinct from the deferred two-rank result.

Local validation completed: native C++ adapter compiled, MoonBit probe native
release build/check/info/fmt passed, and the new-vs-frozen CPU capability test
passed (1/1). The CPU adapter used for that test is
`target/learning-tensor-perf-bucket/libmoonrobo_learning_tensor_v2.dylib`, SHA-256
`efa5f4db4ea83b0bfd5948ccd3c4d5b903e03ba450cc0b892a45f9bd291c2427`.
No GPU or SSH operation was performed by the bucket implementation agent.
