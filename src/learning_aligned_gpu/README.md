# Device-tensor aligned learner

This parallel MoonBit implementation executes the aligned learning algorithm with
LibTorch tensor operations. Python and `learning_aligned.Learner` remain available
for independent comparison. `geometry` owns batched differentiable WXYZ state,
SO(3), forward kinematics, observations, rewards and critic features; `runtime`
owns bounded reference/replay batches and physical collection.

The CLI also supports `evaluate` and `export` for native tensor generations.
The [actor inference package](inference/README.md) loads only actor weights and
saved normalization, exports a self-contained reloadable artifact, and evaluates
complete training-catalog clips with normalized return and termination counts.
Its CPU roundtrip/protocol tests passed; physical evaluation results must be
established separately using the saved checkpoint and matching assets.

The parent package implements:

- Paper-size defaults from `learning_aligned.LearnerConfig`: world-model MLP
  2048×3 with SiLU/LayerNorm, history/preview 10, model window 8, imagination 32,
  policy goal encoder/history decoder and critic.
- Float32 resident weights, activations, gradients, optimizer state and running
  normalization. Initial parameters use the scalar MoonBit port's RNG and
  PyTorch Linear distribution/layout; they do not reproduce PyTorch seeded bit
  patterns. Fixed tensor weights are needed for strict cross-runtime comparison.
- Multi-step world-model loss, per-coordinate error floor and gradient clipping.
- Frozen world/critic parameter views that preserve gradients through their
  inputs. Whole imagined trajectories feed batched physical reward/FK, soft
  survival weights, discounted rewards and the critic tail. Actor gradients use
  norm 1 followed by value 0.1 clipping.
- Critic update after actor backward, using detached states from that same
  pre-update trajectory; normalization update before frozen values/GAE targets;
  epochs and remainder-first tensor-split minibatches. Imagined GAE assumes
  complete-horizon replay samples; it does not handle physical timeout truncation.
- Learner metadata plus three native Adam archives, preserving weights/moments,
  steps/rates and five normalizers. The enclosing runtime owns immutable
  generation publication, artifact identity, RNG, replay, histories, environment
  and counters. Discard a fresh learner if a multi-file restore fails.

`WorldBatch` uses `[batch,window,71]` WXYZ states and next states, actions 29,
xi 33 and masks. `PolicyBatch` contains initial state/previous action/xi, noisy
history, H+1 references/goals, explicit future sensor noise and critic sample
permutations. All floating inputs must be Float32 on the learner device.
Only selected scalar metrics and checkpoint normalization buffers are read back.

Verification with the actual local MoonBit → C → LibTorch 2.9.1 CPU path:

```sh
MOONROBO_TENSOR_LIBRARY=/ABSOLUTE/libmoonrobo_learning_tensor.dylib MOONROBO_GPU_CHECKPOINT_DIR=/EXISTING/TEST/DIRECTORY moon test --target native src/learning_aligned_gpu -v
```

The two tests passed matched scalar initialization/MLP/normalization/GAE, a
nonzero input gradient through a frozen network with no parameter gradients,
an 8-step model update and 32-step actor with imagined critic on tiny offline
numerical fixtures, and exactly equal next actor/critic losses and weights after
full learner save/restore. The separate geometry suite passed its scalar and
finite-difference comparisons. These are not physical-training results.

On 2026-10-24, the [179 single-host report](../../output/spark-runtime-20261024/native-cuda/runs/g1-native-cuda-gate-179-v3/report.json)
recorded a two-environment GB10 Float32 CUDA learner with CPU MuJoCo physics
and an exact checkpoint continuation through iteration 2. A separate
[178 rank-0](../../output/spark-runtime-20261024/native-ddp/178/runs/native-ddp-gate-20261024-c/rank-0/report.json)
and [179 rank-1](../../output/spark-runtime-20261024/native-ddp/179/runs/native-ddp-gate-20261024-c/rank-1/report.json)
native DDP gate completed one synchronized iteration, two environments per
rank. Each rank logged 36 physical and 64 imagined transitions and one model,
one actor and four critic update operations. Summed global work was 72/128
transitions and 2/2/8 rank-local operations, still one synchronized update
iteration. Both containers exited 0 without OOM-kill; NCCL used `NET/IB` with
`GDR 0`. Peak memory was not measured for that first run. Its saved
checkpoints later passed a CPU semantic comparison of actual shared state.
The subsequent `native-ddp-20261024-d` gate measured cgroup peaks of
3,062,317,056 / 3,065,729,024 bytes under 16 GiB caps, with zero OOM events;
both trainers also attested equal parameters, Adam state and normalizers
before saving. See the [transport, verification and memory evidence](../../docs/DGX_SPARK_CONNECTX7_RDMA.md).

The subsequent [native GPU physics gate](../../docs/DGX_SPARK_APIC_EXPORT_PLAN.md)
completed one two-environment iteration on 179 with native APIC physics and
the CUDA learner: 36 physical / 64 imagined transitions and 1/1/4 model,
actor and critic updates, with a saved checkpoint and no OOM observed.
The sampled kernel peak was 2,588,884,992 bytes under a 48 GiB cap; the final
lifetime peak was not certified after cgroup removal. Independent SDK
replay still has a retained per-element mismatch, so this execution result
does not establish physical equivalence or justify scale-up.

Remaining execution scope: sustained resource budgets, mixed-precision
autocast, distributed checkpoint resume, native GPU physics parity and end-to-end
matched-trajectory parity against `../smc`. This version is Float32;
requesting bf16 in the native runner must fail until an explicit autocast
path is provided. The small gates do not establish convergence or full
BONES-SEED training.
