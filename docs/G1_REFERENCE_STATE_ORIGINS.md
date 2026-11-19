# G1 Reference Actor-State Origin Comparison

Updated: 2026-10-23. Status: three-seed training and independent verification
completed. All three new seed means improve; no policy passes the full gate.

The [tail-training study](G1_REFERENCE_TAIL_TRAINING.md) found no consistently
better final policy. Its prefix actor directly optimized only the first
0.64 seconds after resets. This experiment tests actor imagination from
recorded trajectory states while keeping the no-tail objective and all other
training/evaluation budgets unchanged.

## Frozen protocol and reused work

The [charter](../examples/learning/g1-reference-state-origin.json) reuses the
complete, independently verified `prefix-only` reset baseline from source
report SHA-256
`d8ee1744319036e904f6add749cb3e8aed78b8b7cd9426c1d83169bb373d3664`.
It also reuses initial evaluation, common first collections and held-out model
diagnostics. All 360 inherited physical records retain their original bytes,
hashes and metrics. They are referenced in place, not recollected or counted
as new physics. Only the three new `replay-prefix` runs are trained.

Both arms start from the same inherited zero-output actor and independently
initialize/fit models and values. New first fits must match the reset baseline
on the same restored common data. No old fitted model, critic or parameter
direction initializes the new learner. Each seed still uses three cycles,
27 episodes from the nine clips and 0/10/20-second resets per cycle, 900 model
and 128 value updates, twelve H32 actor Adam steps and the 0.005 local logit RMS
step cap. Neither actor objective calls its critic.

The reset arm samples episode starts uniformly. The trajectory arm samples
uniformly with replacement from **all pre-action states of the current
cycle's collection**. Longer surviving episodes therefore get more weight.
The intervention includes that changed weighting; it does not isolate elapsed
time while holding the origin distribution otherwise fixed. Older model replay
still serves dynamics fitting; it is not the actor-origin pool.

Every sampled state carries its exact H10 observation history, actual causal
velocity EMA, reference observer state, reset origin, current phase and preview
mask. Frames do not cross episode boundaries. Imagined continuation advances
from the selected phase, retains the original observer origin and stops at
the existing fall/reference-end conditions. All sampled indices and relative
ages are saved for independent reconstruction of the seeded uniform draws.

All six final actors, including the reused baseline, face the unchanged 27-cell
per-trial gate: complete the remaining 30/20/10 seconds with zero falls, joint
RMSE ≤0.03 rad, body/root position RMSE ≤0.05 m and root angle RMSE ≤0.1 rad.
No intermediate quality checks, checkpoint selection or threshold changes are
introduced. These are known training-reference conditions, not unseen motions.

The paired study contains 603 physical records: 360 inherited and 243 new
(162 later training +81 final evaluation). Costs retain standalone learner
accounting for common collection and historical baseline work, but new provider
time is reported separately. Reuse is not a learning speedup or successful
cost-to-target result.

## Physical results

All final-cycle actors are retained. No new checkpoint or seed is selected.

| Actor origins | Seed | Falls / 27 | Mean survival s | Pooled joint RMSE rad | Body RMSE m | Root position RMSE m |
| --- | --- | --- | --- | --- | --- | --- |
| Reset only, reused | 0 | 27 | 3.472 | 0.05458 | 0.18956 | 0.19913 |
| Trajectory states | 0 | 27 | 6.698 | 0.03949 | 0.12681 | 0.13130 |
| Reset only, reused | 1 | 27 | 5.230 | 0.03559 | 0.14298 | 0.14920 |
| Trajectory states | 1 | 27 | 5.546 | 0.03432 | 0.13462 | 0.13749 |
| Reset only, reused | 2 | 27 | 5.592 | 0.04079 | 0.13834 | 0.14518 |
| Trajectory states | 2 | 24 | 7.319 | 0.03643 | 0.11497 | 0.12067 |

All three new seeds improve their paired mean survival and pooled tracking
errors. Their effect sizes differ substantially, and three seeds on known
clips do not establish generalization or statistical reliability at scale.
Pooled metrics are weighted by actual steps before fall, while qualification
continues to check every individual trial and its full duration.

Seed 2 completes three pose-offset conditions at origin 20 seconds, each
running the remaining **ten seconds**. They are not three full-thirty-second
completions. The medium/low-friction cells pass all individual tracking limits;
the standard-friction completion does not:

| Completed cell, seed 2 | Joint RMSE rad | Body RMSE m | Root position RMSE m | Root angle RMSE rad | Per-trial gate |
| --- | --- | --- | --- | --- | --- |
| pose-offset | 0.03245 | 0.06498 | 0.06626 | 0.15008 | Fail |
| pose-offset-medium-friction | 0.02290 | 0.02293 | 0.02597 | 0.03787 | Pass |
| pose-offset-low-friction | 0.02377 | 0.02936 | 0.03243 | 0.04878 | Pass |

Seed 2 still fails 25/27 quality cells, including 24 falls. The other two new
policies fall in all 27. All six full-policy gates remain unpassed and all
cost-to-target statuses remain `not-reached`. This is useful training-state
coverage evidence, not release qualification or a model-based/PPO speedup.

## Verified sampling, memory and cost

The new arms make 6,912 actor-origin draws; 6,874 are beyond reset. Draws can
repeat the same state. Per-seed mean age is 2.45–2.67 seconds after the original
reset and maximum age is 7.66 seconds. Independent reconstruction matches every
draw to its seeded uniform sampling law and verifies ages against the correct
episode. The old baseline did not record per-step indices; compact summaries
mark those fields unavailable rather than reporting zero sampled origins.

Common first model and value tensors match the inherited baseline exactly
for all three seeds. A float64 gradient check at an archived one-second offset
restores its genuine H10 history and causal EMA, retaining the original reset
origin and reference phase. Its directional finite-difference error is
1.42e-9, with no critic call and frozen model/value tensors unchanged. The
inherited reset actor's corresponding zero-offset check also passes. These
verify implementation consistency, not physical simulator Jacobians.

Only nine of the 108 new actor steps require rescaling: five in seed 0, four
in seed 1. Maximum applied logit RMS is 0.00494625, below the 0.005 cap. The
remaining updates and all inherited reset-arm steps stay below it. This local
bound does not establish a bound on accumulated policy drift or future actions.

New physics totals **243 episodes / 66,414 transitions**. The paired report
contains **603 episodes / 152,776 transitions**, including 360 / 86,362 inherited
records. Every record passes numerical reconstruction and native MotionDataset
reading. Episode budgets match; transition counts differ because survival
changes. Larger transition totals are not evidence of equal sample cost.

Maximum causal feature reconstruction error is 1.97e-6; raw mean error is
2.69e-7 and applied-control error 0.00001681 rad. Reward reconstruction is exact
and quality reconstruction differs from original scalars by at most 5.23e-9.
Archives are float32, with original quality scalars from float64 MuJoCo.

New provider time is 306.39 local CPU seconds, preceded by 1.16 seconds of
setup; it includes restoring archives and training/evaluating only the new
arms. It excludes inherited baseline/common-collection work and native
verification. Standalone learner costs separately retain the original common
collection charge. Reusing results saves repeated computation without proving
a learning-efficiency gain.

- [Verified paired report](../output/research/g1-reference-state-origin.json)
- [Compact results, sampling and completed-trial summary](../output/research/g1-reference-state-origin-summary.json)
- [Training/reuse workflow](../providers/motion_learning/reference_learning_study.py)
- [Causal batch restoration and origin sampling](../providers/motion_learning/reference_learning.py)
- [Native verification](../scripts/report_g1_reference_learning.mbtx)

Artifacts are in `target/learning/g1-reference-state-origin`; inherited files
remain at their original paths. The source report hash is
`c9713dd0cdc6118d83c598a05120fbda15f7e29e946c57387704217d34c95387`.
The [learning platform integration](G1_REFERENCE_LEARNING_PLATFORM.md) now registers
both arms with all 603 numeric records, cycle weights and verified provenance.
The actual cockpit compares against the trained reset baseline and separates
the two qualified individual cells from the unqualified full policy. Next
validate whether trajectory-state updates support sustained learning over the
full reference coverage. No default algorithm or physical authority changes;
the complete [phase plan](SUPERMIMIC_PHASE_PLAN.md) remains active.

The subsequent [training-duration comparison](G1_REFERENCE_EXTENDED_TRAINING.md)
reconstructs these three cycles exactly before running three further cycles.
Seed 0/1 survival improves to 12.004/10.219 s, but seed 2 regresses to 4.930 s.
Only seed 1 gains five individual passes, including two twenty-second remainders;
no full policy qualifies. All 684 paired records validate. Larger training budget
alone does not preserve this study's consistent three-seed improvement.
