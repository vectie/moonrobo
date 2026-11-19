# Optional learner microbatches

`Learner::new(..., world_microbatch=0, actor_microbatch=0)` retains the complete
batch implementation by default. A positive setting smaller than the actual
logical batch splits its batch axis only. Settings must not exceed the existing
`config.wm_batch` / `config.policy_batch`. `learner.batch_execution()` returns the
JSON-serializable `BatchExecutionPlan`. The [native CLI](cmd/README.md) now accepts
`wm_microbatch` / `pi_microbatch` and binds their effective values into preflight,
durable run/resume identity, distributed identity and reports. `LearnerConfig`
and learner checkpoint schemas remain unchanged; execution identity is stored
by the outer training generation.

World chunks retain all model fitting steps and divide every chunk's loss by
the original logical batch size. Gradients accumulate before one distributed
average, one clipping operation and one Adam update. The last-step metric sums
masked numerators and counts across chunks rather than averaging chunk means.

Actor chunks retain the entire imagination horizon and critic tail. Every tail
uses the same old critic normalizer and frozen world/critic weights. The actor
updates once after all backwards and one distributed gradient average. Detached
critic input is reassembled along the batch axis before flattening, preserving
time-major order. Critic normalization then updates once, followed by the original
GAE targets, supplied permutations, remainder allocation and optimizer schedule.
Actor-only updates continue to include the critic tail. The learner never draws
new samples, noise or permutations. Distributed calls compare the selected plan
and logical dimensions before entering either execution path.

This reduces the active world/actor autograd graph size; it still retains the
complete input batch and detached critic data. It does not reduce the logical
batch, relax any admission/cap, guarantee a measured peak, or make larger runs
safe without their existing preflight. Full critic minibatches remain unchanged.
Floating-point reduction and matrix shapes differ, so bitwise equality is not
claimed.

Metric readback now waits until all microbatches have completed. Each world or
actor chunk returns only three detached scalar tensors for its metrics; one
stack/readback copies them in chunk order, then the original CPU `Double`
accumulation runs in that same order. Critic losses retain at most 256 detached
scalars, read back each full block, and flush any remaining tail after the original
epoch/minibatch loop. CPU addition continues from the running total across each
flush; there is no block subtotal or device reduction. The usual twenty critic
steps still use one readback, while arbitrary longer schedules no longer grow
the metric list without bound. This changes neither sampling nor gradient
accumulation, clipping, Adam,
GAE, critic ordering, precision, or the complete-batch path. It retains no
autograd graph between chunks for metrics. At B128/micro16 with 10 world updates
and 20 critic steps, metric reads fall from 284 to 12; other synchronization,
including optimizer finite checks and physics transfers, remains. This count is
from the code, not a measured throughput improvement or new GPU parity result.

The narrow `microbatch metrics stay detached and packed readback preserves scalar
bits` CPU test checks scalar shape, FP32 dtype, explicit lack of autograd, the
fully masked final world chunk, and bit-preserving stack/readback across later
backwards. A separate boundary test covers empty input, twenty steps, 255/256/257
scalars, repeated flushes and a tail through 1025 scalars, including cancellation
across a flush boundary that rejects reordered CPU summation. Existing CPU
comparisons below also cover gradients, Adam and GAE;
`critic_trace_wbtest.mbt` covers the original 20-step critic sequence with and
without diagnostic readbacks. These LibTorch tests require the explicitly
supplied CPU-capable plugin; an unset variable prints `SKIP`, not numerical
validation.

On 2026-10-24 the five `microbatch_wbtest.mbt` tests and both
`critic_trace_wbtest.mbt` tests passed with the actual local CPU LibTorch plugin
(`sha256:2a5e3dd3ebf5d9c5e2ac147d7a65fa1beb8e724e02ebbeef42b2cccda24e6497`),
including the twenty-step critic trace. No CUDA run or speed measurement was
performed for this readback change. The previously retained CUDA full/split
numerical failure below remains unresolved.

CPU validation uses the actual LibTorch plugin, tiny networks, logical batch 5
and chunks `[2,2,1]`. The tests cover two 8-step world updates with unequal mask
counts and an all-masked final chunk; two complete 32-step actor/critic updates;
fixed nonzero sensor noise, time/sample-varying references and goals; nonzero
world action gradients; nontrivial supplied permutations; 2 critic epochs with
3 minibatches and a remainder; and actor-only behavior. Metrics, gradients,
parameters, Adam first/second moments and normalizers are compared within
explicit FP32 tolerances, while update counts/options are compared exactly.

```text
env MOONROBO_TENSOR_LIBRARY=/absolute/path/to/libmoonrobo_learning_tensor.dylib \
  moon test src/learning_aligned_gpu/microbatch_wbtest.mbt --target native --warn-list -a
```

Those original CPU tests alone do not validate GPU numerical parity or memory
peaks. The subsequent combined N4 CUDA one-iteration gate with paper-width
networks, bounded gather, compact replay and split=2 completed, and its stream-v2
CPU readback verified the held-state attestation. See the
[actual training report](../../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a/train/report.json)
and [readback log](../../output/spark-runtime-20261024/native-bounded-n4/runs/native-bounded-n4-training-20261024-a-readback/stdout.log).
This establishes execution and identity/checkpoint integration for that bounded
run. It does not compare full versus split numerics or establish convergence.
The subsequent [isolated CUDA numerical gate](MICROBATCH_GATE.md) completed both
full and split runs but **failed** the unchanged tolerance: 27 of 234,377,294
compared values exceeded it, all in critic first-layer weights after the two
actor updates (11 and 16 values respectively). Inputs and initial state matched;
other recorded arrays, including the extra GAE probes, passed. This is a retained
numerical failure, not successful equivalence. Full cgroup peak was observed,
but the split watcher missed the live process; its final point sample cannot
replace a peak, so no memory-saving claim is supported. See the linked gate
document for artifact hashes, exact metrics and evidence. NCCL numerical parity
remains separate. The existing Python and scalar MoonBit implementations remain
available.
