# G1 Learned Ankle Feedback With Causal Observation Memory

Updated: 2026-10-23. A feedback head fitted on training-family data now completes
all 27 ten-second stand/sway/wave actor-condition cells with full causal memory.
H10 retains three falls; unchanged parents fall twelve times under the same
conditions. Independent joint-sine tasks still fail with either head. This is a
bounded development result, not complete control coverage or a deployable skill.

The [subsequent platform/duration study](G1_BALANCE_PLATFORM_AND_DURATION.md)
registers the fitted policies and extends evaluation to thirty seconds: every
learned wave trial then falls, including full-memory trials after ten seconds.
The short result must be read with this longer-duration limit.

## Learned Mapping And Frozen Protocol

Following [observation-feature verification](G1_OBSERVATION_BALANCE_FEATURES.md),
[`learned_balance.py`](../providers/motion_learning/learned_balance.py) fits
four affine ankle mappings. Each uses horizontal COM/support error, its causal
filtered velocity, that ankle's joint speed and a bias. Pitch uses X components;
roll uses Y. All sixteen coefficients, including signs and bias, are fitted.
Teacher gains are not copied into the head.

Residuals are clipped to ±0.3 rad, added to the commanded joint target and
clipped to actuator bounds. This differs from the parent's tanh mapping. The
other 25 channels retain the frozen parent's outputs on each resulting physical
trajectory. Parents are the three selected disturbance-trained H10/F10 actors;
their weights and normalization remain unchanged.

Nominal kinematics and gravity/gyro transport are fixed physical priors.
Inference reads joint angles/speeds, projected gravity, local angular velocity,
actual previous actions and commanded targets. It reads no simulator COM,
contacts, global root pose or future physical observations. Full memory is a
recurrent velocity state initialized to zero per episode; inference retains
two feature frames and one velocity, rather than a growing history. H10 retains
nine finite differences with zero filter state at the oldest frame. The parent
still uses ten observation frames and ten commanded goal previews.

The [configuration](../examples/learning/g1-learned-balance.json) is frozen
before fitting/evaluation. Source intervention records must satisfy both trial
scope `train` and episode split `train`, with mode `student` or `teacher`.
This excludes canonical stand records even though stand is a training family.
Sway/wave do not contribute to normalization, labels or fitting.

The resulting 54 episodes contain 19,390 points: nine training cases for each
of three parent contexts and two behavior modes. Full-memory teacher commands
are recomputed from recorded simulator states **only as training labels**.
Both memory arms use these same points/labels. Teacher gains were chosen by
earlier training-family work. Repeated teacher trajectories and adjacent states
are correlated; they are not independent reliability samples.

Each joint solves float64 ordinary least squares on labels strictly inside
both residual and actuator bounds. Saturated actions are censored observations
of the linear residual, so they do not enter the solve as linear targets. All
training points contribute to input normalization and the clipped-action error
report. Designs have rank four, with about 14,940 uncensored pitch and 17,800
roll points. Coefficients and conditioning are retained in the report.

There is **one deterministic fitted head per memory arm**, shared by three
parents, not three independent new training seeds. There is no parameter sweep,
validation-based checkpoint choice or final-test selection. Six composite
checkpoints embed the float32 head, normalization, nominal kinematics, observer
specification and entire frozen parent in the distinct format
`moonrobo.g1-learned-balance-actor.v1`. The new `load_learned_balance` restores
them; the legacy loader rejects the different action mapping.

Training ankle-action RMSE is 0.009576 rad for H10 and 0.002777 rad for full
memory. Both retain a maximum error of 0.234626 rad on rare training states.
Full-memory pitch coefficients approach the teacher law; roll coefficients
differ more. This is structured teacher distillation with a physical prior,
not learning a new feedback law from reward alone.

## Paired Physical Results

Each parent runs unchanged/H10/full at canonical reset seeds 9900–9902. A
separate nine-case train-family audit uses reset `6600 + 10000 * parent_seed`,
without added exploration noise. All 162 new episodes and 69,958 actual MuJoCo
transitions are retained, including applied controls and terminal states.

| Scope / mode | Falls / 27 cells | Mean survival (s) | Mean joint RMSE (rad) |
| --- | ---: | ---: | ---: |
| Canonical / unchanged parent | 12 | 7.24296 | 0.047640 |
| Canonical / learned H10 | 3 | 9.97852 | 0.038179 |
| Canonical / learned full | 0 | 10.00000 | 0.036362 |
| Train-family audit / unchanged parent | 15 | 6.31481 | 0.053479 |
| Train-family audit / learned H10 | 9 | 9.01926 | 0.043798 |
| Train-family audit / learned full | 9 | 9.26519 | 0.042851 |

Canonical falls per parent are 6/3/3 unchanged, 0/0/3 with H10 and 0/0/0 with
full memory. H10's remaining failures are parent-two wave trials, with mean
survival 9.9356 seconds. Full memory completes all three motions for every
parent. Per-parent RMSE is 0.036324/0.036362/0.036399 rad, below the previously
stated 0.15-rad small-suite threshold.

Both heads complete all stand and pose-offset audit cases. Every remaining
audit failure is an independent-joint-sine case: nine of nine with either arm,
mean survival 7.06 s with H10 and 7.80 s with full memory. This coverage gap also
appeared under privileged teacher control in prior diagnostics.

The full composite policies meet the **observed small canonical numeric
threshold**. These families have been repeatedly examined during development;
fresh resets do not create an untouched release test. Shared fitting and teacher
dependencies limit independence. Longer duration, disturbances, broader motions,
model mismatch and hardware remain unqualified. `release_qualified` and
`physical_execution_allowed` are false.

Source loading, relabeling, features and both solves take 9.19 s; fitting plus
all physics evaluation and serialization takes 108.57 s. These local two-thread
CPU timings exclude prior teacher/parent training, and establish neither
from-scratch cost nor a model-based/PPO efficiency advantage.

## Verification And Reproduction

The [derived report](../output/research/g1-learned-balance-study.json) retains
fit statistics, every trial, pooled metrics, source/checkpoint hashes and native
reader results. `target/learning/g1-learned-balance` contains archived providers,
config/charter, training-source manifest, six checkpoints and complete compressed
evaluation trajectories. The subsequent platform study adds MoonData importer
support for these research artifacts. A production policy runner is still absent.

Every checkpoint is reloaded before evaluation and compared tensor-for-tensor
with the fitted head and frozen parent. All learned-control rollouts reconstruct
offline features within 1.02e-6 of online features and ankle controls within
9.30e-6 rad of applied actions. Other channels match the contemporaneous parent
output exactly. All nine datasets, including every train/validation/test
episode, pass the canonical native reader.

Forty-seven provider tests and five native motion-data tests pass. New checks
cover full-memory online/offline equivalence, constant inference history,
episode initialization and recovery of a planted law under residual/actuator
saturation. No public MoonBit API is added.

```sh
moon run --target native scripts/fit_g1_learned_balance.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-balance-intervention /absolute/path/to/moonrobo/target/learning/g1-temporal-disturbance /absolute/path/to/moonrobo/target/learning/g1-temporal-input-study /absolute/path/to/moonrobo/target/learning/g1-learned-balance-new
moon run --target native scripts/report_g1_learned_balance.mbtx /absolute/path/to/moonrobo /absolute/path/to/moonrobo/target/learning/g1-learned-balance-new /absolute/path/to/moonrobo/output/research/g1-learned-balance-study-new.json
```

Use the pinned CPU/G1 environment and a fresh output directory. Platform
registration and longer rollouts are now recorded in the subsequent study.
Next diagnose the remaining wave and joint-sine failures. Compare world-model/PPO refinement from this initializer
after establishing intended behavior coverage. Full motion references, GPU
scaling, the complete workbench, E1 and hardware remain unfinished plan phases.
