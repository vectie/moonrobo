# Native training optimization: second-stage design

Recorded 2026-10-24. Status: **design only**. No graph or bucket implementation,
SSH operation, GPU experiment, or performance claim was made for this document.
The implementation order requested by the user is timing, repeated-work removal,
LayerNorm, then graph replay and distributed communication. Complete and measure
the first stage before starting these candidates. Preserve the eager and current
per-parameter paths as independently selectable comparison implementations.

Implementation follow-up: after the parent agent reported first-stage code and
CPU validation complete, the C1 bucket candidate was added. Its exact implemented
contract and deferred GPU probe are recorded in
[`GRADIENT_BUCKETS.md`](../src/learning_tensor/GRADIENT_BUCKETS.md). The remainder
of this document is the original staged design, not execution evidence.

## Source findings

* `src/learning_tensor/adapter.cpp`: `mr_adam_step` requires every gradient,
  rejects nonfinite gradients before changing parameters, clips norm then value,
  and calls the existing C++ Adam. `mr_adam_zero_grad` calls C++ `zero_grad()`.
  In the pinned PyTorch 2.11 API its default is `set_to_none=true`; it cannot be
  reused between fixed-gradient graph replays without invalidating that design.
  Keep this legacy operation unchanged. [Pinned optimizer declaration](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/torch/csrc/api/include/torch/optim/optimizer.h)
* `src/learning_aligned_gpu/actor_microbatch.mbt`: the critic updates its
  normalizer once, creates bootstrap values and GAE targets, then performs the
  configured permutation/minibatch sequence. Each minibatch has one backward,
  optional gradient average, clipping and Adam update. The actor accumulates
  complete 32-step chunk gradients before one average and one Adam update.
* `src/learning_aligned_gpu/microbatch.mbt`: world chunks accumulate gradients
  before a single average and Adam update. A graph must not reset gradients
  between chunks or introduce additional optimizer updates.
* `src/learning_tensor/collective.inc`: `mr_nccl_average_gradients` validates
  distinct contiguous floating leaf parameters, creates zeros for missing
  gradients, and SUM-reduces each parameter in slices of **4M elements** before
  dividing by world size. `Collective::communicate` waits for the Torch stream
  and then for the communication stream for every slice. No cross-parameter
  buckets or backward/communication overlap exist in this path.

## G1: one critic forward/loss/backward graph

The smallest useful production candidate is one fixed-shape critic minibatch,
not the complete actor or training iteration. Leave sampling, reference work,
normalizer update, GAE, permutations, metric readback, gradient averaging,
finite checks, clipping, Adam, learning-rate changes and checkpointing eager.
Use exactly the same critic network implementation selected by the first-stage
configuration. Graph replay itself does not fuse its kernels.

PyTorch 2.11 has a real C++ entry point, `at::cuda::CUDAGraph`, with
`capture_begin`, `capture_end`, `replay`, `reset` and private-pool support. This
is not the Python-only `make_graphed_callables` interface. The current Docker
build already links `torch_cuda` and `c10_cuda`, but the new translation unit
must also compile against the matching CUDA headers required by the ATen graph
and stream headers. Check the pinned image's actual include paths; do not copy
C++ class declarations or depend on a different toolkit's ABI.
[Pinned C++ graph header](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/aten/src/ATen/cuda/CUDAGraph.h)

Proposed lifecycle:

1. Resolve the optional capability before allocating a graph. Check CUDA device,
   fixed shape/dtype/layout, precision policy, parameter order and graph budget.
   Retain a graph key containing network identity, selected LayerNorm route,
   shape, dtype, device and precision policy. Keep at most one shape in G1.
2. Own static input and target tensors, stable parameters and gradient buffers,
   detached loss storage, the CUDA graph and its capture stream. Use in-place
   `copy_` from each newly gathered minibatch into the static input/target.
   The normalizer stays outside; if the first-stage normalized-input reuse is
   selected, the static input contains precisely those normalized values.
3. Warm up only forward/loss/backward using the same network, with no Adam step,
   normalizer update, random draw, replay advance or sampler mutation. Clear the
   resulting temporary gradients. Warmup/capture must not count as training.
4. Capture on a non-default stream. Use an exception-safe, synchronous MoonBit
   wrapper over the opaque native graph so existing MoonBit network operations
   are captured without translating the network again into C++. Pin the owner
   OS thread; restore its previous stream on successful end and all error paths.
   Reject overlapping capture or calls from another thread. No `.values()`,
   telemetry synchronization, `.item()`, file I/O or NCCL calls inside capture.
5. Use one explicit gradient policy: preallocate and retain all expected critic
   gradients, capture their `zero_()` followed by forward/loss/backward, and
   verify after capture that backward retained the expected storage. That makes
   each replay a replacement of this minibatch's gradients. Do not call legacy
   Adam `zero_grad()` while the graph owns those buffers. Require all critic
   parameters to participate; do not silently turn an unexpected missing
   single-node gradient into a zero accepted by Adam.
6. Replay after the static copies, with stream event dependencies. Read/copy
   detached loss before its storage is overwritten by a later replay. Run the
   unchanged optional distributed average, finite check, clipping and Adam.
   Adam changes existing parameter storage in place; verify pointer stability
   rather than assuming all future optimizer implementations do so.
7. Destroy/invalidate the graph before checkpoint load, parameter replacement,
   dtype/device/shape/precision/route change or teardown. Rebuild after restore;
   graphs are runtime state and are not checkpoint payload. Fail an explicitly
   requested unsupported graph mode before training. Never silently call an
   eager route and label it a graph result.

Static addresses and fixed control flow are mandatory. Capture executes work
once; its result must not leak into the first real update. Graph-private pools
remain live across replays. Do not share pools in G1; a later sharing change
needs an explicit replay-order and lifetime proof. CPU synchronization and
concurrent uncaptured CUDA work are excluded during capture.
[PyTorch capture and memory constraints](https://docs.pytorch.org/docs/2.11/notes/cuda.html#cuda-graphs)

G2 may capture a fixed-shape world chunk after G1. It must use an accumulation
variant: clear the optimizer gradients once at the logical-batch boundary,
then accumulate every chunk with the original `1 / logical_batch` scale. A
remainder shape is a separately admitted graph or an explicitly reported eager
remainder, never padding that changes the loss. The complete actor is a later
candidate: preserve all 32 sequential transitions, soft survival, tail value,
frozen world/critic semantics and detached critic trajectory construction.

## C1: bounded cross-parameter buckets, without overlap

Add a separate optional `average_gradients_bucketed_v1` operation. Leave the
existing required ABI symbol and implementation intact. A proposed initial
bucket is **16 MiB**, with a validated explicit range of 1–64 MiB; these sizes
are experiment choices, not measured optima. Use a reusable contiguous scratch
buffer rather than a full-model flattening allocation.

1. Validate the complete parameter list before communication: count 1–4096,
   distinct leaves, floating dtype, communicator device, contiguous parameters
   and defined gradients of matching shape/dtype/device/contiguous layout.
   Undefined gradients become zeros, preserving existing distributed behavior.
2. Build a deterministic plan from parameter order, dimensions, dtype and
   bucket bytes. Process consecutive same-dtype segments without reordering
   parameters; flush a partial bucket on a dtype change. Split large parameters
   across buckets. Never pad an actual NCCL element count with uninitialized
   memory. Check Int64 size arithmetic for overflow.
3. Compare the plan identity across ranks through the existing signature/control
   mechanism before any data collective. Include selected communication mode,
   byte capacity, count/dtypes/shapes and slice sequence. All ranks issue the
   same count, datatype and order. Missing-gradient patterns must not influence
   the plan or skip a collective. NCCL requires matching collective inputs on
   every rank. [NCCL 2.28.9 collective contract](https://docs.nvidia.com/deeplearning/nccl/archives/nccl_2289/user-guide/docs/usage/collectives.html)
4. Pack slices under no-grad, perform in-place SUM AllReduce, divide by world
   size exactly once in the original dtype, then scatter back into the actual
   `parameter.grad` storage. Preserve clipping **after** the complete average,
   the norm-then-value order, and unchanged Adam update count/state.
5. Initially keep deadline-bound waits and failure handling around each bucket.
   One bucket buffer and at most 4096 current-slice descriptors suffice; stream
   the plan instead of materializing an unbounded list of all large-tensor
   slices. Keep a pending buffer alive until completion; communication failure
   aborts all ranks and retains possibly in-flight storage until process exit,
   as the existing path does.

C1 reduces collective and wait frequency but adds pack/scatter copies. It may
lose for a few large parameters, so measure both synchronization and copy cost.
The altered collective size can select a different NCCL reduction algorithm;
mathematical SUM/world equivalence does not imply bitwise floating equality.
No mixed precision, compression, reduce-scatter optimizer or clipping change
is part of C1.

## C2: readiness-driven overlap, a separate candidate

After C1 is accepted, a version-pinned native hook/reducer may mark a bucket
ready only after every contributing gradient has been accumulated. For actor
and world microbatches, enable readiness on the final backward of the logical
batch, after all earlier chunks' contributions exist. A pre-accumulation tensor
hook is not by itself proof that `parameter.grad` is complete. PyTorch's C++
autograd internals expose accumulation hooks but label those APIs internal;
isolate and version-check this integration.
[Pinned autograd declarations](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/torch/csrc/autograd/variable.h)

The compute stream records readiness; the communication stream waits on that
event, packs/reduces/scales/scatters, and records completion. The optimizer
stream waits for all bucket completions before finite checks and clipping.
Use deterministic bucket launch order across ranks even when local hooks fire
in different orders. Bound in-flight buffers, retain storage and deadlines,
and handle unused parameters at backward completion without deadlock. Two
buffers at capacity C cost at most 2C scratch, rather than one per bucket.
NCCL enqueues work asynchronously on the supplied stream, but adding events
after a fully finished backward does not create backward/communication overlap.
[NCCL 2.28.9 stream semantics](https://docs.nvidia.com/deeplearning/nccl/archives/nccl_2289/user-guide/docs/usage/streams.html)

CUDA graph replay does not rerun CPU autograd hooks. Keep C2 and a captured
backward mutually exclusive initially; a future combined graph would need
explicit captured event/communication dependencies and a separate distributed
capture audit. Do not advertise both switches as independent combinable wins.

## Memory, compatibility and ownership

| Candidate | Incremental lifetime to account for | Bound / policy |
| --- | --- | --- |
| Critic static input and target | Until graph destruction | `4 * minibatch * (critic_input_width + 1)` bytes in FP32; with 32×4096 samples, 4 minibatches and width 914: 119,930,880 bytes, about 114.4 MiB. |
| Captured activations/workspaces | Private graph pool persists between replays | Add pool reservation and concurrent eager allocations to every affected phase, including checkpoint save; no claim that eager peak is sufficient. |
| Gradient ownership | Graph lifetime | Reuse actual gradient storage; account for prolonged lifetime and any overlapping eager fallback buffers. |
| C1 scratch | One bucket / reusable communicator storage | At most configured C bytes of tensor payload, plus allocator rounding and bounded metadata; default proposal 16 MiB, maximum 64 MiB. |
| C2 scratch | At most two in-flight buckets | At most 2C payload plus events/metadata; separately admitted. |

Keep current admission percentages, reserve, physics/reference floors and zero
container swap. Preflight the added buffers and conservative pool estimate
before capture; record allocator reserved/allocated peaks and host/cgroup/CUDA
free memory after warmup, capture and replay. A capture measured in a bounded
diagnostic is not a universal graph-pool bound. The existing phase checks are
not a continuous no-OOM guarantee. Do not increase an admission cap, evict
system caches, create many shape graphs, or delete checks to make capture pass.

Proposed code ownership, after the first-stage shared-file work is merged:

* Native graph: new `src/learning_tensor/cuda_graph.inc`, optional symbols in
  `adapter.cpp`/`loader.c`, public wrapper `cuda_graph.mbt`, graph-specific
  native tests. Native owner coordinates the Docker and `.mbtx` build inputs.
* Learner graph: new `src/learning_aligned_gpu/critic_graph.mbt`; minimal routing
  hooks in critic update paths, explicit execution identity, graph lifetime
  owned by learner runtime. Do not duplicate the reward or GAE implementation.
* Communication: new `src/learning_tensor/collective_bucket.inc`, optional
  loader/wrapper methods and learner routing; retain `collective.inc` baseline.
* Admission/evidence: extend the existing native memory planner and paired-run
  `.mbtx` tooling; record graph/pool/bucket route and exact binary identities.

Keep ABI version 2 and load every new entry point with optional `dlsym` as for
telemetry/TF32. A feature is available only if its whole symbol family exists
and the runtime capability check passes. A CPU plugin can report unsupported.
Old plugins must still open and run the unchanged eager/current-collective
paths. Explicitly enabling an unavailable feature must fail early, clearly.

## Differential and paired measurement gates

1. Graph lifecycle checks: unsupported CPU/legacy plugin, shape/dtype/device
   mismatch, repeated create/destroy, capture error cleanup, tensor/gradient
   storage identity, no replay after restore or destruction. Warmup/capture
   must leave parameters, Adam steps/moments, normalizers, RNG and replay
   counters unchanged. Check repeated replays with alternating inputs and an
   intervening Adam update to catch stale input, stale weight or accumulated
   gradient bugs.
2. Compare eager/graph loss, predictions, gradients, parameter updates and Adam
   moments/steps from the same initial state and input sequence. For world
   capture, cover one chunk, several chunks and a remainder; verify the original
   normalization and single update. Reuse established numerical gates; do not
   relax a failing tolerance or require unsupported blanket bitwise equality.
3. Bucket tests: sizes 0/1/C−1/C/C+1, several tiny parameters, split large
   parameter, dtype transitions, distinct rank values and rank-specific missing
   gradients. Compare analytic SUM/world and baseline; cover NaN/Inf and require
   that the subsequent Adam check mutates neither parameters nor state. Reject
   mismatched plans before data collectives; retain timeout/abort evidence.
4. Run paired baseline/candidate processes from identical frozen checkpoint,
   replay and RNG/context/config with the same TF32 policy. Exclude warmup,
   alternate order, retain per-pair whole-iteration and phase medians/tails,
   actual route counters, memory peaks, build/config hashes and failed runs.
   Collect short profiling traces separately from timing runs. Report graph
   setup cost and checkpoint-inclusive throughput as well as steady-state.
5. For C1/C2, retain both ranks' timelines. Separate arrival skew, pack/scatter,
   NCCL enqueue/completion and optimizer wait. Keep per-rank logical batch,
   world-size learning-rate rule, update count and data schedule fixed when
   comparing communication implementations. Compare single-node independent
   seeds with DDP as a distinct learning-efficiency experiment.

There are no measured Stage 2 speedups yet. A source implementation or successful
capture alone is not evidence of improved end-to-end training throughput.
