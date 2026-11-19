# G1 Reference Model Replay Retention

Updated: 2026-10-23. Status: three-seed training and independent native verification
completed. Three thirty-second trials qualify individually; no complete policy qualifies.

The [six-cycle duration study](G1_REFERENCE_EXTENDED_TRAINING.md) improves two
seeds but regresses in the third. That seed's held-out initial-policy H32 model
error increases while its 20,000-window FIFO replaces older training data.
This study tests initial-data retention as one controlled response; it does
not assume that forgetting is already the established cause.

## Frozen comparison

The [charter](../examples/learning/g1-reference-replay-anchor.json) compares
`replay-prefix-extended`, the independently verified six-cycle recent-FIFO
baseline, with `replay-prefix-anchor`, a new six-cycle initial-anchor arm.
Both use all three seeds, six cycles, 27 collection episodes/cycle, 900 model
and 128 value fitting updates/cycle, and 12 H32 no-tail actor steps/cycle.
There is no change to actor initialization, normalization, learned feedback,
reference goals, reward, exploration, actor-origin sampling rule or local step
cap. Neither actor objective calls its value model.

The new arm rebuilds the original first three cycles from archived batches,
checking actor/model/value weights against the corresponding baseline after
each cycle. Original optimizer snapshots are unavailable; their moments are
reconstructed by repeating the original operations, not independently compared
against a saved optimizer snapshot. The live optimizers and RNG streams then
continue through the three intervention cycles.

From cycle 4, the model fitting pool preserves **all eight-step windows from
the shared first noisy collection**. Its remaining capacity retains the newest
windows from collections 2 onward. The anchor cannot also enter that recent
pool. The fitting pool remains at most 20,000 windows; original source archives
and temporary reconstruction buffers are separate from that capacity. Windows
do not cross episode boundaries. Initial anchor size varies with each seed's
original survival; no ratio search or additional model updates are introduced.

Model fitting samples uniformly from the combined pool using the original
seeded generator. Actor updates still sample only the current cycle's actual
pre-action states with their complete causal history/EMA and reference phase.
Retaining early *model* data does not add old actor origins or reference-source
control labels. The original model diagnostic episodes never enter fitting.

All final actors face the unchanged 27-cell quality suite: remaining 30/20/10 s
from nine known references, zero falls, joint RMSE ≤0.03 rad, body/root position
RMSE ≤0.05 m and root angle RMSE ≤0.1 rad. No intermediate quality selection,
early stopping, seed selection or threshold changes are allowed. Equal episode
and update budgets do not imply equal actual transitions if survival differs.

## Reuse and evidence

The source six-cycle report is pinned at SHA-256
`15fea5c25740ef2d68703301f489502d067dee90bb53c7c27098bbecb2c26200`.
Its complete six-cycle FIFO arm contributes 603 inherited records: 27 initial
evaluations, 81 common first collections, 9 model diagnostics, 405 later training
episodes and 81 final trials. The old three-cycle final evaluations are not
recounted. The new arm adds 243 cycle 4–6 collections and 81 final evaluations:
324 new, 927 paired records. Inherited files remain at their original paths.

Numerical tests exercise the first-three-fit equality, exact anchored/recent
contents, finite-window boundaries and sampling digest/counts. Independent
verification also reconstructs pool counts and every model minibatch index
digest from the archived episode lengths and seeded random stream. Actor origin
draws, checkpoint tensors, physical arrays, actions and quality undergo the
existing independent numeric/native checks.

New provider wall time on local CPU includes first-three-cycle reconstruction;
standalone learner costs retain the original collection charges. This is a
matched-budget comparison within the model-based learner, not a successful
model/PPO cost-to-target comparison or GPU-hours claim.

## Results

All three final suites have completed. Every final policy and failed outcome
is retained, with no checkpoint or seed selected for adoption.

| Seed | Model replay | Falls /27 | Mean survival s | Individual passes /27 | Joint RMSE rad | Body RMSE m | Root position RMSE m | Root angle RMSE rad |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | Recent FIFO, reused | 18 | 12.004 | 0 | 0.03384 | 0.08008 | 0.07912 | 0.19767 |
| 0 | Initial anchor | 23 | 9.430 | 3 | 0.02798 | 0.10052 | 0.10383 | 0.16767 |
| 1 | Recent FIFO, reused | 22 | 10.219 | 5 | 0.02452 | 0.09502 | 0.09892 | 0.14348 |
| 1 | Initial anchor | 18 | 10.930 | 9 | 0.02241 | 0.08403 | 0.08752 | 0.12709 |
| 2 | Recent FIFO, reused | 27 | 4.930 | 0 | 0.05748 | 0.17250 | 0.18182 | 0.22622 |
| 2 | Initial anchor | 11 | 16.614 | 0 | 0.03938 | 0.06189 | 0.06548 | 0.11278 |

The RMSE aggregates are pooled over actual observed pre-fall steps, not means
of fixed-duration counterfactual trajectories. Per-trial qualification still
requires full duration and all four unchanged limits.

Seed 1 passes all nine pose-offset conditions: three friction levels times
0/10/20-second origins. These include **three complete thirty-second trials**,
as well as three twenty- and three ten-second remainders. Its nine stand and
nine joint-sine conditions still fall, so the full 27-cell policy gate fails.
This is one training seed on known, correlated reference conditions, not a
qualified general motion skill or unseen-motion result.

The three qualified thirty-second seed-1 trials have the following errors:

| Known reference condition | Joint RMSE rad | Body RMSE m | Root position RMSE m | Root angle RMSE rad |
| --- | --- | --- | --- | --- |
| pose-offset | 0.01258 | 0.02469 | 0.02440 | 0.04443 |
| pose-offset-medium-friction | 0.01269 | 0.02487 | 0.02452 | 0.04514 |
| pose-offset-low-friction | 0.01279 | 0.02460 | 0.02422 | 0.04468 |

Seed 0 completes only four trials and passes three, versus nine inaccurate
completions and zero passes under FIFO. It has more falls and worse pooled
body/root position error despite lower joint/orientation error. Seed 2 recovers
survival strongly and completes sixteen trials, but **none** passes all tracking
limits. The recipe therefore changes the outcome substantially without solving
the complete quality target or establishing consistent survival improvement.

The first-collection anchors contain 6,341/6,199/6,308 windows by seed, leaving
13,659/13,801/13,692 recent windows within the 20,000-window fitting pool. Their
population shares are approximately 31.7/31.0/31.5%. Actual later actor states
and transition counts can diverge as each policy responds to the intervention;
only the actor's sampling rule, not its realized data, is held fixed.

Provider elapsed time on local CPU is 519.50 s, including reconstruction and
new collection/fitting/evaluation. Every cost-to-target remains `not-reached`.
Source report SHA-256 is
`a8308c60c8c1d9eb3e561eb667daac8736d7374989dd21e69182ebd0bd65ae25`.

## Prediction diagnostics and interpretation

The unchanged initial-policy diagnostic episodes remain excluded from fitting.
Both arms use identical initial normalization within each seed. Their final
normalized prediction errors are:

| Seed | FIFO H8 | Anchor H8 | FIFO H32 | Anchor H32 |
| --- | --- | --- | --- | --- |
| 0 | 0.05706 | 0.02922 | 0.14426 | 0.03710 |
| 1 | 0.05896 | 0.03114 | 0.08048 | 0.04704 |
| 2 | 0.06369 | 0.05551 | 0.09114 | 0.11598 |

All H8 errors improve; H32 improves in two seeds and worsens in seed 2. The
strongest survival recovery therefore occurs with *worse* H32 error on this
fixed old-policy diagnostic. Conversely, seed 0's much better prediction error
does not prevent more falls. Retention changes learning, but these results do
not establish one diagnostic MSE as the causal explanation or a sufficient
controller-quality proxy. The two methods' later physical state distributions
also differ. Inspect concrete failed stand/sine updates and model/physics
alignment before treating this setting as a general solution.

## Independent verification

The [verified paired report](../output/research/g1-reference-replay-anchor.json)
contains **927 episodes /284,781 transitions**: 603 inherited /173,984 and 324
new /110,797. The new data comprise 243 training episodes /60,883 transitions
and 81 final evaluations /49,914 transitions. Every archive passes source and
behavior hashes, causal feature/action/noise/reward reconstruction, scalar
quality reconstruction and native MotionDataset reading. Maximum feature error
is 1.43e-6, actor mean error 2.98e-7 and applied-control error 0.00001681 rad.
Reward reconstruction is exact; rebuilt quality differs from original float64
MuJoCo scalars by at most 4.49e-9. Stored arrays remain float32.

Independent reloads confirm identical actor/model/value tensors at all nine
reconstructed cycles. Pool counts and model-minibatch index digests verify
across all 18 fitting cycles of the new arm: 1,036,800 window draws in total,
including 518,400 draws in the intervention cycles. Exactly 162,948 of those
later draws select initial-anchor windows; draws can repeat windows. Actor
origin indices and causal phase/history are verified separately for both arms.

The six-cycle candidate's one-second-state float64 directional gradient check
uses the actual cycle 6 actor/model/value artifacts. Finite-difference error is
9.77e-9 with unchanged frozen model/value and no critic tail; the frozen FIFO
baseline's check passes too. These establish autodiff consistency, not physical
simulator Jacobian accuracy.

The [compact results](../output/research/g1-reference-replay-anchor-summary.json)
preserve every completed cell, failed full-policy status, per-cycle diagnostics,
sampling and cost components. Seventeen reference numerical tests and five
native MotionDataset tests pass; changed MoonBit scripts check and format.
`moon info` reports no errors or new public API changes, with existing toolchain
warnings retained. The subsequent [platform integration](G1_REFERENCE_REPLAY_PLATFORM.md)
registers both six-cycle arms, their complete paired archives and trained-policy
baseline comparison. Research results remain separate from skill qualification.

## Reproduce

Use the existing verified study, reference assets and numerical environment;
the output directory must be new.

```sh
moon run --target native scripts/fit_g1_reference_learning.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-full-body-reference /Users/kq/Workspace/moonrobo/target/learning/g1-reference-extended-training/initial/actor-zero-output.pt /Users/kq/Workspace/moonrobo/target/learning/g1-reference-replay-anchor /Users/kq/Workspace/moonrobo/examples/learning/g1-reference-replay-anchor.json /Users/kq/Workspace/moonrobo/target/learning/g1-reference-extended-training
moon run --target native scripts/report_g1_reference_learning.mbtx /Users/kq/Workspace/moonrobo /Users/kq/Workspace/moonrobo/target/learning/g1-reference-replay-anchor /Users/kq/Workspace/moonrobo/output/research/g1-reference-replay-anchor.json
moon run --target native scripts/summarize_g1_reference_extension.mbtx /Users/kq/Workspace/moonrobo/output/research/g1-reference-replay-anchor.json /Users/kq/Workspace/moonrobo/output/research/g1-reference-replay-anchor-summary.json
```

No default policy or physical authority changes. The complete
[phase plan](SUPERMIMIC_PHASE_PLAN.md), including sustained full-reference
control, broader motions, full workbench, successful matched efficiency and
E1/hardware qualification, remains active.

The subsequent [last-cycle comparison](G1_REFERENCE_LAST_CYCLE.md) evaluates
actual saved cycle-5/6 actors without new training. It identifies short-term
model/physics return disagreement across both replay arms and all seeds; this
does not alter the original final-suite results or select another checkpoint.
