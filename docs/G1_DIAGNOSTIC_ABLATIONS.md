# G1 Failure-Tail Diagnostics And Learning Ablations

Updated: 2026-10-23. This follows the failed [ten-second study](G1_LONG_DURATION_STUDY.md).
It tests whether short prediction scores conceal poor action sensitivities,
then exercises the planned actor-horizon/critic-boundary ablation. All results
are simulator development evidence; stable control remains unproven.

## Recorded Failure-Tail Probe

The [fixed protocol](../examples/learning/g1-tail-model-probe.json) uses the
incoming long-study seed-one actor, canonical stand/sway/wave cases and reset
seeds 730–732. Requested start times are 1.0, 1.5, 1.8, 2.0 and 2.2 seconds;
prediction horizons are 1, 8 and 32 steps. Both compared models use the same
recorded actions, full MuJoCo integration snapshots, clipping and initial-model
normalization scale. The old model is the goal-refinement fit; the new one is
the sparse-tail long-study fit. Replay restoration error is exactly zero.

Of 135 requested windows, 105 are available and 30 cross an episode end.
There are no complete 32-step windows starting at or after two seconds. Their
metrics remain null, with explicit omission records. No reset, padding or
post-fall invented controls fill the gap.

| Horizon | Recorded windows | Old model normalized MSE | Long-study model normalized MSE |
| --- | ---: | ---: | ---: |
| 1 | 45 | 0.05841 | 0.03504 |
| 8 | 41 | 0.05333 | 0.04795 |
| 32 | 19 | 0.10111 | 0.12566 |

In the 14 eight-step windows starting at or after two seconds, old/new error
is 0.06618/0.09492. Better global short-window error therefore does not establish
better prediction near these failures. These windows overlap and share nine
source episodes; they are not independent motion trials.

Eight seeded random action-sequence directions per window are checked at L2
perturbations 0.001, 0.01 and 0.1 rad. For 32-step windows, old/new directional
sign agreement with the smallest physics finite difference is 45.4%/48.7%
over 152 directions. Physics signs themselves agree between the two smaller
scales on only 67.1%, so contact sensitivity remains scale-dependent.

The probe also moves along each model's own normalized return gradient. At
0.01 rad sequence norm, this improves actual physical return in 17/19 old-model
windows but only 7/19 new-model windows. New-model mean return change is still
positive (0.00693), despite that low fraction; do not replace the distribution
with a claim that every direction hurts. Returns include the shared smoothness
penalty and soft survival, use fixed recorded actions, and exclude critic
bootstrap. This is neither a closed-loop actor-parameter gradient nor a
stable-control test.

Run from the repository root:

```sh
moon run --target native scripts/probe_g1_tail.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-goal-dynamics /absolute/path/to/moonrobo/target/learning/g1-long-dynamics /absolute/path/to/moonrobo/target/learning/g1-long-dynamics/policy/actor-seed-1.pt /absolute/path/to/moonrobo/target/learning/g1-tail-probe
```

The [compact result](../output/research/g1-tail-model-probe-summary.json) retains
counts, model/checkpoint bindings and all summary metrics. The ignored run
directory retains every direction, return, omission and provider source.

## Actor Horizon And Terminal Critic Ablation

The [ablation script](../scripts/ablate_g1_policy_horizon.mbtx) freezes four
configurations before executing any cell: horizons 8/32 crossed with terminal
actor critic bootstrap off/on. Each cell has three seeds, 200 updates, batch
64, the same long-study model seed zero, weights-only initial actors, reward,
normalization and action bound. Critic fitting and GAE remain active in every
cell; the switch removes only its terminal contribution to the actor objective.
This is not an ablation of every critic use in the learning system.

Validation uses seeds 30–32 at updates 0/50/100/150/200. Every one of the 12
training runs selects update zero. Removing the actor's boundary value or
shortening the horizon does not produce a selected improvement under this
protocol. It does not rule out unmeasured updates between those checkpoints.

| Horizon / actor bootstrap | Last-update validation survival, seeds 0 / 1 / 2 (s) |
| --- | --- |
| 8 / off | 1.3200 / 1.3200 / 1.2933 |
| 8 / on | 1.2000 / 1.3200 / 1.3000 |
| 32 / off | 1.2400 / 1.3200 / 1.2267 |
| 32 / on | 1.3467 / 1.3000 / 1.3400 |

Initial validation survival is 1.6867/2.3067/2.0000 s. All listed validation
trials fall. Selected actors are the same incoming three actors across cells;
fresh final seeds 740–742 give 1.6467/2.3667/1.9178 s mean survival and 9/9
falls for each actor. Repeated evaluation in four cells is not 12 independent
learned controllers. Every candidate remains unqualified.

Equal update/batch counts imply different imagined transition counts at 8 and
32 steps. Measured training is roughly 1.8 s per eight-step seed and 5.2–5.4 s
per 32-step seed, excluding preprocessing. This is a final-quality ablation,
not matched cost-to-target or a speedup result. The [summary](../output/research/g1-horizon-ablation-summary.json)
retains every cell's initial/final validation and selected final outcome.

```sh
moon run --target native scripts/ablate_g1_policy_horizon.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-long-dynamics /absolute/path/to/moonrobo/target/learning/g1-ppo-long /absolute/path/to/moonrobo/target/learning/g1-horizon-ablation
moon run --target native scripts/summarize_g1_ablation.mbtx /absolute/path/to/moonrobo/target/learning/g1-horizon-ablation /absolute/path/to/moonrobo/output/research/g1-horizon-ablation-summary.json
```

Use fresh output directories. Provider sources, all configs, latest/selected
weights and physical traces remain available for every cell, including failures.

## A Measured Representation Error

A second [probe configuration](../examples/learning/g1-translation-model-probe.json)
shifts root X or Y by one metre on the same infinite plane, preserving velocity
and joint controls. It uses nine snapshots at 1.5 s and both 8/32-step horizons.
After subtracting the translation, physical trajectories agree to at most
3.1e-12. Old/long-model translation-equivariance MSE is 0.83738/0.42064 at
32 steps. The unconstrained network uses the arbitrary horizontal origin to
predict future motion, a dependency this physical probe does not support.

The targeted model change masks absolute root X/Y from the network's inputs
while preserving their residual integration in its outputs. Height, orientation,
velocities, actions and context remain inputs. It imposes neither yaw invariance
nor general terrain invariance. The new encoding is explicitly a v2 dynamics
checkpoint; existing v1 checkpoints retain their original input computation.
The [fit configuration](../examples/learning/g1-dynamics-invariant-fit.json)
uses exactly the same data, statistics, seeds, width, sampling and 400-update
budget as the preceding long fit. Control thresholds remain unchanged.

The physical translation check stays below 3.1e-12; the new model's 32-step
equivariance MSE is 2.3e-32, versus 0.41559 for the preceding model on the same
normalization scale. On the original 19 tail-probe windows, model-ascent return
improvement at 0.01 rad rises from 7/19 to 19/19, while random-direction sign
agreement rises from 48.7% to 57.2%. State prediction MSE worsens from 0.12400
to 0.15588. This is a targeted symmetry/gradient improvement, not a general
prediction improvement. These model comparisons use the long fit's common
scale; do not compare their absolute MSE to the earlier short-fit-scaled table.

The new world model is frozen during three 200-update policy fits, all with
32-step imagination and terminal critic bootstrap enabled. Validation chooses
updates 200/0/0. Final seeds 750–752 are evaluated both with the incoming actor
and its selected candidate under identical conditions:

| Seed | Selected update | Incoming → selected survival (s) | Incoming → selected joint RMSE (rad) | Falls / trials |
| --- | ---: | --- | --- | ---: |
| 0 | 200 | 1.6467 → 1.9778 | 0.13793 → 0.14224 | 9 / 9 |
| 1 | 0 | 2.3511 → 2.3511 | 0.09388 → 0.09388 | 9 / 9 |
| 2 | 0 | 1.8933 → 1.8933 | 0.12083 → 0.12083 | 9 / 9 |

Seed zero survives longer with worse tracking. The other selected actors'
recorded trajectories are exactly unchanged under an independent evaluation.
No candidate reaches the ten-second gate; the best incoming actor remains the
best selected actor. All refitted dynamics input-gradient/reload diagnostics and
all actor reload/frozen-model checks pass. The [paired comparison](../output/research/g1-invariant-comparison.json)
preserves the scope and both sets of metrics.
The critic still consumes privileged state including absolute root X/Y. This
change makes the world model equivariant, not the complete actor/critic
objective; critic sensitivity to an arbitrary horizontal origin needs its own
measurement before attributing remaining failures entirely to data coverage.

```sh
moon run --target native scripts/fit_g1_invariant.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-long-dynamics /absolute/path/to/moonrobo/target/learning/g1-ppo-long /absolute/path/to/moonrobo/target/learning/g1-invariant-study
moon run --target native scripts/verify_g1_invariant.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-ppo-long /absolute/path/to/moonrobo/target/learning/g1-invariant-study /absolute/path/to/moonrobo/output/research/g1-invariant-comparison.json
```

## Platform Evidence And Remaining Work

The four ablation cells are registered as `h8-no-bootstrap`, `h8-bootstrap`,
`h32-no-bootstrap` and `h32-bootstrap`. The constrained-model study is registered
as `invariant-refinement`. Each source retains all three candidates, selected
and latest weights, the shared transition dataset, fit report and original
physical traces. Identical data payloads deduplicate through the existing
BlobStore; no new catalog or job service was added. All five experiments remain
unqualified, with physical execution authority false. Complete payload validation
has zero findings.

```sh
moon run --target native scripts/register_g1_diagnostic_runs.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-horizon-ablation /absolute/path/to/moonrobo/target/learning/g1-invariant-study /absolute/path/to/moonrobo/target/learning/experiment-book/moondata
```

Twelve numerical tests now cover return masks, the actor-boundary value/state
gradient, missing-tail reporting, zero-gradient denominators, pose generation,
time-stratified selection and the translated model's multi-step/reload behavior.
The legacy v1 models still load and complete the original physical probe.
MoonBit script checks, `moon info` and scoped formatting complete. No MoonBit
package or cockpit implementation changes are needed for these experiments.

The subsequent [counterfactual study](G1_COUNTERFACTUAL_STUDY.md) measures large
critic-origin sensitivity, removes it, and adds 108 restored physical training
branches. A 2×2 study selects one updated candidate with longer survival and
worse tracking; all still fall. Critic return calibration and stable balance
remain unresolved. Matched efficiency, a reliable controller, complete job recovery and
the wider phase gates remain unfinished; production hardening stays deferred.
