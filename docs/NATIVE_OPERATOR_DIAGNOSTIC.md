# Independent native operator diagnostic

This is an instrumentation design and implementation record, not a performance
result. The frozen G2 executable, plugin and all formal ABBA specifications remain
unchanged. A separately identified diagnostic executable/plugin must not supply
replacement throughput rows for those experiments.

## Two distinct measurement channels

The existing `learning_tensor/profiling.inc` stores two CUDA events per recorded
range, up to65,536 ranges, until report generation. Its CUDA durations include
stream dependencies and idle intervals; they are not kernel-active time. That
mechanism remains suitable for the existing coarse phase comparisons. Expanding
it to every imagined step, MLP layer and ATen operation would add many events,
consume its bound and perturb the observed schedule.

The separate diagnostic channel therefore uses NVTX structural ranges plus
LibTorch's automatic ATen/autograd annotations. No per-layer CUDA event, tensor
readback or synchronization is introduced. Automatic operator annotations should
carry forward/backward sequence associations; successful association must be
verified in the actual trace, not inferred from the presence of the API.
Shapes, stacks and tensor values are not collected by default. The capture is
bounded to an explicitly selected training interval and must fail visibly if its
required instrumentation is unavailable. Disabled execution constructs no
per-step/per-layer dynamic labels and performs no extra native query.

The first requested interval is **iteration41's complete policy-update entry**:
sample preparation/upload, logical4096, eight512-row actor chunks and twenty
critic minibatch updates. The runtime opens the session **before** the existing
policy `prepare_collective` / `sample_policy_batch` path, places that unchanged
path inside `diag.actor.prepare`, and closes it after `actor_critic.update`.
Exceptions during preparation also close the selected window. World-model and
physical-collection annotations may exist in the source, but their automatic
operator trace is disabled for this first capture. A separate world-model capture
would require a separately stated interval; it is not silently included here.

For the external watchdog, the runtime prints one
`moonrobo.operator-window.v1` JSON line with `state:"started"` and `iteration:41`
before calling the native capture-begin operation, using a pure MoonBit selected-
iteration query. It prints `state:"completed"` only after capture-end succeeds.
These stdout operations are outside the raw NVTX interval; disabled execution
prints neither line. A failure has no successful completion marker. The watchdog
interval also includes capture-boundary synchronization and must not be treated
as an additional kernel-time measurement. The C++ plugin does not duplicate the
stdout markers.

## Source-to-label map

| Source boundary | Implemented structural labels | Meaning |
| --- | --- | --- |
| `runtime/train.mbt` | `diag.iteration.41.actor_critic`, `diag.actor.prepare`, `diag.world.update.{i}` | The first selected window includes policy preparation and actor/critic; world-update labels remain dormant |
| `actor_microbatch.mbt` | `diag.actor.chunk.start{start}.count{count}`, `diag.actor.step.{t}` | Eight512-row or sixteen256-row chunks for logical4096; sequential32-step dynamics inside each chunk |
| `learning.mbt`, `microbatch.mbt` | `diag.actor.full.count{n}`, `diag.world.step.{t}` | Distinguishes the complete-batch path; world-fit labels remain dormant in the actor-only window |
| `networks.mbt` and normalization helpers | `diag.policy.encoder/decoder`, `diag.world.mlp`, `diag.critic.mlp`; `diag.network.layer.{i}` with `linear`, `ln.expanded/native`, `activation` | Role labels include their original input/output normalization or transformations; layer children isolate network operations |
| `geometry/context.mbt` and tracking reuse | `diag.geometry.robot_fk/reference_fk`, `diag.actor.reward.batch`, `diag.reward.*` | FK and reward use the actual concatenated `H × chunk` rows, not32 independent reward calls |
| actor chunk body | `diag.actor.soft_failure`, `diag.actor.return`, `diag.critic.tail`, `diag.actor.backward`, `diag.actor.critic_features` | Detached critic-feature construction stays after chunk backward and before the one actor Adam update |
| actor critic-fit blocks | `diag.critic.normalizer/bootstrap/gae`, `diag.critic.epoch{e}.minibatch{m}`, `gather_and_forward`, `target_gather`, `loss`, `backward`, `adam` | Keeps the complete logical trajectory and twenty critic updates explicit; input gather retains its original place inside prediction |

The current six-switch actor route first performs the32-step rollout, then
concatenates predicted states and references before one batch reward computation
per chunk. Geometry reuse shares that computed FK with tail/critic features and
computes the initial-state critic FK separately. Labels must preserve these
batch boundaries. A named body reward component may occur once per tracked body
inside the existing loop; those repeated occurrences must not be mistaken for
imagination time steps.

The reward labels distinguish per-body position/orientation/linear-velocity/
angular-velocity errors, the optional single batched-orientation calculation,
root position/orientation errors, tracking-score assembly, action-rate and
joint-limit regularizers. No scoring order, tolerance, reduction, detach or
optimizer boundary changes. `diag.critic.normalizer` includes the existing
optional preparation of fixed normalized critic inputs; it is not solely a
single reduction kernel. `diag.critic.gather_and_forward` deliberately includes
the original input gather, while target gather and loss are labeled separately.

For the selected frozen six-switch configuration, the source implies these
counts for one complete actor/critic update. They are **expected validation
counts, not observations from a GPU trace**:

| Range kind | Expected count |
| --- | ---: |
| Policy sample preparation/upload | 1 |
| Actor chunks / imagined steps | 8 /256 |
| Policy encoder / decoder calls | 256 /256 |
| World MLP calls during imagination | 256 |
| Critic MLP calls:8 tails +1 bootstrap +20 fits | 29 |
| Network linear / actual expanded-LN / activation children | 3671 /768 /2874 |
| Batched reward / soft failure / survival return | 8 /8 /8 |
| Robot / reference FK with geometry reuse | 16 /16 |
| Actor Adam / critic Adam | 1 /20 |

These counts use the frozen network layer counts and14 tracked bodies; smaller
CPU fixtures have independently derived smaller counts. They do not show kernel
fusion or account for callbacks inside autograd; the real ATen/NVTX trace supplies
that evidence. The outer capture includes reassembly and metric handling even
where no additional child label is introduced.

The layer labels do not imply a fused LayerNorm. The accepted route uses the
expanded sequence of mean, subtraction, square, mean, epsilon, sqrt, division,
weight and bias operations. The prior native-LayerNorm numerical gate remains
failed and is not altered by instrumentation.

## Checks and reporting boundaries

CPU fixtures must check disabled/on numerical outputs, gradients, optimizer and
normalizer states under the same execution plan, and verify balanced nested
ranges after both success and exceptions. No new sampling, RNG, detach, tensor
copy, gradient update or reduction is allowed. The diagnostic session and label
storage have explicit bounds; trace output requires a separate disk/time bound
under the same outer process/memory guards.

Only the sole remote owner may build or capture on179. The first capture should
verify nonempty ATen and autograd events, forward/backward association, expected
chunk/step counts, required structural labels and clean close. CUDA kernel-active
durations, CUDA API submission, host preparation and stream waiting must then be
reported separately. Inclusive labels must not be summed as disjoint work, and
the instrumented iteration's wall time is not an uninstrumented throughput result.

The high-level implementation and three CPU fixtures are written and formatted.
A narrow native `moon check` over the learner and runtime diagnostic fixtures
completed successfully (14 tasks, no errors). They have **not yet been built into
native executables or executed** at this handoff.
`operator_diagnostics_wbtest.mbt` requires
`MOONROBO_OPERATOR_DIAGNOSTIC_TEST=1` and an explicitly supplied
`MOONROBO_TENSOR_LIBRARY` with the diagnostic extension. The first fixture uses
CPU-only bounded structural recording, tests full and split execution separately,
and checks strict equality of metrics, parameters, gradients, Adam and normalizer
state for diagnostic-on/off runs using the **same** plan. It also checks
step/layer/reward/FK/minibatch counts and clean nesting. The second intentionally
fails a tensor matrix operation and checks that both open network ranges cancel.
Neither fixture is a512-versus256 numerical-equivalence gate.

The third fixture, `runtime/operator_window_wbtest.mbt`, exercises the real
runtime's iteration41 using a small synthetic CPU state. It verifies that
`diag.actor.prepare` is the first child of the iteration scope. A second case
injects a nonfinite preview into that fixture only, after the world update and
before sampling; it requires the existing preparation guard to fail, both scopes
to cancel, no actor update to occur and no successful capture completion. This
tests the newly widened boundary without a GPU or a simulated hardware claim.

The sole owner still needs to run narrow compilation/tests and regenerate
interfaces before freezing a diagnostic build. CUDA/NVTX capture, automatic
forward/backward association and bottleneck attribution remain pending.
