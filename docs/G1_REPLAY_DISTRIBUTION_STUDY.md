# G1 Replay Distribution And Repeated Policy Updates

Updated: 2026-10-23. This follows the [temporal-value comparison](G1_TEMPORAL_VALUE_STUDY.md).
Frozen-direction tests do not support removing teacher replay: with the value
tail, teacher-only directions improve remaining physical return in 15/18
actor/minibatch combinations, current-policy directions in 11/18 and mixed
directions in 10/18. A subsequent teacher-only training comparison still fails
every wave trial. Replay affects individual updates, but changing it alone does
not establish stable control.

## Frozen Replay-Direction Comparison

The same six original supervised actors (frame/preview × seeds 0/1/2), mixed
world-model seed zero and initial physically calibrated value networks remain
fixed. Value payloads are loaded only when their critic was fitted at actor
update zero. The value checkpoint's selected actor is not substituted for the
original supervised actor. Model/value parameters and normalization are checked
unchanged after every probe.

Teacher starts are the exact filtered teacher tensors from the prior value
study. Current starts use only its first actual critic-training collection,
excluding independent value audits and later changed-policy records. Both
retain causal H10 observation histories, changing joint references and original
remaining task time. All input and source files are hash-bound.

Three batch-64 distributions are compared over three coupled draws per actor,
with and without the value tail. Mixed has 32 teacher and 32 current points.
Teacher/current-only batches retain the corresponding shared 32 indices and
add 32 independent points from that source. Draw zero reconstructs the original
trainer's mixed first batch exactly; its resulting preview seed-zero actor
matches the actual saved one-update actor bit for bit. Other draws use declared
seed offsets, rather than choosing a favorable draw after scoring.

Every direction is one fresh Adam step at the existing 0.0001 learning rate.
The same saved simulator integration states, causal actor memory and reference
phases score each direction. Restored baseline trajectories pass the 1e-8
tolerance. Physical local return ends at H32 or a fall; remaining return ends
at the original ten-second task boundary or a fall. Snapshots overlap within
episodes, and different draws reuse actors/origins. Counts below are diagnostic
batch counts, not independent qualification trials or significance estimates.

| Value tail | Replay | Positive physical local batches / 18 | Positive remaining batches / 18 | Mean local Δ | Mean remaining Δ |
| --- | --- | ---: | ---: | ---: | ---: |
| Off | Teacher | 12 | 11 | +0.01358 | +0.25957 |
| Off | Current | 12 | 8 | +0.00565 | +0.33105 |
| Off | Mixed | 13 | 11 | +0.02066 | +0.34599 |
| On | Teacher | 10 | 15 | +0.01213 | +0.45843 |
| On | Current | 8 | 11 | +0.01089 | +0.20110 |
| On | Mixed | 10 | 10 | +0.02387 | +0.16648 |

All 18 fitting objectives improve in each row, while physical improvements vary.
Means give each actor/draw batch equal weight. Standing can conceal dynamic
regressions: preview/tail-on/teacher has 7/9 positive remaining batch means
overall, but its dynamic-only mean is −0.07054 with 5/9 positive batches. The
report retains these subsets and parameter-direction cosine comparisons.
The table does not prove a globally optimal replay mixture or that model/value
derivatives become physically correct when fitted on teacher states.

## Teacher-Only Repeated Training

Following the frozen comparison, two new cells use teacher-only actor starts
and the calibrated value tail. Original supervised policies, dynamics, critic
architecture, 100 actor updates, 600 critic steps per refresh and refreshes at
0/20/40/60/80 stay unchanged. Current actor physics still calibrates value.
The initial physical datasets, training/audit errors and validation match the
prior mixed-tail cells exactly. Later actor-dependent physics can diverge.

Actor batches retain the original first 32 teacher draws and add 32 teacher
draws from a dedicated generator. Unused current-index draws preserve the
original main sampler cadence. Both preview actors selected at update one match
the previously diagnosed teacher direction exactly, including all parameter
and normalization tensors. This verifies the sampling intervention against
actual trained checkpoints, rather than only reimplementing a sampler in a test.

Validation seeds 30–32 select weights, including update zero. New final seeds
9200–9202 do not select weights. Prior selected mixed-tail actors are independently
re-scored on these same final conditions; the earlier 9100 results are not used
as if they were paired outcomes:

| Inputs / seed | Teacher selected update | Prior mixed → teacher survival (s) | Prior mixed → teacher RMSE (rad) | Teacher falls / 9 |
| --- | ---: | --- | --- | ---: |
| Frame / 0 | 0 | 7.5444 → 7.5444 | 0.04574 → 0.04574 | 3 |
| Frame / 1 | 0 | 7.4978 → 7.4978 | 0.04639 → 0.04639 | 3 |
| Frame / 2 | 0 | 7.6600 → 7.6600 | 0.04452 → 0.04452 | 3 |
| Preview / 0 | 1 | 7.5400 → 7.5444 | 0.04630 → 0.04641 | 3 |
| Preview / 1 | 1 | 7.1244 → 7.7600 | 0.04841 → 0.04458 | 3 |
| Preview / 2 | 0 | 7.3667 → 7.3667 | 0.04715 → 0.04715 | 3 |

Preview seed-one recovers standing completions and improves aggregate tracking.
Every teacher-only actor still fails wave 3/3, and four of six retain update
zero. Later validation updates regress. None reaches the frozen zero-fall,
mean-RMSE ≤0.15 rad gate, so no longer qualification follow-up runs. Favorable
initial parameter directions did not establish useful repeated training.

## Evidence And Reproduction

The [direction report](../output/research/g1-replay-direction-study.json)
retains all 108 directions, three draws, subsets, frozen bindings, saved-delta
hashes and the exact mixed first-step reconstruction. The
[teacher-training report](../output/research/g1-teacher-value-study.json)
retains matched initial calibration, both exact teacher first-step checks,
same-condition prior scores, validation histories and MoonData references.

Training cells register as `temporal-teacher-value-frame` and
`temporal-teacher-value-preview`, with selected/latest actor-value pairs,
reused world-model evidence, actual critic/audit physics and teacher replay.
Full MoonData validation has zero findings. Frozen-direction probes remain
local diagnostics; they are not fabricated training successes or hardware
qualification. No policy gains physical authority through registration.

```sh
moon run scripts/probe_g1_replay_directions.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-temporal-value-study /absolute/path/to/moonrobo/target/learning/g1-dynamic-refit/mixed /absolute/path/to/moonrobo/target/learning/g1-replay-direction-probe
moon run --target native scripts/report_g1_replay_directions.mbtx /absolute/path/to/moonrobo/target/learning/g1-replay-direction-probe /absolute/path/to/moonrobo/output/research/g1-replay-direction-study.json
moon run scripts/fit_g1_teacher_value.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-temporal-value-study /absolute/path/to/moonrobo/target/learning/g1-dynamic-refit/mixed /absolute/path/to/moonrobo/target/learning/g1-replay-direction-probe /absolute/path/to/moonrobo/target/learning/g1-teacher-value-study
moon run --target native scripts/report_g1_teacher_value.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-teacher-value-study /absolute/path/to/moonrobo/target/learning/g1-temporal-value-study /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/experiment-book/moondata /absolute/path/to/moonrobo/output/research/g1-teacher-value-study.json
```

Use fresh probe/training directories. Sources and charters are frozen before
workers launch. The trainer's absent `actor_replay_distribution` still defaults
to the previous mixed path; the teacher branch adds no actor/critic parameters
or public MoonBit API. Existing 37 numerical and ten relevant MoonBit tests pass,
alongside actual restored-physics, frozen-weight and saved-first-step checks.
`moon info` and scoped formatting complete before handoff.

Old goal/long/counterfactual-dynamics held-out batch JSON and completed temporal-value source
physics JSON were losslessly archived as `.json.gz` for space. Weights, training
reports, source compressed training records and registered BlobStore payloads
remain intact. Restore an old raw path with `gzip -d` before a workflow that
still requires it. The current shared teacher dataset remains uncompressed.

The subsequent [temporal PPO baseline](G1_TEMPORAL_PPO_STUDY.md) now uses those
same policy/value interfaces and incoming weights. Three seeds complete 270
actual train episodes and 31,446 transitions, with every training episode
falling and all final policies failing qualification. A separate unchanged-actor
noise comparison shows both exploration sensitivity and missing noise-free
train-family coverage. This advances the outstanding SM-2 baseline without
establishing a matched learning-efficiency result.
Stable all-case control, matched quality/cost, full workbench/E1 phases and
physical qualification remain incomplete. No generic production hardening is
introduced by this study.
