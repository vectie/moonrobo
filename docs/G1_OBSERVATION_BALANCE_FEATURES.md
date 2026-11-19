# G1 Balance Features From Joint And IMU Observations

Updated: 2026-10-23. This follows the [balance-channel intervention](G1_BALANCE_INTERVENTION.md).
Root-relative COM/support geometry can now be reconstructed from the existing
joint positions, projected gravity and nominal static model. A causal gyro/
gravity estimate supplies its filtered derivative. New fixed-gain ankle
feedback uses these observation-derived quantities and closely matches the
privileged H10 control comparator. This validates a feature path for learning;
it does not train or qualify a new learned policy.

## Inputs And Differentiable Geometry

[`balance_features.py`](../providers/motion_learning/balance_features.py)
exports compiled static joint/body/site parameters into
`moonrobo.balance-kinematics.v1`. Inference accepts the current physical-unit
observation layout: 29 absolute joint angles, 29 joint velocities, projected
gravity, root-local angular velocity and previous actions. It reads no global
root pose, simulator COM, foot positions, contacts or future physical state.
`make_spec` reads nominal model constants; subsequent feature computation uses
the serialized specification and Torch operations without a live MuJoCo model.

The forward-kinematics layer accounts for fixed body rotations/translations,
hinge axes, off-center joint anchors and compiled reference angles. It follows
the conventions in the [MuJoCo 3.3.7 kinematics implementation](https://github.com/google-deepmind/mujoco/blob/3.3.7/src/engine/engine_core_smooth.c#L32)
and the [joint definition reference](https://mujoco.readthedocs.io/en/3.3.7/XMLreference.html#body-joint).
Root position and heading are absent from its inputs. Body COM positions are
weighted by nominal masses; the support proxy is the mean of two foot sites,
as in the existing teacher. It is not a measured center of pressure or a
contact-aware terrain estimate.

Let `d` be root-relative COM minus this foot-site mean and `g` the normalized
root-frame gravity vector. The world-horizontal error in root coordinates is
`e = d - g * dot(d, g)`. This removes global translation and heading without
manufacturing a global pose. Joint-angle/gravity gradients remain available
for later model-based actor updates. No learned weights are present in this
geometry layer.

## Causal Velocity And Frame Transport

The target velocity is the teacher's filtered derivative of world-horizontal
COM-minus-support error. It is not the robot's root linear velocity. Direct
differences between body-frame errors also include changes in the body's
orientation, so they do not reproduce that target.

For a transport `T` from the previous root frame to the current one, the causal
recurrence is `v_t = 0.8 * T * v_previous + 0.2 * (e_t - T * e_previous) / dt`.
The first actual frame starts with zero velocity. H10 retains nine real
differences; a full-episode recurrence is also evaluated offline. Histories
never cross episode boundaries or use future observations.

Three estimators are compared: body differences with identity transport,
trapezoidal local-gyro rotation, and gyro rotation corrected to agree with
adjacent gravity directions. The correction aligns tilt while gyro supplies
the relative heading estimate. A separate true-rotation transport is an oracle
verification path only. It reproduces the original teacher's finite/full
recurrences and never enters the observation-only controller.

The estimator uses 50 Hz endpoint measurements. It approximates the intervening
rotation, especially during rapid angular changes. Small mean errors must not
be presented as exact reconstruction at every pre-fall state.

## Verification On Native And Recorded States

The [derived report](../output/research/g1-observation-balance-features.json)
records two checks:

- 512 arbitrary translated/rotated poses, with joints perturbed around home:
  maximum geometry error is 1.05e-14 m in FP64 and 1.33e-7 m in FP32.
  These are kinematics checks, not stable physical-control trials.
- All 90 original student/full-teacher intervention episodes, 34,953 observed
  states: FP64 geometry has maximum error 1.78e-15 m. Actual simulator state is
  restored only to generate verification truth. Reconstructing the teacher's
  ankle actions from exact reference features gives zero error.

Recorded velocity/action comparisons use both feature precisions. The table
below shows H10 FP32 features; actions are compared using the FP64 fixed-gain
formula to isolate feature error. The closed-loop controller below runs fully
in FP32.

| Scope / estimator | Velocity RMSE (m/s) | Ankle setpoint RMSE (rad) |
| --- | ---: | ---: |
| Train / direct body differences | 0.04276 | 0.02033 |
| Train / gyro | 0.0004703 | 0.002957 |
| Train / gravity plus gyro | 0.0002924 | 0.002952 |
| Canonical / direct body differences | 0.02569 | 0.006881 |
| Canonical / gyro | 0.0001780 | 0.001735 |
| Canonical / gravity plus gyro | 0.00004780 | 0.001758 |

Gravity correction reduces velocity error, but not every action metric improves
over gyro-only transport. For gravity-plus-gyro H10, maximum ankle setpoint
errors reach 0.2702 rad on training states and 0.2134 rad on canonical states.
Those maxima are retained alongside pooled errors; this is not a bounded-error
state estimator. Whole-episode results and individual episodes remain in the
report. Correlated states and teacher-only repeated conditions are not treated
as independent reliability samples.

Static model masses, COM offsets and ideal simulated IMU signals are assumed.
Payload/model mismatch, sensor bias/noise and hardware calibration remain
outside these measurements. Source validation/test families are used here for
numerical comparison without fitting parameters or selecting weights.

## Observation-Derived Feedback In Closed-Loop Physics

The three frozen disturbance-initialized parents are evaluated on stand/sway/
wave at fresh reset seeds 9800–9802, nine trials per parent. Variants are fixed
before running: unchanged student, four ankle channels from privileged H10
teacher, and those four channels from observation-derived H10 features plus
the original fixed teacher gains. The other 25 channels remain the original
learned actor's outputs on each actual resulting trajectory.

| Variant | Falls / 27 actor-condition cells | Mean survival (s) | Mean joint RMSE (rad) |
| --- | ---: | ---: | ---: |
| Original student | 12 | 7.2111 | 0.04760 |
| Privileged H10 ankle feedback | 6 | 9.9363 | 0.03828 |
| Observation-derived H10 ankle feedback | 6 | 9.9348 | 0.03830 |

Both feedback variants remove the three sway falls and retain six wave falls.
Seed one completes all nine trials with either variant; seeds zero and two
still fall near the time cap. The close aggregate results show that current
observation-derived features can support this fixed-feedback behavior. They
do not establish universal equivalence to privileged feedback or long-duration
control. This also differs from the preceding full-memory four-ankle experiment
in memory length and reset conditions; its zero falls are not a paired baseline
for these new trials.

All 81 new control episodes retain complete state/action datasets. Online and
offline FP32 feature reconstruction agree within approximately 1e-6 on these
trajectories, with exact episode reset and actual previous-action histories.
Actor weights/normalization remain unchanged; no policy checkpoint or optimizer
is produced. Fixed gains and geometry are not relabeled as learned ankle control,
and `learned_policy_qualified`/`physical_execution_allowed` remain false.

The [subsequent learned-feedback comparison](G1_LEARNED_BALANCE_FEEDBACK.md)
uses these features: full causal memory removes observed canonical falls,
while independent-joint-sine coverage remains open. The original next-step
rationale follows.

The next learning comparison can use these verified physical-unit features.
It should fit feedback only from training-family data, retain the rare estimator
errors, and distinguish finite/full causal memory from learned action mapping.
Current H10 oracle failures show that improving geometry alone does not close
the control gap. Stable learned control and the later model-based efficiency,
workbench, E1 and hardware phases remain incomplete.

## Artifacts And Reproduction

The completed directory is `target/learning/g1-balance-features`. Its charter
freezes providers, configuration, source intervention, parent actors and teacher.
`kinematics.json` contains portable nominal constants; `feature-verification.json`
retains per-episode estimates; `feature-feedback-physics.jsonl.gz` retains all
new physical-simulation trajectories. SHA-256 binds each artifact. These are
local research diagnostics, with no new candidate registration or hardware path.

```sh
moon run scripts/verify_g1_balance_features.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-balance-intervention /absolute/path/to/moonrobo/target/learning/g1-temporal-disturbance /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-balance-features-new
moon run --target native scripts/report_g1_balance_features.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-balance-features-new /absolute/path/to/moonrobo/output/research/g1-observation-balance-features-new.json
```

Use a fresh directory and the pinned CPU/G1 environment. The original source
log's integrity and earlier native validation remain hash-bound. All nine new
control datasets pass the canonical native reader, which validates every split
before emitting sampled training endpoints. Forty-five numerical tests and
five native motion-data tests pass. New checks cover native geometry with
nonzero anchors/reference angles, finite-difference gradients, causal prefix
independence, online/offline alignment, filter reset and frame-transport sign.
`moon info`, scoped formatting and interface review complete. This study adds
no public MoonBit API or physical execution capability.
