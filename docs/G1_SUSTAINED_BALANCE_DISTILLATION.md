# Sustained Observation-Only Balance Distillation

Updated: 2026-10-23. A training-selected observation-only ankle law now completes
all 27 thirty-second canonical actor-condition cells and all 27 separate
training-family audit cells. Three frozen temporal parents share this fitted
law. This transfers the stronger [teacher result](G1_LONG_BALANCE_DIAGNOSIS.md)
into learned feedback, but does not establish independent new training seeds,
broad motion coverage, release approval or hardware qualification.

## Fresh Fit Data And Fixed Controls

The [configuration](../examples/learning/g1-sustained-balance.json) is frozen
before collection. The teacher runs nine training cases at new resets 6900/6901:
eighteen thirty-second episodes, 27,000 transitions, zero falls. Actual applied
teacher actions supply labels. Prior audit/canonical records do not enter fitting.

Two shared deterministic ankle representations use exactly these points:

- **Range:** horizontal COM/support error, causal filtered velocity, own joint
  speed and bias: sixteen active coefficients.
- **Pose/rate:** adds projected-gravity tilt and local angular rate: twenty-four
  active ankle coefficients.

Both also fit an optional three-coefficient waist mapping from clipped fitted
pitch and waist speed. It removes the fitted own-ankle speed term before
coupling. In the reduced representation that term can absorb omitted pose/rate
effects; it is not necessarily physical damping. Censored least squares excludes
labels at residual/actuator bounds from the linear solve. Coefficients and
normalization are fitted, without copying teacher gains.

Inference uses nominal differentiable kinematics, observed joint/gravity/gyro
inputs and a full causal velocity filter. It reads no simulator COM, contacts,
global root pose or future physical observations. The filter retains two frames
and one velocity state per episode. Parents keep their existing H10 observation
history and F10 analytic goal preview, with unchanged weights/normalization.

Training ankle RMSE is 0.008806 rad for range and 0.0001159 rad for pose/rate.
Retained maximum errors are 0.30728 and 0.004146 rad. A closer teacher fit alone
does not establish better closed-loop tracking.

## Training-Family Selection Before Final Runs

Five fixed variants run nine training cases per parent at reset
`7100 + 10000 * parent_seed`, giving 135 episodes. The first two have identical
fitted tensors and differ only in output bound. They are new fits to the stronger
teacher, not old v1 policies relabeled with a larger bound.

| Variant | Active coefficients | Falls / 27 | Survival (s) | Joint RMSE (rad) |
| --- | ---: | ---: | ---: | ---: |
| Range, 0.30 rad, ankle | 16 | 27 | 6.44444 | 0.051776 |
| Range, 0.45 rad, ankle | 16 | 0 | 30.00000 | 0.032851 |
| Range, 0.45 rad, ankle plus waist | 19 | 0 | 30.00000 | 0.034457 |
| Pose/rate, 0.45 rad, ankle | 24 | 0 | 30.00000 | 0.033047 |
| Pose/rate, 0.45 rad, ankle plus waist | 27 | 0 | 30.00000 | 0.034415 |

The predeclared ordering prefers fewer falls, longer survival, lower joint RMSE,
then fewer active coefficients. It selects **range / 0.45 / ankle only**. This
choice is written before any final canonical/audit rollout. Only that selected
arm receives final evaluation; final behavior of the other arms is not inferred.

## Final Thirty-Second Physics

Each selected composite runs stand/sway/wave at new resets 10200–10202, nine
trials per parent. The separate nine-case audit uses reset
`7200 + 10000 * parent_seed`. The privileged teacher runs nine unique canonical
and 27 audit conditions, without repeated canonical runs for irrelevant parents.

| Controller / scope | Falls / cells | Survival (s) | Joint RMSE (rad) |
| --- | ---: | ---: | ---: |
| Selected learner / canonical | 0 / 27 | 30.00000 | 0.035421 |
| Selected learner / training-family audit | 0 / 27 | 30.00000 | 0.037381 |
| Privileged teacher / canonical | 0 / 9 | 30.00000 | 0.035994 |
| Privileged teacher / training-family audit | 0 / 27 | 30.00000 | 0.038810 |

All learner stand, sway, wave, pose-offset and joint-sine conditions complete.
Per-parent canonical RMSE is 0.035435/0.035595/0.035232 rad. Four head outputs
replace the ankles; the other 25 outputs match the contemporaneous frozen parent
exactly on each actual trajectory.

The selected controller needs no explicit pose/rate input or waist replacement
for these observed conditions. This does not prove those features never help.
Three inherited parent seeds share one fitted law and canonical resets; the
cells are correlated, not three independent new learning runs. Repeatedly studied
procedural families and ideal simulated sensors are not an untouched release
benchmark, noisy-sensor test or hardware evidence.

## Checkpoints, Verification And Platform

[`sustained_balance.py`](../providers/motion_learning/sustained_balance.py)
adds `moonrobo.g1-learned-balance-actor.v2`, declaring optional pose/rate/waist
mapping, output bound, full observer, joint names and embedded frozen parent.
Selected residual authority is 0.45 rad; original actuator position bounds
remain enforced. Old temporal/v1 loaders reject v2. No new critic is fitted.

The [verified report](../output/research/g1-sustained-balance-study.json) retains
243 episodes and 332,700 transitions: eighteen fit episodes, 135 selection
episodes and ninety final learner/teacher episodes. Every episode passes the
native reader with its actual split. Online/offline features and controls pass
the predeclared float32 bounds, and uncontrolled parent outputs match exactly.
An independent train-corpus reader reproduces all fifteen checkpoints
tensor-for-tensor. Forty-nine numerical tests and nine registry tests pass.
No public MoonBit API is added.

The [registration record](../output/research/g1-sustained-balance-registration.json)
publishes three selected checkpoints as `balance-sustained`. Fitting, selection
and final evaluation archives seal separately; optional
`learning-balance-selection` retains all 135 selection episodes without calling
them fitted data. The representative dataset is only the first training episode.
The viewer's baseline is the privileged teacher, not the old parent. Its nine
unique canonical trials are reused for three comparisons. Viewer traces are
reconstructed from recorded next states with the pinned model, without policy
reruns. Existing API readback matches all three reports at thirty seconds;
MoonData validation has zero findings. Numeric passes grant no release or
physical authority.

Collection takes 10.64 s and two closed-form fits take 0.027 s. All collection,
selection, final evaluation and serialization takes 469.79 s on the two-thread
CPU setup. Prior teacher/parent development, native verification and registration
are excluded. The current threshold is already reached by initialization; a
later comparison cannot call these initial passes a world-model/PPO advantage.

## Reproduction And Remaining Work

The study is `target/learning/g1-sustained-balance`; its registration producer is
`target/learning/g1-sustained-balance-registration`. Archived sources, config and
charter bind the teacher, parents and pinned G1 environment.

```sh
moon run --target native scripts/fit_g1_sustained_balance.mbtx REPO ORIGINAL_BALANCE_STUDY TEACHER_STUDY FRESH_STUDY
moon run --target native scripts/report_g1_sustained_balance.mbtx REPO STUDY OUTPUT_JSON
moon run --target native scripts/export_g1_sustained_balance.mbtx REPO STUDY FRESH_EXPORTED
moon run --target native scripts/register_g1_sustained_balance.mbtx REPO STUDY EXPORTED ROBOBOOK NOW_MS OUTPUT_JSON
```

This supplies a bounded stable learned initializer and retains failed controls.
Next establish fuller physically feasible references and a matched quality/cost
protocol using the same initializer and action mapping. World-model/PPO learning
claims, independent motion/noise/generalization gates, complete workbench, E1
and hardware remain unfinished plan work.
