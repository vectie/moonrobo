# Optional device-resident LibTorch operations

`Backend::open(path)` loads the C++ LibTorch plugin explicitly. Ordinary native
MoonBit builds compile only `loader.c` and do not link LibTorch. ABI **2** is
required; rebuild the plugin when updating the loader because its required symbol
set now includes the NCCL entry points. No Python
runtime or pybind dependency is used by the plugin.

Available operations include:

- Leaf creation on CPU (`cuda_device=-1`) or a chosen CUDA device, with Float64,
  Float32, BFloat16, Int64 or Bool storage. Float64 stays the default for existing
  callers. Host creation/readback uses one bulk transfer per tensor; intermediate
  results, gradients and optimizer moments stay on the selected device.
- Broadcast arithmetic, batched matmul, reshape, narrow, axis transpose,
  reductions, stack/concatenation, index-select, clamp, affine, SiLU, sigmoid,
  tanh, exp, square, sqrt and log.
- Scalar backward with optional graph retention, detach, leaf gradients, and a
  selected vector-Jacobian pullback without accumulating leaf gradients.
- Adam with configurable betas, epsilon and learning rate; clipping and rejection
  of missing/nonfinite gradients before updates. A step performs a single combined
  finite-gradient check readback, plus the LibTorch clipping check when enabled.
- Atomic save/restore of ordered parameters, Adam moments, step counters and
  hyperparameters. Restore validates parameter count, shapes and dtypes before
  applying state. This is **not** a complete learner checkpoint: RNG, replay,
  normalization and training counters remain the enclosing learner's responsibility.

Tensor and optimizer handles are finalized by MoonBit; the plugin stays loaded
for process lifetime because LibTorch owns global thread pools. Exceptions are
returned as `TensorError::Native`. A backend's error buffer is not thread-safe;
concurrent callers must use separate backend handles. Host values use Double;
Int64 values above the exact Double integer range cannot be represented through
this host creation/readback API.

Build against the exact LibTorch used for training:

```sh
cmake -S src/learning_tensor -B target/learning-tensor -DCMAKE_PREFIX_PATH=/ABSOLUTE/torch/share/cmake
cmake --build target/learning-tensor --parallel 1
```

The output is `libmoonrobo_learning_tensor.so` on Linux or `.dylib` on macOS.
Run the focused CPU integration test with the explicit built plugin path:

```sh
MOONROBO_TENSOR_LIBRARY=/ABSOLUTE/libmoonrobo_learning_tensor.so MOONROBO_TENSOR_CHECKPOINT=/ABSOLUTE/test-adam.pt moon test --target native src/learning_tensor -v
```

Without the environment variable, the test prints an explicit skip; that result
is not numerical validation. On this workstation the actual MoonBit → C loader →
LibTorch 2.9.1 CPU path passed fixed Float32 forward/gradient values, batch/index
operations, BFloat16 readback, and exact equality of the next Adam update after
saving/restoring weights, moments and learning rate. Invalid checkpoint and
missing/nonfinite-gradient refusals are covered. This does not establish CUDA,
bf16 training, memory capacity, DDP or full paper parity.

The original `learning_aligned.Learner` still uses scalar `numeric.Tape` and host
`Array[Double]` state. The parallel `learning_aligned_gpu` package now uses this
API for batched geometry, normalization, 8-step world-model fitting, 32-step actor
imagination and GAE critic updates. Its tiny CPU integration and exact learner
resume tests pass. CUDA/GB10 validation, mixed-precision autocast, distributed
validation and end-to-end matched-trajectory parity remain separate work.

`Backend::cuda_free_bytes(device)` queries the CUDA runtime linked by the loaded
LibTorch plugin, preserving the active device. Symbols are resolved from the
plugin dependency graph, so the C++ adapter does not need CUDA toolkit headers.
CPU-only plugins fail explicitly instead of inventing a memory budget.

The optional [CUDA allocator telemetry extension](CUDA_MEMORY.md) adds active
allocator/pool allocated/reserved current and peak counters, device-wide free/total observations,
and explicit peak resets. Old ABI-2 plugins remain loadable; telemetry calls fail
explicitly when unavailable. The independent fixed-1-MiB probe has now passed
on node 179 with pinned LibTorch 2.11.0/CUDA, including uninitialized refusal,
live/released counters, explicit peak reset, and a separate environment-uncached
negative case with successful subsequent GPU arithmetic. Both 8 GiB/zero-swap
containers exited 0 without an OOM kill; [reports and hashes](CUDA_MEMORY.md#actual-spark-gpu-probe-2026-10-24)
retain the exact evidence. The original frozen training plugin remains unchanged.
This does not measure training-process allocator peaks or verify multi-GPU,
`cudaMallocAsync`, or programmatic cache disable. Training, caps and memory
admission rules are unchanged.

The optional [startup CUDA FP32 control extension](TF32.md) adds separate
LibTorch 2.11 matmul, cuDNN-convolution and cuDNN-RNN precision readback and
explicit configuration. It checks override conflicts and seals configuration
across Backend handles once this plugin begins creating tensors. Old ABI-2
plugins remain usable and missing extensions fail explicitly. CPU negative
checks pass, and all four independent bounded modes passed on node 179 with
LibTorch 2.11.0/CUDA: IEEE, TF32 matmul, TF32 all settings, and an override-conflict
negative case. All four fresh 8 GiB/zero-swap/2-CPU containers exited 0 without an
OOM kill; [reports, pins and limits](TF32.md#actual-spark-gpu-probe--2026-10-24)
retain the evidence. The training CLI now has an explicit optional
[`allow_tf32` policy](../learning_aligned_gpu/cmd/README.md#explicit-cuda-fp32-policy)
whose absence preserves defaults; the new wiring has CPU contract checks and
awaits its separate integrated GPU gate. Frozen plugins remain unchanged. The probe does not establish
kernel dispatch, cuDNN-kernel execution, speed, training behavior or peak memory;
the NCCL-control-first startup seal has not been runtime-tested.

`Adam::audit_metadata()` returns deterministic JSON for ordered state-presence
flags, exact decimal-string Int64 step counters, parameter-group indices and all
Adam hyperparameters. String steps match MoonBit's Int64 JSON representation and
avoid rounding beyond 2^53.
`Adam::audit_tensor(index, kind=0|1|2|3)` exposes detached shared-storage views of
parameters, first moments, second moments and optional AMSGrad maxima. Treat
these views as read-only and slice before `values()` to bound host transfers.
This allows semantic checkpoint comparisons without hashing Torch's process-local
pointer IDs embedded in archives. Audit exports are optional: older plugins
still open, but audit calls explicitly request a rebuild. The CPU integration
checks exact metadata and moment equality after checkpoint restore.

## Optional NCCL collectives

`Backend::nccl_id()` creates a 128-byte rendezvous ID. Keep its process alive
while distributing the ID to all ranks, then call
`backend.nccl_connect(id, rank=rank, world_size=2, cuda_device=0, timeout_ms=30000)`.
Both rank and CUDA device are local explicit settings; the launcher must supply
the same ID and world size. This supports 2–16 ranks and requires the exact
**NCCL 2.28.9** library from the loaded LibTorch dependency graph. It resolves CUDA
and NCCL dynamically and needs no extra CUDA/NCCL build-time headers. The verified
public configuration layout is from [NVIDIA's pinned header](https://github.com/NVIDIA/nccl/blob/v2.28.9-1/src/nccl.h.in).

The synchronous `Collective` interface provides:

- `all_reduce(tensor, op=Sum|Max|Min)`: a detached contiguous result without
  changing the input; clone limited to 256 MiB. Float32, Float64, BFloat16 and
  Int64 are supported on the communicator's CUDA device.
- `broadcast(tensor, root=0)`: in-place contiguous tensor broadcast under
  `no_grad`, useful for initial parameters and normalization statistics.
- `average_gradients(parameters)`: SUM/world into each actual parameter's `.grad`
  before the caller clips gradients and steps Adam. Missing gradients become
  zero. It communicates slices of at most 4M elements directly, avoiding a
  full-model flat allocation. Parameter ordering must match across ranks.
- `control(Array[Int64], op=Sum|Max|Min)`: exact integer reduction of 1–8192
  values for readiness, counters and identity bytes; this bypasses Double's
  integer range limitation. `barrier()` reduces one integer.
- `close()`: idempotent communicator abort/close. Handles also have finalizers.

One caller may use a communicator at a time. Every rank must issue matching
operations, shapes and dtypes in the same order. Callers must agree on model and
configuration identity before broadcasting. The adapter waits for the correct
LibTorch current CUDA stream, submits NCCL on a dedicated nonblocking stream,
then polls its completion and NCCL asynchronous errors. Polling deadlines are
bounded to 100–300000 ms. A process watchdog is still necessary for a stuck
vendor or driver call that does not return. Every failure requires terminating
all ranks; there is no fallback, retry or reuse of a failed communicator.
Potentially in-flight buffers are deliberately retained until process exit on
failure, so errors must not be caught and followed by continued training.

The CPU plugin builds and the negative integration test verifies malformed
IDs/ranks/timeouts and explicit CPU rejection. Actual two-rank GPU operation,
timeout injection and distributed learner parity remain runtime validations;
the existence of this API is not evidence that DDP training has passed them.
