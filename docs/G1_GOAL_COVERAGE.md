# G1 Goal Coverage And Model Refinement

Implemented: 2026-10-23. This closes another local collection/model/policy loop.
One refined candidate passes the original nine two-second simulator trials and
an independent fresh two-second suite. It fails every extended ten-second trial.
The result is a bounded short-horizon pass, not stable long-term balance or
hardware qualification.

## Independent Training Goals

Earlier training references were all the home standing target. The initial
normalization windows have zero varying goal channels. A new `pose_offset`
reference samples independent per-episode target offsets: up to 0.04 rad for
lower-body joints, 0.08 rad for waist joints and 0.12 rad for upper-body joints.
Goals remain constant within an episode; the actual body still resets to home.
Actuator limits clip targets. A separate seeded NumPy generator preserves the
old reset and exploration streams.

The [collection configuration](../examples/learning/g1-goal-collection.json)
mixes three standing and three pose-offset cases at friction 1.0/0.8/0.6.
All pose-offset variants belong to the same training source family. No canonical
sway/wave clips are copied into training: their periodic references remain
validation/test cases. Constant episode goals also match the current imagined
rollout's fixed-goal assumption; this is not a future-reference-sequence model.

Three PPO seeds use the same ±0.3 rad residual bound, architecture and maximum
budgets as the preceding wide-action run. The input normalization still comes
from the initial training windows. The actual new collection varies all 29
goal channels, and reports retain min/max targets plus selected first-layer
goal-column weight changes. This measures coverage, not a causal explanation
of performance.

## Run

Use the environment/assets from [CPU physics](G1_CPU_PHYSICS.md) and initial
windows from [dynamics fitting](G1_DYNAMICS.md). Run from the repository root:

```sh
moon run --target native scripts/fit_g1_ppo.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-dynamics /absolute/path/to/moonrobo/target/learning/g1-ppo-goals /absolute/path/to/moonrobo/examples/learning/g1-ppo-goal-fit.json
moon run --target native scripts/compare_g1_learning.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-ppo-wide /absolute/path/to/moonrobo/target/learning/g1-ppo-goals /absolute/path/to/moonrobo/target/learning/g1-goal-comparison goal-coverage
moon run --target native scripts/fit_g1_goal_dynamics.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-dynamics /absolute/path/to/moonrobo/target/learning/g1-ppo-goals /absolute/path/to/moonrobo/target/learning/g1-goal-dynamics
moon run --target native scripts/fit_g1_goal_policy.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-goal-dynamics /absolute/path/to/moonrobo/target/learning/g1-ppo-goals
moon run --target native scripts/verify_g1_goal_candidate.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-goal-dynamics
```

Use new output directories/experiment IDs for new runs. The scripts preserve
numerical providers, reports, weights, raw transitions and physics traces.
There is no optimizer/RNG recovery or unattended job service.

## PPO Coverage Study

The three new PPO seeds complete 160 updates, consuming 152067/156228/157491
training transitions and about 54–57 seconds each. Selection uses validation
seeds 10–12. Shared final scoring uses new seeds 300–302 on the canonical three
cases. All candidates still fall:

| Training data | Seed | Mean survival (s) | Mean joint RMSE (rad) | Falls / trials |
| --- | ---: | ---: | ---: | ---: |
| Standing only | 0 | 1.5022 | 0.0925 | 9 / 9 |
| Standing only | 1 | 1.6489 | 0.0866 | 9 / 9 |
| Standing only | 2 | 1.7400 | 0.0884 | 9 / 9 |
| Mixed pose goals | 0 | 1.5067 | 0.0876 | 9 / 9 |
| Mixed pose goals | 1 | 1.5111 | 0.0883 | 9 / 9 |
| Mixed pose goals | 2 | 1.7333 | 0.0878 | 9 / 9 |

Coverage is broader, but this budget does not establish a consistent control
improvement. Actual sample counts differ under the shared maximum budgets.
These conditions are now inspected development conditions.

## Fresh Data, Dynamics And Policy

Selected checkpoints from all three mixed-goal PPO seeds recollect four seeds
(40–43) over six training cases: 72 episodes and 6077 transitions. Two reach the
two-second limit; 70 end in falls. These are longer/upright and failure segments,
not a successful motion library. IDs bind each episode to its policy digest.

Merged with the initial 60 episodes, the dataset has 132 episodes and 9788
transitions. The actual MoonBit reader produces 7544 train, 658 validation and
662 test windows of length eight. Held-out state, next-state, action, observation,
goal, context, termination and truncation arrays remain exactly unchanged.
Three refitted dynamics models beat persistence and pass input-gradient/reload
diagnostics. Their normalization comes only from the new training set; errors
across rounds are not directly comparable without a common scale.

Three actor/critic refinements use dynamics seed zero and weights-only warm
starts from the corresponding PPO checkpoints. Optimizer state resets, while
the prior actor/critic buffers are retained. This is PPO-assisted refinement,
not three independent world-model/controller pipelines or training from scratch.
The frozen model has an eight-step fitting horizon; actor updates imagine 32
steps. Physics validation selects updates 200/50/50, including the prior actor
as an update-zero candidate. All final evaluation is independent MuJoCo physics.

| Refined seed | Mean survival (s) | Mean joint RMSE (rad) | Falls / nine trials, seeds 400–402 |
| --- | ---: | ---: | ---: |
| 0 | 1.6400 | 0.1232 | 9 |
| 1 | 2.0000 | 0.0822 | 0 |
| 2 | 1.8867 | 0.1203 | 8 |

The successful short candidate's checkpoint SHA-256 is
`633115f63afb5e78f448ec20c9dd32cb53c3f12d781d4cd002892da01857cdbe`.
Independent reload repeats its nine trajectories exactly. Fresh seeds 500–502
also have zero falls over nine two-second trials, with mean RMSE 0.0834 rad.
Extending those same cases to ten seconds produces 9/9 falls, with mean survival
2.2867 s and RMSE 0.0937 rad. Stopping at two seconds censors this later failure;
it cannot support a long-term stability claim. All three original training
seeds and all failure evidence remain available.

## Platform Evidence And Limits

The complete run is registered in the research RoboBook's MoonData as
`goal-refinement`. Its source holds the original policy/dynamics/data/weights,
the qualification follow-up summary and all three follow-up physics reports.
Payload/catalog validation passes with zero findings. Registration and the
provider's short-trial pass grant no physical execution authority.

Open **MoonData → Learning experiments → goal-refinement / seed 1**. The
inspector states the original two-second scope and shows fresh/extended results.
**Recorded evaluation** switches between original, repeat, fresh two-second and
extended ten-second traces, each resolved through its own registered checksum.
The original pass stays visible alongside the longer-trial failure. Old
experiments without follow-ups remain inspectable with their original tracks.

Six numerical tests cover return masks and pose generation. Original physics
collection/regression checks pass. Registry and UI tests cover retaining an
extended failure after removing the original run, mode binding and switching
between the corresponding evidence. Browser checks use the actual registered
records at desktop and small portrait/landscape sizes.
Verification: 884 native repository tests, 119 active cockpit JavaScript tests
and six numerical tests pass; one existing JavaScript test is skipped. The UI
release build, `moon check`, `moon info` and scoped formatting complete. Existing
toolchain warnings remain.

The subsequent [ten-second study](G1_LONG_DURATION_STUDY.md) now collects beyond
the old censoring boundary and trains for a declared longer duration. It retains
this two-second comparison; all long-study selected actors still fail. Better
goal coverage alone has not solved stability. Matched cost-to-target measurement,
broader motion skills, complete skill/version review, and E1 adaptation remain
outstanding. General production hardening stays deferred.
