# SMC/native execution attribution and checked-norm Adam — 2026-10-24

The earlier approximately 6.26× throughput ratio is a contextual comparison,
not an isolated language/runtime effect. The original SMC run used BF16 MLPs,
compiled tensor functions, GPU-resident data, Smc99 observations, full actor
batches and 500 world-only iterations. The native run used FP32/TF32, Paper93,
actor microbatches and a different fresh-run history. Preserve those historical
results and use the short protocol below for new controlled attribution.

## Unmodified SMC 2×2 protocol

Keep `../smc` sources read-only and hash them with the runtime image, Torch,
motion catalog and robot artifacts. Root's common short protocol is N256,
seed 0, 64 initial physical steps, 20 world-only iterations, 60 total iterations,
and retained steady iterations 41–60. The common SMC CLI is:

```text
python -u /workspace/supermimic/supermimic/train.py
  --num_envs 256 --seed 0 --warmup_steps 64 --wm_only_iters 20
  --iterations 60 --log_every 1 --ckpt_every 2000
  --wm_batches 10 --wm_batch 2048 --pi_batch 4096
  --wm_window 8 --horizon 32 --hist 10 --goal_frames 10
  --critic_epochs 5 --critic_minibatches 4 --buffer_steps 1000
  --utd 0.4 --gamma 0.99 --lam 0.95 --lr 0.0002
  --lr_decay_iters 250000 --action_noise 0.1
  --motion_dir ABSOLUTE_FROZEN_MOTION_DIRECTORY --log_dir FRESH_DIRECTORY
  --amp CELL_VALUE
```

Use the existing container/launcher arguments unchanged. Do not use `--resume`:
the original resume path does not refill an empty replay buffer. Checkpoint
publication still occurs at iteration 60 and is excluded from the training
window while retained in total process time and memory accounting.

| Cell | `--amp` | `TORCH_COMPILE_DISABLE` | `TORCHDYNAMO_DISABLE` | Throughput `SM_PROFILE` |
| --- | --- | --- | --- | --- |
| FP32/TF32 compiled | `none` | `0` | `0` | `0` |
| FP32/TF32 eager | `none` | `1` | `1` | `0` |
| BF16 compiled | `bf16` | `0` | `0` | `0` |
| BF16 eager | `bf16` | `1` | `1` | `0` |

Set switches before the fresh process imports Torch. Local installed Torch
source and pinned official v2.11.0 source both confirm that
[`TORCH_COMPILE_DISABLE`](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/torch/_dynamo/config.py)
sets the Dynamo config flag, checked in
[`convert_frame.py`](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/torch/_dynamo/convert_frame.py).
[`TORCHDYNAMO_DISABLE=1`](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/torch/_dynamo/eval_frame.py)
also makes the optimize decorator a no-op. Both switches are explicit here to
avoid an inherited disabling variable. This verifies the control mechanism,
not which kernels ran in a particular remote image; preserve that image's
package/version identity and diagnostic compile logs.

Unset `TORCHDYNAMO_SUPPRESS_ERRORS`; in the inspected version its parser is
`bool(environment_string)`, so setting it to `0` still enables suppression.
Do not silently convert compile failures to eager results. Use
`TORCH_LOGS=graph_breaks,recompiles` only in separate diagnostic runs, retain
stderr, and record compilation/cache artifacts. Each cell starts fresh with a
consistent declared cache policy, bounded compile workers (two), the same
100 GiB/no-swap/12-CPU process limits and existing one-second memory guard.
Do not run cells concurrently or increase their batch/budget during comparison.

SMC's `train.py` explicitly enables CUDA matmul and cuDNN TF32 for every cell.
Therefore `--amp none` is FP32 storage with TF32 permitted, not IEEE-FP32 GEMM.
`--amp bf16` affects the MLP autocast scope in `networks.run_mlp`; its output is
cast back to FP32 and geometry/state/reward work stays outside that scope.
Record inherited TF32 overrides. Default `torch.compile` also does not by
itself prove CUDA graph replay; attribute fusion/compilation and replay separately.

Use ABBA fresh-process pairs at each precision for compile/eager comparisons,
and at each compile setting for BF16/FP32 comparisons. Aggregate exactly the
same 20 retained iteration numbers in every run, preserving per-run medians,
means, p90, raw samples and adjacent-pair ratios. Report interactions: a BF16
gain under compilation need not equal its gain under eager execution. Numerical
trajectories can differ due to precision and compiler RNG paths despite the
same seed; these runs are workload attribution, not bitwise equivalence tests
or convergence claims. Never pair these runs with the old 500/600-iteration run.

For cross-runtime work, native supports `observation_mode="smc"` (99 inputs),
so this shape difference can be aligned by configuration. Paper93 would change
the policy decoder's first input width from 1022 to 962. Align self-collision
off through a verified native scene/config if possible; SMC hard-codes it off.
The simulator implementation, GPU-resident vs host replay/reference data,
sampling/RNG behavior, actor microbatch execution, optimizer finite-check policy
and logging/telemetry boundaries still require explicit disclosure. Matching
scalar CLI values does not make the entire learning problem or timing boundary
identical. A full actor batch must pass native memory admission rather than
being forced merely to match SMC's execution shape.

## What SM_PROFILE actually measures

Read `../smc/supermimic/train.py` directly; `SM_PROFILE=1` adds synchronizations
to **every actor update**, not only the periodic outer profile line. Keep it
out of the principal throughput runs and use the same 2×2 settings for a
separate instrumented diagnostic. All values print rounded to integer ms.

| Original log label | Included work |
| --- | --- |
| `imagine fwd` | Replay valid-start sampling, initial observation/noise/reference preparation, 32-step imagination, flattened rewards/soft survival, tail critic and policy loss |
| `bwd` | Policy zero-grad and loss backward, followed by CUDA synchronization |
| `critic` | Policy norm/value clipping and Adam, restoring requires-grad flags, critic feature construction/normalizer update/GAE, all 20 critic updates, final synchronization |
| `collect` | Physical collection plus policy observation/goal/world normalizer updates; synchronized boundaries |
| `wm` | Ten world updates including replay sampling, compiled rollout/error, backward, clipping and Adam |
| `policy+critic` | The full policy-update routine, including its own profiling synchronizations and print overhead |

The outer profile line is conditional on zero-based `it % 20 == 0` and
`it > wm_only_iters + 5`. Under the 20/60 protocol it occurs only at `it=40`,
which is CSV iteration 41. It does not provide 20 steady samples of collect/world
time. Inner actor profile lines cover iterations 21–60. Do not fabricate outer
phase percentiles from one sample or label `critic` as pure critic compute.

A bounded parser should collect the inner/outer `[prof]` lines pending the next
`it K | ...` line, then attach CSV iteration K (or internal index K−1). With
`--log_every 1` the mapping is unambiguous; reject duplicates, malformed numeric
fields, unexpected outer cadence and an incomplete final pending block. Keep
raw line numbers and label unavailable outer measurements absent. Compare
outer policy+critic with the sum of the three inner fields as a consistency
check allowing rounding/print overhead, not an equality assertion.

Original `train_log.csv` `it_per_s` with log_every=1 measures the interval since
the previous pre-log timestamp: current scalar averaging/printing is excluded,
while the previous log tail is included. `wall_h` is printed with limited
precision and is not a nanosecond interval source. Native synchronized telemetry
also changes the boundary. Report this distinction and use stable-window totals
and fresh-process ABBA comparisons; do not describe raw cross-runtime per-row
ratios as identical synchronized kernel measurements. The shared 2/3 physical
step alternation at UTD 0.4 should remain represented by a complete even-length
steady window.

## Optional native candidate: reuse checked L2 norm in Adam

The current native path first creates per-parameter finite masks/reductions and
reads a combined Boolean to the host. It then calls LibTorch C++
`clip_grad_norm_(..., 2, error_if_nonfinite=true)`, which computes the ordered
L2 norm and reads it to the host again. The
[official C++ header](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/torch/csrc/api/include/torch/nn/utils/clip_grad.h)
explicitly documents a device/host synchronization even if its finite-norm
check is disabled, because it returns a host double. Merely setting that check
false does not remove the return-value synchronization and weakens overflow
handling.

The additive `adam_checked_norm` candidate computes the **same per-parameter
L2 norms in the same order**, uses the single-norm/no-stack special case, and
reads the same total norm once. A finite L2 result certifies finite gradients.
It reuses that device/dtype norm tensor for the original epsilon, coefficient
clamp and norm clipping, then unchanged value clipping and Adam. Missing
gradients are rejected before any work. If the norm is nonfinite, a slow-path
finite scan distinguishes NaN/Inf gradients from finite gradients whose norm
overflowed; both are rejected before gradient/parameter/optimizer mutation.
With `clip_norm=0`, it delegates to the unchanged original finite-mask route.

The optional ABI-2 symbol is `mr_adam_step_checked_norm_v1`. API:
`Backend::has_checked_norm_adam()` and
`Adam::step_checked_norm(clip_norm~, clip_value~)`. The existing `Adam::step`
remains default; an explicit new route on an old plugin fails. New implementation
files are `adam_checked_norm.inc`, `adam_checked_norm_loader.inc` and
`adam_checked_norm.mbt`. No full gradient flattening, persistent graph pool or
optimizer replacement is introduced: ordinary extra storage is O(parameter
count) norm scalars/metadata, replacing large temporary finite masks. The rare
failure path keeps the existing bounded-by-gradient-size finite scan.

Integration must preserve every world/policy/critic optimizer boundary, LR,
betas, epsilon, update count and clip limit. Run after distributed averaging,
outside CUDA graph capture. Include the flag in checkpoint/execution identity
and reject unsupported requested capability before collecting training data.
Expected savings are one ordinary-path host wait per clipped optimizer update
(31 per normal iteration) plus finite-mask launches/traffic. This is a candidate,
not an explanation of the entire earlier 6× gap or a measured speedup.

The bounded differential suite compares gradients after clipping, parameters,
both moments and step/hyperparameter metadata across multiple Float32/Float64
updates; it includes norm/value/unclipped routes, zero/single/empty tensors,
missing gradients, NaN, Inf, and finite Float32 gradients with overflowing L2
norm. Failure cases assert unchanged gradients, parameters and populated Adam
state. CPU tests precede the same suite on CUDA; the latter is launched only by
the run owner. Then compare one-flag-only ABBA full training runs with identical
sampling/precision/geometry and retain Adam subphase time, complete iteration
time and memory peaks. Keep the default unchanged unless that evidence supports
the candidate. LayerNorm/BF16 changes and data-path work are owned separately
and must not be bundled into the first Adam comparison.

Local validation completed: combined C++ CPU plugin build, package check/info/fmt,
and all three checked-norm differential tests passed (including the frozen old
plugin capability test). The validation plugin is
`target/learning-tensor-perf-checked-norm/libmoonrobo_learning_tensor.dylib`, SHA-256
`a3b38635d9454dc24fdf3c0117df63762551eff039bf0e88febad18e5494b4b0`.
Run the same test file with `MOONROBO_TENSOR_CHECKED_NORM_LIBRARY` pointing to the
new plugin, `MOONROBO_TENSOR_CHECKED_NORM_LEGACY_LIBRARY` pointing to a frozen
plugin without this extension, and `MOONROBO_OPTIMIZATION_TEST_DEVICE=cuda:0`
for the separately authorized GPU gate. Omitting the device variable selects
CPU; omitting library variables skips integration tests and is not validation.
No SSH or GPU operation was launched by this implementation agent.

## Actual learner routing and deferred scalar metrics

All six world/policy/critic Adam boundaries in full-batch and microbatch paths
now call `Learner::optimizer_step`. `adam_checked_norm=false` calls the original
`Adam::step`; true selects the additive operation. `Learner::new` rejects a
requested missing capability before constructing networks. Distributed gradient
averaging remains before the helper and clipping/Adam remain outside graph
capture. No learning rate, optimizer hyperparameter or update count changed.

The independent opt-in `defer_scalar_metrics=false` controls only the full-actor
critic loss readbacks. With it enabled, the existing `CriticLossMetrics` helper
holds at most 256 detached scalar snapshots and then performs one bounded
stack/readback, preserving the exact original sequential CPU Double addition
order across flushes. The default 20 critic minibatches therefore need one
critic-metric readback instead of 20. The microbatch path already used this
helper and remains unchanged; world metrics and the final policy/reward/survival
readbacks are unchanged. Graph replay returns owned detached scalar clones, so
the next replay cannot overwrite pending metrics. Memory admission adds a
conservative 1 MiB for scalar allocator rounding, metadata and stack payload.

The actual learner CPU gate passed **2/2 tests** using the same validation plugin
above. It exercised checked-norm alone, deferred metrics alone, and both together
under full-batch and split-by-two execution: six route/plan combinations, each
with two eight-step world updates, two 32-step actor/critic updates and one
actor-only update. Fixed sensor noise, critic permutations/remainder routing,
normalizers, gradients, parameters and populated Adam states matched exactly;
critic metric Double bits also matched. A separate old-plugin constructor test
confirmed early capability rejection. This is a small numerical gate, not a
throughput or convergence claim.

For the run owner's GPU gate, point `MOONROBO_TENSOR_LIBRARY` at the new plugin,
set `MOONROBO_OPTIMIZATION_TEST_DEVICE=cuda:0`, retain the old-plugin variable,
and run:

```text
moon test src/learning_aligned_gpu/optimizer_execution_wbtest.mbt --target native --release --warn-list -a
```

The two configuration fields are independent Booleans named
`adam_checked_norm` and `defer_scalar_metrics`, both defaulting false. Measure
each independently before combining them; defer-only preserves per-step updates
and metric arithmetic but changes when host synchronization occurs.

## Native LayerNorm CUDA failure: numerical cause and retained exclusion

The [preserved labeled failure](../output/spark-runtime-20261024/optimization-stage1-20261024-a/layernorm-gpu-labelled-failure.log)
occurs **before backward or Adam**, at Float32 near-constant fixture 1,
shape `3x4`, iteration 0, output 0. Native is `0.07307180017232895`;
expanded is `0.07304610311985016`. Their absolute difference is
`2.5697052478790283e-5`, or about `0.03518%` of the expanded value. The unchanged
gate is `2e-6 + 2e-4 * abs(expected) = 1.6609220623970034e-5`; the difference is
**1.547 times that limit**. Native remains unaccepted, and the frozen E groups
retain expanded LayerNorm.

Source inspection and FP32 arithmetic reconstruction point to reduction-order
rounding amplified by subtraction near the mean, not an epsilon, affine or
population-variance mismatch. The wrapper calls `torch::layer_norm` with last
dimension 4 and epsilon `1e-5`; expanded computes mean then mean squared centered
values. Both divide variance by N. PyTorch documents the
[biased estimator / correction zero](https://docs.pytorch.org/docs/2.11/generated/torch.nn.LayerNorm.html).
Its [CUDA implementation](https://raw.githubusercontent.com/pytorch/pytorch/v2.11.0/aten/src/ATen/native/cuda/layer_norm_kernel.cu)
uses vec4 Welford accumulation when eligible, followed by reciprocal-square-root
normalization; this differs in floating-point operation order from expanded.

For the first row, the stored FP32 inputs are
`[1, 1.0010000467300415, 0.9990000128746033, 1.000499963760376]`.
An IEEE FP32 reconstruction produces:

| Reconstruction | Mean | Population variance | Output 0 |
| --- | --- | --- | --- |
| Vec4 Welford, reciprocal square root | 1.0001249313354492 | 5.468851327350421e-7 | 0.07307180017232895 |
| Pairwise `(x0+x2)+(x1+x3)` mean, centered-square mean | 1.0001250505447388 | 5.468814379128162e-7 | 0.07304610311985016 |

Both reconstructed outputs exactly match the recorded GPU outputs. The means
differ by one FP32 ULP, `1.1920928955078125e-7`; scale `0.7` divided by a standard
deviation near `0.003247596` amplifies that into approximately `2.57e-5`.
These intermediate statistics are **source-based numerical reconstructions**,
not captured GPU intermediate tensors. They strongly explain the failure but
do not establish a universal error bound or superiority of either reduction.

The test stops at this forward assertion. Consequently this failing fixture's
input/affine gradients and Adam comparisons, the later Float64 and constant
fixtures, and the nested `256x2048` gate were **not executed in that run**.
The separately passing noncontiguous/contract test does not cover those gaps.
No code, defaults or tolerances changed during this follow-up. There is no
evidence warranting an epsilon tweak, output correction or hidden fallback.
A future fused implementation preserving the expanded operation order would
be a separate candidate requiring the unchanged forward, gradient, Adam and
full-width gates plus paired timing; the current native candidate must not be
promoted merely because the real-number formulas agree.

## Static attribution addendum: time batching, FK and world preparation

This read-only review uses the current native sources and unmodified `../smc`;
it introduces no timing result. **Native already batches imagined reward across
time.** Both the full actor path and each actor microbatch first complete the
dependent H-step dynamics, concatenate states into H×B rows, and then evaluate
reward/soft failure once. The claim that native calls reward/FK separately for
each imagined time step does not describe this implementation. See
[native full actor](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/learning.mbt:474),
[native chunk](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/actor_microbatch.mbt:99)
and [SMC flatten/reward](/Users/kq/Workspace/smc/supermimic/train.py:196).

For H=32, one full actor update with critic enabled has these **source-level
FK calls**, excluding collection, initial catalog construction and compiler
elimination of unused outputs. A call walks the robot tree for all supplied
rows; it is not one GPU kernel.

| Route | Reward FK rows | Tail FK rows | Critic-data FK rows | Calls and total state rows |
| --- | --- | --- | --- | --- |
| Native baseline, robot and reference each | H×B | B | (H+1)×B | 3 calls each, 66B rows each; 6 calls total |
| SMC robot | H×B | B | (H+1)×B | 3 calls, 66B rows |
| SMC reference | lookup only | lookup only | lookup only | 0 update-time FK calls |
| Native `reuse_geometry=true`, robot and reference each | H×B cached | cached final row | only initial B rows need FK | 2 calls each, 33B rows each; 4 calls total |

The native baseline invokes both FK paths inside
[reward](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/geometry/context.mbt:232)
and [critic features](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/geometry/context.mbt:367).
[Geometry reuse](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/actor_geometry_reuse.mbt:5)
retains t=1..H output tensors, reuses the final row for the differentiable tail,
then detaches them for critic fitting; t=0 is computed separately. C actor
chunks multiply the call counts by C, with rows summed over the same logical
batch. The existing reference-resident candidate stores flat71 states and
goals, **not body FK tables**, so it alone does not remove reference FK.
[SMC motion construction](/Users/kq/Workspace/smc/supermimic/motion.py:61)
precomputes body position/rotation/velocities in bounded frame chunks, retains
them on GPU and gathers them in [MDP heads](/Users/kq/Workspace/smc/supermimic/mdp.py:112).

The remaining batching axis in native reward is **tracked bodies**, not time:
the original G1 route calls body orientation error 14 times plus one root
orientation error. `body_orientation_batched=true` changes this to one packed
body call plus one root call, retaining the same formula. FK itself still has
parent-before-child dependencies; predicted dynamics must also remain sequential
because state/history/action at t+1 depend on t. Batch-local FK reuse and a
reference-only body table are legitimate execution candidates; neither permits
detaching actor states before reward or changing the critic-normalizer/GAE/update
order. The cached robot/reference outputs alone contain
2×14×18×4×H×B bytes: **33,030,144 B at B512**, excluding autograd saved tensors,
untracked intermediate bodies and allocator retention. A permanent reference
body table adds 14×18×4×F bytes (about 0.44 GB for 441k frames), plus bounded build
coexistence and gathers. It must reproduce the native Float32 reference-FK
inputs, rather than importing differently rounded CPU/SMC body features.

World-model fitting has a distinct batching opportunity. SMC's
[_wm_rollout/_wm_err](/Users/kq/Workspace/smc/supermimic/train.py:95)
still performs eight dependent dynamics steps, but stacks predictions and
computes state error/normalization over B×8 once. Native
[fit_world_batch](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/learning.mbt:253)
and its microbatch equivalent invoke target quaternion decoding and state error
eight times. At ten world updates/iteration, this is **80 state-error calls
versus 10**, while both still perform 80 dynamics/MLP steps. Delaying independent
target decoding/error until after rollout can reduce small-op submission. Keep
the existing batch-major B×8 order, mask, output-normalizer snapshot, divide by
B, final-step metric and one backward/Adam per logical update. It adds stacked
prediction storage of 76×B×8×4 bytes (4,980,736 B at B2048) and widens error
temporaries; changed reduction/kernel shapes require gradient/update parity
checks and a fresh memory estimate, not an assumption of bitwise equivalence.

Preparation is also materially different. SMC
[sample_windows](/Users/kq/Workspace/smc/supermimic/buffer.py:41)
gathers five fields from resident GPU replay. Native
[sample_world_batch](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/runtime/batches.mbt:176)
decodes 256-window CPU blocks, packs/validates five arrays, uploads each and
concatenates the blocks. At B2048 and ten updates this means **400 upload calls
and 50 final field-concatenation calls per iteration**. The five Float32 payloads
total 134,348,800 B/iteration; this excludes CPU objects, duplicate staging and
concat traffic. [The original tensor upload](/Users/kq/Workspace/moonrobo/src/learning_tensor/adapter.cpp:101)
copies into CPU Float64, converts to Float32 and then transfers to CUDA. A bounded
primitive gather/upload or replay mirror could remove that work, but must retain
native sample indices/RNG order, values, done masks and mutation visibility.

These are hypotheses for the reported roughly 1.8 s versus 0.6 s world-stage
gap, together with SMC compilation/fusion, expanded native LayerNorm, optimizer
checks and scalar readbacks. Static counts cannot apportion that gap or predict
a speedup. Compare `world.sample_prepare_upload`, forward, backward and Adam
under identical shapes/precision and fresh-process paired measurements; the
existing outer stage times include preparation and are not pure GEMM time.

## World-stage follow-up after the accepted E comparison

This is a read-only attribution, appended while F2 is running. No frozen
training source, numerical gate, default or GPU workload was changed. The
[accepted E evidence](../output/spark-runtime-20261024/smc-native-aligned512-20261024-e/README.md)
reports native **2924.500 ms/iteration**, of which world is **1817.075 ms
(62.133%)**. The separate [instrumented diagnostic](../output/spark-runtime-20261024/smc-native-profile-e-20261024-b/profile-attribution.json)
uses `actor_enabled_iterations_21_24`, not E's steady iterations 41–60:

| Diagnostic scope | Host inclusive ms/iteration | Current-stream CUDA-event ms/iteration |
| --- | ---: | ---: |
| World sampling, preparation, upload | 369.111 | 369.147 |
| World update, including its children | 1432.805 | 1433.253 |
| Forward | 262.836 | 392.325 |
| Backward | 882.694 | 987.586 |
| Adam/check/clip | 252.217 | 43.894 |

Backward is **68.9% of the world-update event interval**, forward 27.4%, and
Adam 3.1%. These are nested elapsed intervals, not kernel-active durations.
Do not add a parent to its children, sum CPU and CUDA columns, subtract the
columns to estimate GPU idle time, or mix this diagnostic into E's throughput.
[Event recording](../src/learning_tensor/profiling.inc#L79) brackets the current
stream; host submission gaps and dependencies can remain between the events.
In particular, the Adam host interval includes the wait at
[`item<bool>()`](../src/learning_tensor/adapter.cpp#L288) after preceding work.
Its 252 ms host interval does not demonstrate 252 ms of removable optimizer
computation. This profile has no per-operator CUDA timeline.

The sources establish several execution differences, without apportioning the
987.6 ms backward interval among them:

- **Expanded LayerNorm is a substantial repeated candidate, not a proven
  bottleneck.** [Native forward](../src/learning_aligned_gpu/networks.mbt#L174)
  uses nine tensor API calls per normalization: two means, subtraction,
  square, affine epsilon, square root, division, affine weight and bias. The
  [scalar affine adapter](../src/learning_tensor/adapter.cpp#L232) itself uses
  multiply then add, so this is ten source-level ATen arithmetic operations,
  not ten asserted GPU kernels. Three hidden layers × eight steps × ten world
  updates gives **240 LayerNorm evaluations / 2160 forward tensor API calls**
  per iteration, with the corresponding general autograd chains in backward.
  Each B2048×width2048 FP32 activation is 16 MiB; multiple intermediates and
  saved backward values can create material memory traffic. This is not an
  exact saved-tensor or peak-memory accounting. SMC declares `nn.LayerNorm`
  [inside its MLP](../../smc/supermimic/networks.py#L12) and compiles the rollout.
  Our native-LayerNorm candidate **still fails the original near-constant CUDA
  fixture gate**, as recorded above. The accepted/F candidate paths retain
  expanded LayerNorm. Do not promote that failed candidate, relax tolerances,
  or attribute all backward time to normalization.
- **The eight dynamics steps are dependent in both implementations.** Each
  next predicted state feeds the following MLP; native
  [world fitting](../src/learning_aligned_gpu/learning.mbt#L253) and SMC
  [`_wm_rollout`](../../smc/supermimic/train.py#L95) both execute eight steps.
  SMC's [`torch.compile`](../../smc/supermimic/train.py#L128) creates a compiled
  rollout/error route; native dispatches individual tensor operations through
  LibTorch. This supports investigating submission and small-op fusion, not
  parallelizing the eight predictions or blaming MoonBit language overhead.
  Backward also contains the required dense-layer gradient products and state
  integration derivatives; their shares are currently unmeasured.
- **Independent error work can batch across time.** SMC stacks predictions
  and evaluates target decoding/error over B×8 once; native does it eight
  times before stacking scalar errors. The earlier addendum gives the
  80-versus-10 per-iteration call counts. Batching that work can reduce
  submissions, but changes reduction shapes and tensor lifetimes. It must
  retain native rotation formulas, mask/order, frozen normalization statistics,
  division by B, final-step metric, and one backward/Adam per logical update.
- **GPU-resident replay removes a different part of the cost.** SMC
  [gathers a GPU ring](../../smc/supermimic/buffer.py#L41); native decodes CPU
  slabs, packs Float64 arrays and uploads converted fields. The diagnostic's
  replay decoding and packing host intervals are 51.515 and 28.375 ms/iteration;
  they are children of the 369.111 ms preparation scope. Its generic
  `batch.upload` total also includes non-world uploads and cannot all be
  charged to world. F's separate bounded staging candidate already changes
  40 uploads/update to five; it does not make replay resident, and its complete
  paired result is pending at the time of this audit. Even hypothetical removal
  of the entire 369 ms preparation scope would be only about 1.145× for this
  diagnostic's 2910 ms total, before paying for the replacement. It cannot
  explain away the dominant update interval.

The next highest-value **execution candidate** is fixed-shape world
forward-plus-backward graph replay, preserving the current expanded-LayerNorm
operations and eight-step dependency. First inspect a bounded operator/launch
timeline of this exact route: if it is dominated by continuously busy kernels,
graph replay will not remove their arithmetic or memory traffic. If launch gaps
and generic-autograd submission dominate, this candidate targets the largest
measured interval without changing normalization formulas. Capture should keep
Adam, nonfinite checks, RNG sampling and metric readbacks outside, and use stable
input/normalizer buffers whose values are refreshed without changing update
order. Its graph pool and saved tensors require an explicit cap and additional
admission reserve; the previous critic-graph timing is not evidence of world
graph benefit. Full forward/gradient/Adam/normalizer/resume gates and complete
fresh-process paired runs remain mandatory before enabling it.

After that attribution, prioritize reduction-order-preserving LayerNorm
forward/backward fusion **if its kernels dominate**, or time-batched target/error
work if those smaller launches dominate. GPU replay remains a bounded data-path
candidate after F2 quantifies the residual preparation cost. For the current
1000×256 ring, the four world Float32 fields alone require **208,896,000 B**;
metadata, gather outputs, upload coexistence and retained CPU checkpoint storage
are additional. Keep native start/environment RNG draws and
[`contiguous` frame/episode/done checks](../src/learning_aligned/buffer.mbt#L32),
not SMC's different RNG and done-only mask, and update the mirror on every ring
write and restore. None of these proposed gains are measured or additive, and
no recommendation permits weakening the existing memory guards.
