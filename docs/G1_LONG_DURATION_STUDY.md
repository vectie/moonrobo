# G1 Ten-Second Development Study

Updated: 2026-10-23. This extends the [goal-coverage study](G1_GOAL_COVERAGE.md)
past its two-second cutoff. Ten seconds is a maximum rollout duration, not an
observed success duration. All trials terminate at an actual fall without
padding or resetting the same episode.

## Frozen Protocol

The new [PPO configuration](../examples/learning/g1-ppo-long-fit.json) preserves
the ±0.3 rad residual range, 20 ms control period, reward, actor/critic widths,
and fall thresholds (root height 0.35 m or upright Z 0.5). Three seeds receive
200 updates, at most 250000 physics steps and 240 seconds each. Selection uses
validation seeds 30–32, with the initial actor eligible at update zero. Final
PPO evaluation uses seeds 600–602 over stand, sway and wave: nine trials per
candidate. The gate requires zero falls over ten seconds and mean joint RMSE
at most 0.15 rad. It was fixed before the run.

Actor and critic weights plus their normalization buffers start from the
preceding model-refined candidates. Optimizers reset. This is continued
development with weights-only initialization, not exact recovery, training
from scratch or a matched learning-speed comparison.

| PPO seed | Selected update | Actual physics steps | Training seconds | Mean survival (s) | Mean joint RMSE (rad) | Falls / trials |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 20 | 231760 | 76.63 | 1.6511 | 0.1376 | 9 / 9 |
| 1 | 0 | 238511 | 83.79 | 2.4422 | 0.0943 | 9 / 9 |
| 2 | 0 | 240567 | 85.09 | 1.8822 | 0.1207 | 9 / 9 |

All three complete 200 updates. Seeds one and two retain their initial
checkpoints under validation selection; longer allowed episodes and additional
PPO updates have not solved balance. Latest trained weights are also retained.

## Tail Data And Model Refitting

Each selected PPO checkpoint collects one new reset seed in each split:
70/71/72, 80/81/82 and 90/91/92 for train/validation/test. Each train seed covers
six stand/constant-pose cases at three friction values; validation is sway and
test is wave. Training exploration noise is 0.02 rad; held-out collection has
no action noise. Source-family ownership stays fixed. The new [collection
script](../scripts/fit_g1_long_dynamics.mbtx) archives its providers and configs.

All 24 new episodes fall, adding 2255 transitions to the previous 132 episodes.
The merged dataset contains 156 episodes and 12043 transitions. Previously
recorded held-out numeric arrays remain equal as prefixes; new held-out
episodes extend those arrays. They are not used for gradient updates.

| Split | Eight-step windows | Starts at or after 2 s | New transitions at or after 2 s |
| --- | ---: | ---: | ---: |
| Train | 9101 | 26 | 47 |
| Validation | 934 | 8 | 15 |
| Test | 916 | 3 | 10 |

The [dynamics configuration](../examples/learning/g1-dynamics-long-fit.json)
draws 32 early and 32 late examples per batch, with replacement. Selection uses
half global validation MSE plus half late validation MSE. Normalization still
uses only training windows. Existing configurations retain uniform sampling
and global-only selection. A missing late pool rejects the requested sampling
or selection; absent late diagnostics are null rather than a zero error.

All three fitted models beat state persistence globally and in the available
late validation/test windows; frozen-weight input gradients and checkpoint
reload checks pass. These are eight-step predictions starting later in an
episode, not ten-second predictions. Only three overlapping late test windows
exist, all from one new episode. Oversampling 26 training windows does not
create more independent evidence. No physical-gradient or stable-control
qualification follows from these prediction results.

## Run And Evidence

Use the environment and independently licensed assets from
[CPU physics](G1_CPU_PHYSICS.md). These commands run from the repository root;
use fresh output directories for new experiments:

```sh
moon run --target native scripts/start_g1_long_study.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-ppo-long
moon run --target native scripts/fit_g1_long_dynamics.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-goal-dynamics /absolute/path/to/moonrobo/target/learning/g1-ppo-long /absolute/path/to/moonrobo/target/learning/g1-long-dynamics
moon run --target native scripts/fit_g1_goal_policy.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-long-dynamics /absolute/path/to/moonrobo/target/learning/g1-ppo-long /absolute/path/to/moonrobo/examples/learning/g1-policy-long-fit.json
moon run --target native scripts/report_g1_long_study.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-ppo-long /absolute/path/to/moonrobo/target/learning/g1-long-dynamics /absolute/path/to/moonrobo/output/research/g1-long-study-summary.json
```

The [policy configuration](../examples/learning/g1-policy-long-fit.json) uses
the new dynamics seed zero, frozen for 32-step imagined updates, and weights-only
starts from the corresponding long-PPO candidates. Selection uses validation
seeds 30–32, including update zero. Final independent physics evaluation uses
fresh seeds 700–702 and the same ten-second gate. All three training seeds and
their failed trials must remain in the report. The previous two-second results
and registered follow-up evidence remain available as a separate experiment.

## Policy Outcome And Platform Registration

All three refinements complete 200 imagined updates. Validation selects update
zero for every seed, retaining the incoming policy rather than an improved
candidate. Final physics on seeds 700–702 gives:

| Refined seed | Selected update | Mean survival (s) | Mean joint RMSE (rad) | Falls / trials |
| --- | ---: | ---: | ---: | ---: |
| 0 | 0 | 1.6489 | 0.1383 | 9 / 9 |
| 1 | 0 | 2.3200 | 0.0937 | 9 / 9 |
| 2 | 0 | 1.9089 | 0.1203 | 9 / 9 |

No candidate qualifies. Different final seeds explain small differences from
the PPO table; they do not demonstrate a refinement gain. All reported frozen
dynamics and actor reload checks pass. The [machine-readable summary](../output/research/g1-long-study-summary.json)
contains model scores, sparse-tail counts, actual budgets and selected weight
digests. Large raw batches, weights and complete traces stay under ignored
`target/learning/` directories.

The combined model/policy run is registered in the research RoboBook's MoonData
as `long-refinement`, alongside `first`, `warm` and `goal-refinement`. Its three
selected candidates remain unqualified. Open **MoonData → Learning experiments
→ long-refinement** to compare failures and inspect the actual trajectories.
The original evaluation label reads **Original 10 s trials** and explicitly
states that each trajectory stops at its fall or time limit. The maximum
duration comes from the sealed producer report, so early falls do not cause
the UI to mislabel this as a two-second experiment. Old reports without duration
metadata remain readable. No follow-up mode is manufactured for this run.

The negative result narrows the next research question: eight-step prediction
improvement on a few late, overlapping windows has not produced a useful
32-step control update. The subsequent [diagnostic ablations](G1_DIAGNOSTIC_ABLATIONS.md)
measure action sensitivities near those failures, test horizon/critic variants
and correct a measured horizontal-origin dependency. One policy seed improves
survival, but all still fall. Repeating longer training alone is not supported
by this round. Stable balance, broader skills, matched efficiency, E1 adaptation and
the full phase gates remain outstanding.

Verification: 885 native repository tests, 119 active cockpit JavaScript tests
and eight numerical tests pass; one existing JavaScript test remains skipped.
The release UI build and host build complete. `moon info` reports zero errors,
scoped `moon fmt` completes, and the generated interface adds only the intended
optional evaluation-duration field for this change. Existing toolchain warnings
remain. Registered payload validation passes with zero findings.
