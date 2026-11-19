# Optional CUDA allocator telemetry

The additive ABI-2 extension exposes:

- `Backend::has_cuda_memory_telemetry()` checks both extension symbols. It does
  **not** assert that CUDA or a usable allocator exists.
- `Backend::cuda_memory_stats(device, synchronize=false)` reads exact `Int64`
  aggregate allocated and reserved **current and peak** byte counts, plus CUDA
  runtime free and total bytes. `CudaMemoryStats` also records the device and
  whether this call synchronized. JSON encodes Int64 counters as decimal strings.
- `Backend::reset_cuda_memory_peaks(device, synchronize=true)` explicitly resets
  the allocator's peak counters to their current baseline. It does not release
  allocations, empty caches, or reset cumulative allocation counters.

No production learner, CLI admission cap, 65% budget or 24 GiB physics reserve
uses these APIs automatically. The completed full/split numeric gate and its frozen
plugin remain unchanged. This extension supplies observations for a later
calibration; it is not evidence that a larger batch fits.

`allocated_*` and `reserved_*` come from the active LibTorch allocator through
official `CUDAHooks` and `DeviceAllocator` interfaces, compiled against the exact
installed LibTorch headers. No CUDA toolkit headers, copied C++ vtable layouts,
Python runtime, or guessed mangled symbols are needed. The four statistics are
the aggregate entries in [PyTorch's memory statistics](https://docs.pytorch.org/docs/2.11/generated/torch.cuda.memory.memory_stats.html).
The pinned 2.11 [cudaMallocAsync implementation](https://github.com/pytorch/pytorch/blob/v2.11.0/c10/cuda/CUDAMallocAsyncAllocator.cpp#L640)
also supplies these four entries, using driver pool usage; its interpretation
does not distinguish allocated from active blocks. The API does not infer an
allocator backend name from environment variables.

These are **active allocator/pool peaks**, not total device peaks. With the native
allocator they track LibTorch-managed allocations. With `cudaMallocAsync`, other
libraries sharing the same default CUDA pool can also contribute. Warp, NCCL,
CUDA context/driver storage and other allocations outside the measured allocator
or pool are excluded. CUDA free/total are device-wide instantaneous observations
from the linked runtime. They are sampled after the allocator snapshot, so the
combined record is not an atomic global snapshot. Spark unified memory does not
make these counters interchangeable with cgroup RAM peaks. Preserve both records
when assessing actual headroom; summing them can double-count shared memory.

The ordinary read neither resets counters nor synchronizes by default. With
`synchronize=true`, pending work on the selected device is completed first; vendor
synchronization can block, so a launcher watchdog is still required. Calls must
be outside graph capture. Peak resets affect every user of that allocator in the
process. Record the reset point and the measured scope; a process-lifetime peak
and an iteration-window peak answer different questions. A training measurement
needs these calls **inside that training process**. A separate probe cannot read
another process's allocator peak.

CPU/no-device, unavailable or uninitialized allocators, known uncached mode
(`PYTORCH_NO_CUDA_MEMORY_CACHING=1` or its HIP alias), missing extension symbols,
and vendor errors raise `TensorError::Native`. They never become zero-valued
success records. Initialize the selected device through normal tensor use before
querying; the read refuses a missing primary context rather than selecting and
initializing an unused device. The read itself creates no tensor. The official
generic `DeviceGuard` preserves PyTorch's logical-device TLS and deferred
restoration; it does not use raw `cudaSetDevice` to restore an unused prior GPU.

The measurement contract requires a fixed, enabled caching allocator for the
process. Do not change cache-related environment variables after initialization
or disable/bypass caching programmatically. The generic `DeviceAllocator` API
does not expose CUDA-specific `isEnabled()`: this extension cannot verify an
external `enable(false)` call, which can leave old or zero allocator counters
despite live untracked allocations. No such mutation is performed by this API or
the current native learner. This is a disclosed caller precondition, not a claim
that every cache-disable mechanism is detected. Custom allocators must implement
meaningful `DeviceAllocator` statistics or throw.

## Compatibility and build

The plugin ABI remains 2. New loader symbols are optional, and existing training
operations can still use old plugins. Calling telemetry on an old plugin reports
the missing extension and requests a rebuild. Neither a missing symbol nor a CPU
build is a capability success with zero counters. Rebuild the plugin from
`adapter.cpp`, `collective.inc` **and `telemetry.inc`** using the normal matching
LibTorch build procedure. A source-only staging list must include the new include.

The CPU regression invocation is:

```sh
MOONROBO_TENSOR_TELEMETRY_LIBRARY=/absolute/new-cpu-plugin.dylib MOONROBO_TENSOR_LEGACY_LIBRARY=/absolute/old-abi2-plugin.dylib moon test src/learning_tensor/telemetry_test.mbt --target native --release
```

Unset paths produce explicit integration skips. The non-plugin test verifies
exact JSON round trips above 2^53; it is not a CUDA runtime test.

## Bounded, opt-in device probe

```sh
moon build src/learning_tensor/memory_probe --target native --release
_build/native/release/build/vectie/moonrobo/src/learning_tensor/memory_probe/memory_probe.exe /absolute/new-plugin.so
```

The probe selects device 0 and first requires both query and reset to reject the
uninitialized allocator/context, matching that specific error rather than any
failure. It then keeps a one-element anchor, resets a measurement
window, allocates a fixed 1 MiB Float32 tensor, verifies its sum and live/released
allocator counters, then verifies a second reset. It prints one JSON report;
failure is nonzero. Its report explicitly records
`programmatic_cache_disable_checked=false`; it does not claim an external cache
disable was detected. Host Double inputs are fixed at 2 MiB. CUDA context and runtime
initialization are additional costs; use the existing bounded container and
watchdog. This probe does not run training or replace its memory guard.

Run the explicit environment-disabled negative case in a separate fresh process:

```sh
PYTORCH_NO_CUDA_MEMORY_CACHING=1 _build/native/release/build/vectie/moonrobo/src/learning_tensor/memory_probe/memory_probe.exe /absolute/new-plugin.so --uncached-negative
```

This mode requires an accessible GPU and that exact environment flag, verifies
both calls fail specifically because tracking is bypassed, and verifies a
subsequent one-element GPU tensor operation. Only those successful assertions
produce `status:passed` and exit zero; CPU, missing symbols and arbitrary failures
cannot masquerade as a successful negative case. It reports no memory counters
and makes no claim about programmatic cache disable or multi-GPU restoration.

All three narrow CPU regression tests passed against the new CPU plugin and the
unchanged prior ABI-2 plugin. Local validation covers CPU compilation, explicit
unsupported and legacy-plugin errors, ordinary tensor operation after each
error, exact Int64 serialization, and probe compilation.

## Actual Spark GPU probe: 2026-10-24

The source-c package was built against pinned LibTorch **2.11.0** and CUDA on
node 179. The separate
[positive report](../../output/spark-runtime-20261024/native-tensor-telemetry/runs/native-tensor-telemetry-20261024-c/positive.json)
passed the uninitialized query/reset refusals, fixed 1 MiB allocation, numerical
sum, release, synchronization and explicit peak reset checks on device 0:

| Sample | Allocated current bytes | Allocated peak bytes | Reserved current/peak bytes |
| --- | --- | --- | --- |
| Baseline | 512 | 512 | 2,097,152 |
| 1 MiB tensor live | 1,049,088 | 1,049,088 | 2,097,152 |
| Tensor released, after reduction | 512 | 1,050,624 | 2,097,152 |
| Explicit second reset | 512 | 512 | 2,097,152 |

The independent environment-disabled
[negative report](../../output/spark-runtime-20261024/native-tensor-telemetry/runs/native-tensor-telemetry-20261024-c/negative.json)
also passed: query/reset were rejected specifically for uncached mode and a
subsequent GPU tensor operation succeeded. Both fresh containers had an 8 GiB
memory limit, zero swap allowance and 2 CPUs; both exited 0 with `OOMKilled:false`
in the retained [container states](../../output/spark-runtime-20261024/native-tensor-telemetry/runs/native-tensor-telemetry-20261024-c/docker-final.json).

The [runtime hashes](../../output/spark-runtime-20261024/native-tensor-telemetry/runs/native-tensor-telemetry-20261024-c/runtime.sha256)
pin probe `c0e7256111714c65fa868b410034744a50e2cbbf827eb51012b1ade4a76ba14a`
and new plugin `226e18f2cd6cbfbdfbf0a7b6faab1b8833440746eac17fd5d377205db75852d4`.
The separate [arm64 image](../../output/spark-runtime-20261024/native-tensor-telemetry/runs/native-tensor-telemetry-20261024-c/image.json)
is `sha256:3478a8a6a5aec9eafb9d74d96a6253c5b0c256c53a8f4c05c732902df5221c24`.
The original frozen training/numerical-gate plugin remains unchanged at
`a1176bb28ce4fb928006c7e5db20fbe1b693bcabab6d482e0f766a00ad802f1f`.

This verifies the bounded single-device probe, not allocator peaks inside a
training process. Multi-GPU device restoration, `cudaMallocAsync` runtime
behavior, and programmatic cache disable remain unverified. The independent
probe neither retroactively measures earlier training nor establishes a
full/split memory saving or larger-batch capacity. The existing 65% admission
rule, 24 GiB physics reserve and all caps remain unchanged.
