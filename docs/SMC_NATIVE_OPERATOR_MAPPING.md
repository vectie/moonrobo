# SMC / native six: operator mapping and comparison contract

Status: local source audit, 2026-10-25. This document records **what to compare**;
it is not a completed operator benchmark or a measured bottleneck attribution.
No remote operation, build, GPU execution, or training-source change was performed
for this audit. Native instrumentation is owned by the separate
[diagnostic implementation](NATIVE_OPERATOR_DIAGNOSTIC.md); the original SMC tree
and the accepted G2 throughput executable/plugin remain comparison artifacts.

The audited case is FP32/TF32, Smc99 observations, history/preview 10, horizon 32,
logical actor batch 4096, native actor microbatch 512, five critic epochs and four
minibatches per epoch. Native uses the accepted six switches, expanded LayerNorm,
and neither `noise_staging_batch` nor `actor_norm_snapshot`. Critic graph replay
and critic-normalization reuse are off. The sixth switch, bounded world-batch
staging, does not change the actor/critic operator tree. The first diagnostic
window is iteration 41's actor/critic update, not its ten world-model updates.

## 1. Network and trajectory correspondence

Weights have layout `[output, input]` on both sides. A shared seed does **not**
give shared weights, noise, replay samples, or critic permutations: initialization
and random generators differ. Mathematical layer counts below are not measured
kernel counts or an explanation of elapsed time.

| Logical group | Original SMC | Native six | Comparison boundary / difference |
| --- | --- | --- | --- |
| `policy.encoder` | Goal normalization; `730→2048→1024→512→256→32`, four ELUs, then tanh | Same dimensions, activations and latent width | No LayerNorm in this network. Current native FP32 linear is `matmul(Wᵀ)+bias`; SMC uses `nn.Linear`. Actual addmm/GEMM/fusion must come from the trace. |
| `policy.decoder` | Normalize `[N,10,99]`, flatten to 990, concatenate latent 32; `1022→2048→1024→512→256→29`, four ELUs | Same feature order and dimensions | No LayerNorm or final action tanh. Freeze mean/variance/count as well as weights for a numerical comparison. |
| `world.mlp` | Invariant state 71 + action 29 + normalized context 33; normalize 133; `133→2048→2048→2048→70`; each hidden layer Linear→LayerNorm→SiLU | Same architecture; expanded LayerNorm: mean/subtract/square/mean/add epsilon/sqrt/divide/scale/bias | Three LN sites, epsilon `1e-5`, affine population variance. Same formula does not guarantee identical reduction rounding or gradients. The separate native-LN candidate has not passed its full gate and is not the six-switch route. |
| `world.integrate` | De-normalize 70 increments; position increment in yaw frame; rotation `R·exp(dθ)`; linear/angular velocity increments in root frame; joint position/velocity additions | Same frame conventions and six state components | Compare all six outputs and input/action VJPs. Scalar algebra, SO(3) branch handling and tensor layout must be recorded; do not assume bit identity. |
| `actor.observation/history` | Build Smc99 observation; generate uniform GPU noise; shift history; calculate next goal inside `_imag_step` | Build same observation; add pre-generated noise tensor; shift history; read staged goal/reference | Noise generation and goal preparation are outside native actor rollout, but inside SMC's step/compiled region. This is a real scope difference. |
| `actor.rollout` | 32 dependent steps on full 4096; world/critic parameters temporarily `requires_grad=False` | Eight independent 512-row chunks, each 32 dependent steps; detached parameter views freeze world/critic while preserving state/action derivatives | Record shape and layout. Eight versus one backward invocation is an execution fact, not a measured reason for the speed difference. |
| `critic.tail` | Build 184 critic features + 730 goal; old critic normalizer; `914→256→128→1`, two ELUs; critic parameters frozen | Same widths and update timing; last-step geometry reused | SMC tail uses the **uncompiled** `_critic_input` and eager critic. Both propagate the tail derivative into the actor. |
| `actor.return/backward` | `cumprod(1-d)` and tensor discount powers; discounted reward sum plus `γ^32·survival·tail`; one mean loss/backward | Sequential survival/reward recurrence; per-chunk sum scaled by `-1/4096`; eight backward calls accumulate one policy gradient | Algebraic objective agrees, reduction/discount construction and accumulation order differ. Native performs exactly one actor Adam after all chunks. |

Source anchors: [SMC MLPs/normalizers](/Users/kq/Workspace/smc/supermimic/networks.py:12),
[native network execution](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/networks.mbt:158),
[state integration](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/geometry/state.mbt:111),
[SMC imagined step / compile boundaries](/Users/kq/Workspace/smc/supermimic/train.py:111),
[native chunk rollout](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/actor_microbatch.mbt:50).
Native `normalize_xi` uses scale/bias arithmetic where SMC uses subtraction and
division; noise distributions agree in intent, not in generated samples.

## 2. FK, reward and reference work are not interchangeable scopes

SMC computes and stores reference body position, rotation, linear velocity and
angular velocity for the full motion library during initialization
([motion.py:60](/Users/kq/Workspace/smc/supermimic/motion.py:60)). Native's resident
cache contains `flat71` state and goals, **not body FK**
([cache fields](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/runtime/resident_references.mbt:58)).
Native six still computes reference FK for each reward batch and the initial
critic state. Conversely, it reuses predicted/reference FK for the tail and
detached critic features; SMC calls robot FK separately in reward, tail and the
full critic-feature batch.

For `H=32`, logical `B=4096`, the source work accounting is:

| FK role | SMC runtime | Native six runtime |
| --- | --- | --- |
| Reward | Robot FK on `H·B` rows; cached reference bodies gathered | Robot **and reference** FK on `H·512` rows per chunk |
| Tail | Robot FK on `B` rows; cached reference positions | Views of last reward-FK rows; no new FK |
| Critic training features | Robot FK on `(H+1)·B` detached rows | Reuse detached `t=1..H`; fresh robot **and reference** FK only for `t=0`, 512 rows per chunk |

These row counts do not establish equal computational cost: reference inputs
have no gradient graph, bodies/layouts differ, and compiler dead-code elimination
may remove unused FK outputs. Native's generic FK supports fixed joints, joint
reference offsets and pivots; SMC's FK uses its G1 moving-body tree and simpler
zero-pivot/reference equations. A same-input FK test must first verify the actual
kinematic metadata and body/joint order. It must not assume these special cases
from the robot name alone.

| Reward logical key | Common formula / coefficients | Concrete difference to retain |
| --- | --- | --- |
| `reward.body_position` | Align reference bodies to robot XY/yaw; mean over 14 bodies of squared 3D position error; `exp(-e/0.3²)` | Native body-array loop versus SMC packed body axis. FK and alignment must be either included on both sides or excluded on both. |
| `reward.body_orientation` | Mean squared relative body orientation angle; `exp(-e/0.4²)` | **Different implemented functions:** native quaternion/SO(3)-log norm squared; SMC trace→clamp→acos squared. Native six batches the 14 rotations but retains quaternion-log math. |
| `reward.body_linvel` | Mean squared world-frame linear velocity error; `exp(-e/1.0²)` | Reference velocity is not yaw-rotated on either side. Native loop versus packed reduction. |
| `reward.body_angvel` | Mean squared world-frame angular velocity error; `exp(-e/3.14²)` | Same layout distinction as linear velocity. |
| `reward.root_position` | Squared world root-position error; `0.5·exp(-e/0.3²)` | Scalar operation/reduction order may round differently. |
| `reward.root_orientation` | Root orientation score, weight 0.5, scale 0.4 | Same quaternion-log versus clamped-acos difference as body orientation. |
| `reward.action_rate` | `-0.1·Σ(a-a_prev)²` | Compare exactly the same current/previous actions. |
| `reward.joint_limit` | `-2·Σ(relu(q-soft_hi)+relu(soft_lo-q))`; soft-limit factor 0.9 | Freeze actual joint limits/order. |
| `reward.total` | Sum scores and penalties, multiply by control `dt=0.02` | Preserve the original reduction tree when measuring an existing route. |
| `reward.soft_failure` | Height deviation threshold 0.25, tilt deviation 0.8; sigmoid temperatures 0.02/0.04; `1-(1-a)(1-b)` | Native scale/bias versus SMC subtract/divide; separate from native reward event but included in SMC `reward_term`. |

The orientation difference is not merely an implementation of identical finite
arithmetic: SMC clamps cosine to `[-1+1e-6, 1-1e-6]`, producing a positive error
floor at identical rotations and clipped gradients near endpoints. Treat the two
functions as separate mathematical variants. An isolated timing comparison is
valid but does not authorize replacing either training objective.

Sources: [SMC FK](/Users/kq/Workspace/smc/supermimic/kinematics.py:64),
[native FK](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/geometry/context.mbt:122),
[SMC reward](/Users/kq/Workspace/smc/supermimic/mdp.py:109),
[native reward](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/geometry/context.mbt:251),
[native FK reuse](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/actor_geometry_reuse.mbt:5),
[SMC angle](/Users/kq/Workspace/smc/supermimic/rotations.py:94),
[native angle](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/geometry/rotations.mbt:261).

## 3. Critic, normalization, GAE and Adam

| Logical group | Shared intended sequence | Differences / audit requirement |
| --- | --- | --- |
| `critic.features` | Invariant 71 + joint error 29 + 14 body-position errors ×3 + root error 3 + relative rotation 6 + context 33 + goal 730 = 914 | Native constructs chunk features **after that chunk's actor backward**, before the single actor Adam; SMC constructs the full batch after actor Adam. Features use stored states and frozen critic, so this ordering alone does not change the intended inputs. FK work differs as above. |
| `critic.normalizer` | One update over all `33×4096=135168` rows; then bootstrap using the updated statistics | Native variance is centered-square mean, SMC uses `torch.var(unbiased=False)`; native count is host Double, SMC count a tensor. Reduction/count arithmetic must have a separate numerical gate. Tail used the preceding statistics on both sides. |
| `critic.bootstrap` | Critic forward over the full logical trajectory, detached from actor | Native flatten `[135168,914]`; SMC supplies `[33,4096,914]` to its MLP. Same rows, potentially different linear lowering. |
| `critic.gae` | Reverse recurrence `R_t=r_t+γ(1-d_t)[(1-λ)V_{t+1}+λR_{t+1}]`, initialized with `V_H` | `γ=.99`, `λ=.95`; same logical trajectory, scalar multiplication grouping can differ. Never run eight independent GAE fits instead. |
| `critic.fit` | `32×4096=131072` rows; five permutations, four 32768-row minibatches each; 20 MSE/backward/Adam updates | Native restores the time-major order before GAE; permutations are pre-generated on CPU. SMC calls GPU `randperm` per epoch. Freeze permutation arrays, not only seed. |
| `actor.adam` | Norm clip 1, then value clip 0.1; Adam betas .9/.95, epsilon `1e-8` | Native checked-norm rejects missing/nonfinite/overflow before mutation. SMC clips, checks returned norm and skips actor step if nonfinite. These failure semantics are different. |
| `critic.adam` / `world.adam` | Norm clip 1; Adam betas .9/.999, epsilon `1e-8` | Native enforces finite-gradient preflight; original SMC does not have the same rejection policy for these optimizers. Actual foreach/fused/individual tensor execution must be observed, not inferred from the name Adam. |
| `metrics` | Detached reporting values | Native microbatch path reads aggregate actor scalars before actor Adam and reports mean critic loss across updates; SMC returns the last critic loss. Do not use reported loss fields as equal-valued numerical or timing boundaries. |

Sources: [SMC policy/critic update](/Users/kq/Workspace/smc/supermimic/train.py:175),
[native microbatch update](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/actor_microbatch.mbt:221),
[native critic fit](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/actor_microbatch.mbt:371),
[native normalizer](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/networks.mbt:273),
[checked Adam](/Users/kq/Workspace/moonrobo/src/learning_tensor/adam_checked_norm.inc:5).

## 4. Trace scopes, labels and acceptance

| Existing measurement | What it actually includes | Direct cross-runtime comparison? |
| --- | --- | --- |
| SMC `SM_PROFILE imagine fwd` | Sampling/history/noise + 32 steps + reward/FK/soft termination + survival + tail/loss | No: native `actor.forward` includes only each chunk's rollout. |
| SMC `SM_PROFILE bwd` | Actor zero-grad + backward, bounded by explicit CUDA synchronizations | No raw ratio against the sum of native current-stream backward events. |
| SMC `SM_PROFILE critic` | **Actor clipping and Adam**, unfreeze, critic preparation, GAE and 20 updates | Not equivalent to native critic-only ranges. The boundary begins immediately after actor backward. |
| Native `actor.geometry` / `actor.reward` | Geometry: robot/reference FK; reward: cached-body scores and action concatenation, not soft failure | SMC `reward_term` includes robot FK and soft failure; reference FK is absent at runtime. |
| Native `critic.prepare` | Normalizer/bootstrap/GAE, after previously constructed chunk features | Excludes `actor.critic_features`, chunk concatenation and earlier FK. |
| New iteration-41 captures | Both cover the complete policy update, including sampling/preparation through actor and critic completion. Native begins before `sample_policy_batch` and labels it `diag.actor.prepare`; the original `actor_critic.update` coarse event still excludes preparation. | Parent coverage is now aligned; the earlier native window after preparation is superseded. Preparation algorithms, RNG and goal/FK placement still differ, so compare mapped groups and retain unassigned work. |

The native implementation uses `diag.actor.prepare`, `diag.actor.chunk.start{start}.count{n}`,
`diag.actor.step.{t}`, `diag.policy.encoder/decoder`, `diag.world.mlp/integrate`,
`diag.network.layer.{i}` plus `linear`, `ln.expanded`, `activation`,
`diag.geometry.robot_fk/reference_fk`, `diag.reward.*`, `diag.actor.soft_failure`,
`diag.actor.return/backward/critic_features/adam`, `diag.critic.tail`, and
`diag.critic.normalizer/bootstrap/gae/epoch{e}.minibatch{m}` with gather, loss,
backward and Adam children. Layer labels exist only for actual operations: there
must be no policy/critic LN label.

The separately prepared SMC diagnostic uses `diag.actor.step.{t:02d}` around the unchanged
compiled call, `diag.reward.batched`, `diag.critic.tail`, critic
`features/norm/bootstrap/gae`, and `diag.critic.fit.{forward_loss,zero_grad,
backward,clip_norm,adam}.{epoch}.{mb}`. These labels map to the logical keys above;
literal spelling need not match. Its final
[41-iteration source](/Users/kq/Workspace/moonrobo/output/spark-runtime-20261024/fine-grained-trace4096-20261025/smc/generated41-window/diagnostic/supermimic/train.py)
has SHA-256 `329f721080a98f0139e8f3d560e877f03bb39e2709fdadcc12500569ebd12b20`.
Its [preparation record](/Users/kq/Workspace/moonrobo/output/spark-runtime-20261024/fine-grained-trace4096-20261025/smc/README.md)
retains the original and intermediate sources and distinguishes local structure
validation from GPU capture. The actual trace still determines which ranges and
operator/kernel associations were emitted.

Required trace checks:

1. Pin source, executable/plugin, image, config, precision/TF32, capture bounds and
   source-to-label map. Verify clean start/close, no dropped/truncated trace and
   the actual presence of ATen, autograd and CUDA kernels/API correlations.
2. Native: eight unique contiguous 512-row chunk ranges, each with 32 steps;
   eight actor backward ranges, **one actor Adam**; one full-trajectory normalizer,
   bootstrap and GAE; exactly 5×4 critic backward/Adam pairs. SMC: 32 full-4096
   steps, one actor backward/Adam and 20 critic updates. Counts validate coverage;
   they do not attribute time or demonstrate numerical equivalence.
3. Match backward `stashed seq` to observed forward sequence/thread context where
   supplied by the actual profiler. Constants, views, detached work and compiler
   fusion need not have one-to-one backward counterparts. Unmatched nodes stay
   explicitly unassigned; do not fabricate a sequence match.
4. SMC compile boundaries are `_wm_rollout`, `_wm_err`, `_imag_step`,
   `_reward_term`, `_critic_input`; tail and critic fitting are eager. Do not add
   diagnostic calls inside compiled bodies. A fused kernel belongs to its
   observed group; do not split its duration into invented per-layer times or
   force an eager ATen tree onto it.
5. Use CUDA API/correlation records to associate actual kernels with launch
   scopes. Report host submission, synchronization/waiting, kernel activity and
   interval elapsed separately. Existing native CUDA events explicitly report
   `inclusive_current_stream_elapsed_not_kernel_active`.
6. Never add inclusive parent and child durations. For GPU activity distinguish
   summed kernel work from interval union when streams overlap. Retain gaps and
   unclassified kernels. Instrumented iteration time is not a replacement for
   the accepted uninstrumented ABBA throughput result.

For the unchanged six-switch production dimensions, the finer native structural
expectations are 256 encoder, 256 decoder and 256 world-MLP calls; 29 critic-MLP
calls (8 tails + 1 bootstrap + 20 fits); 3,671 linear, 768 expanded-LN and 2,874
hidden-activation ranges; 16 robot-FK and 16 reference-FK ranges. These are
forward source-range counts, not ATen/autograd/kernel counts. Reward body-loop
ranges also contain unlabelled reduction/alignment work in their parent, and
`actor.critic_features` excludes the caller's later goal concatenation/reshape.

## 5. Minimum same-input microbenchmark protocol — not yet implemented

The source map and profiler instrumentation do **not** freeze cross-runtime inputs.
The following gates require a new fixture/runner and have not been executed by
this audit. They are the smallest useful follow-up after trace evidence selects
a suspect group; do not implement all groups merely because they are listed.

| Independent case | Frozen input and boundary | Required output / gradient / update checks |
| --- | --- | --- |
| Network layer/MLP | Exact FP32 `W,b`, LN scale/bias, normalizer statistics, `X` and upstream `dY`; separately `N=512` and `4096`. World actor weights frozen; policy weights trainable. | Forward values, input VJP and every trainable parameter gradient. Use the existing native `Layer`/`Network` fields and tensor loading APIs versus original SMC network modules; no random reinitialization. Same-input native expanded LN versus SMC LN remains a gate, not an assumed equivalence. |
| World integration / observation | Same six-component state, increment, previous action, reference rotation and xi; fixed noise provided as data | All next-state components, observation/history and VJPs. Separate normalization and SO(3) branch cases. |
| FK | Same state and verified kinematic metadata; separately differentiable robot and constant reference workloads | All tracked `p,R,v,w`, their order, and state VJPs where enabled. Measure actual `[H·512]` and `[H·4096]` shapes separately when admitted. |
| Reward / termination | Common precomputed body tensors, root state, reference, current/previous actions; then separately include FK on both sides | Each error/score, total reward, failure probability and VJPs. Quaternion-log and clamped-acos are separately named variants, not an equality gate. |
| Critic preparation/GAE | Same `X[33,4096,914]`, rewards/failures, previous norm statistics, critic weights | Updated norm mean/variance/count, bootstrap values and every GAE target. This avoids attributing earlier actor divergence to critic execution. |
| Critic 20 updates | Same prepared X/targets, five exact permutation arrays, weights, lr and starting Adam state | Every minibatch loss, raw/clipped gradients, post-step parameters and Adam first/second moments/step, plus no actor/world mutation. |
| Adam alone | Same ordered parameters and supplied finite gradients, hyperparameters, moments and step | Clipped gradients, parameters, moments and step. Separately retain native NaN/Inf/finite-norm-overflow rejection/no-mutation tests; do not claim SMC failure behavior is equivalent. |

Use one canonical binary fixture with shape, dtype, strides/contiguity,
requires-grad/frozen flags, body/parameter names and byte hashes. Freeze history
noise, 32 step-noise arrays and five critic permutations when a coupled rollout
is tested. A shared seed is insufficient. Import reusable SMC modules, not
`train.py`, whose module-level code initializes training and simulation.

Run correctness outside timed regions. Declare tolerances before measuring;
report max absolute/relative error, mismatches, finiteness and exact identity
where required. Reset weights, gradients, norms and Adam state between paired
trials; include cold optimizer-state allocation only when both cases include it.
Native exposes parameters and Adam moments through `audit_tensor(kind=0/1/2)`
and step/hyperparameters through `audit_metadata`. Existing accessors support the
proposed gate; a cross-runtime fixture exporter/loader and comparator are still
missing.

For timing, pre-upload identical inputs, warm up each route and compile outside
the measured region, then run bounded ABBA repetitions with the same before/after
completion boundary. Record both CUDA elapsed and completed host wall time.
Collect a separate diagnostic trace for kernel attribution. Standalone
`torch.compile(MLP)` is a **new microbenchmark boundary**, not the original
compiled `_imag_step`, so it cannot directly explain original whole-step fusion.
Keep one case resident at a time, preserve the 100 GiB/no-swap/12-CPU outer guard
and existing 80% plus 16 GiB device-free admission. Do not infer a 4096 result from
a 512 result, relax memory limits, or retain all activation snapshots in memory.

Cross-layout numerical equivalence is already known to need care: the historical
[paper-width CUDA full/split comparison](/Users/kq/Workspace/moonrobo/output/spark-runtime-20261024/native-microbatch-numeric/runs/native-microbatch-numeric-20261024-a/microbatch/comparison.json)
has exact input/initial-state identity but `passed=false`, 27 mismatches at
absolute tolerance `2e-6` / relative tolerance `2e-4`. That was logical batch 4,
full 4 versus split 2, not a 512/256 or cross-runtime gate. Do not generalize it to
a measured 4096 error; equally, do not mark any of the new comparisons
`numerical_equivalence_verified=true` from common counts, same seed or previous
within-route optimization gates.

## 6. Resource-limited diagnostic fallback, separate from the 60-iteration runs

The preferred capture retains the original 60-iteration protocol. If its complete
save-phase envelope cannot be admitted, the independently identified fallback
starts fresh with the same warmup, seed, parameters and schedule, executes through
iteration 41, captures that actor/critic update, then closes cleanly **without any
checkpoint**. All three sides must use the same stopping protocol. It is not a
60-iteration benchmark, does not support continuation/resume, and cannot replace
accepted throughput rows.

This requires a separate command. Merely setting the existing training loop to
41 iterations is insufficient: [normal command](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/cmd/main.mbt:487)
unconditionally publishes checkpoints after its loop segments and has a final
fallback publication. Its training report also unwraps a checkpoint receipt.
By contrast, [TrainingRunner.run](/Users/kq/Workspace/moonrobo/src/learning_aligned_gpu/runtime/train.mbt:566)
only emits bounded metrics at iteration completion; it does not serialize state.
The new driver must bypass snapshot, optimizer/archive serialization, replay
sidecars, current-pointer publication and the checkpoint-dependent report. The
diagnostic receipt must explicitly say `checkpoint_created=false`,
`continuation_supported=false`, and
`training_complete_for_requested_iterations=false`.

The dedicated [admission projection](/Users/kq/Workspace/moonrobo/src/learning_native_admission/operator_diagnostic.mbt:9)
accepts only the complete fresh single-rank five-phase plan. It retains every
component of collection/world/actor phases, rejects repeated projection,
restoration, reordered/missing/duplicate phases and execution reserves added
before projection, and leaves the source plan unchanged. The integration order is:

`plan_paper_stream → for_operator_diagnostic → with_execution_reserve(all existing optimization reserves + one 4 GiB diagnostic reserve) → unchanged assess`

Ordinary `train` and ordinary preflight must never take this projection. The
checkpoint-size and replacement-restore fields remain source-plan provenance;
they are not admitted operations in the diagnostic. Retained allocator caches,
parameters, moments, full replay, reference catalog and physics remain budgeted
through reporting and teardown; there is no assumed early GPU release.

For the audited six-switch, logical-4096/micro-512 configuration:

| Quantity | Bytes |
| --- | ---: |
| Highest retained phase, actor/critic, including the six optimization reserves | 56,160,518,032 |
| Additional profiler/report reserve | 4,294,967,296 |
| Projected peak estimate | 60,455,485,328 |
| Required by 80% alone | 75,569,356,660 |
| Required with retained 16 GiB free reserve | **77,635,354,512** |
| Original save-inclusive plan plus the same diagnostic reserve and free reserve | 83,115,694,736 |

This reduction removes work the separate driver genuinely does not execute; it
does not claim a measured capacity improvement or change either guard. The
admission decision still compares both host/cgroup remaining bytes and CUDA free
bytes. The 100 GiB/no-swap/12-CPU outer limits remain in force.

Reporting and shutdown are not free: up to 65,536 structural labels of at most
160 bytes, bounded telemetry (at most 1,024 × 16 KiB serialized events), report
materialization/copies and trace-file cache coexist with live model/physics
storage. The 4 GiB reserve is a conservative allowance, **not a proven bound** on
CUPTI/Nsight buffers, serialization RSS or physical-SDK shutdown. It must cover
the combined supplemental lifetime, not be independently spent on each item.
Keep trace disk/time bounds and external memory guards active through profiler
drain, environment close, process exit and trace export; no tensor-value or
optimizer-state dump belongs in the compact receipt. If coarse CUDA-event
profiling is also enabled, retain its separately calculated reserve rather than
silently absorbing it. Existing allocator telemetry explicitly excludes report
serialization/environment teardown, so it does not certify those peaks.

Local validation of the projection: four narrow CPU tests cover unchanged
retained phases/source ownership, refusal paths, exact fixture arithmetic and
one-byte-below admission rejection. This validates plan bookkeeping, not a GPU
capture or the opaque profiler/SDK peak. The dedicated command and actual capture
require their owners' separate validation.
