# G1 Full-Reference Learning Comparison

Updated: 2026-10-23. Status: two bounded, matched-prior studies completed;
all twelve final policies fail the unchanged reference quality gate.

This extends the [reference initialization](G1_REFERENCE_INITIALIZATION.md)
and [platform integration](G1_REFERENCE_PLATFORM.md) with actual full-body
reference world-model/PPO learning. It adds executable SM-3 evidence. It does
not establish successful learning efficiency, unseen-motion generalization,
full SuperMimic reproduction, skill release or hardware qualification.

## Frozen comparison

Both methods start from the same pre-supervision zero-output actor checkpoint:
`799850fb2ee31bdd3a3267ac42742e17e6137c5f20bbabb5881543f26124f94e`.
Its learned residual is zero, but its previously fitted relative balance head,
reference-derived normalization and static body geometry remain active. This
is a shared inherited prior, not learning from scratch. The three seeds govern
new collection and optimization; their incoming neural weights are identical.
The initial mean policy falls in all 27 cells, averaging 5.62815 seconds.
The separately reported supervised initializer already passes; its history
and development cost are not assigned to either new learner as zero-cost work.

The nine reference clips and manifest are unchanged:
`8b310f2a6ab44e8a997aaba92f62a23ec13ceb0fa79ddeb0e0eaf5299bf569b5`.
Reference poses/velocities are commands and integration snapshots initialize
physics. Source controls are never actor targets or dynamics labels in these
studies. Models and critics fit only newly collected learner trajectories.

Each method/seed receives three collection/update cycles, with nine physical
episodes per cycle and a maximum of twelve actor steps per cycle. The first
noisy collection is shared within a seed and charged to each standalone method;
subsequent collections use each method's own policy. Three additional episodes
per seed are held out from fitting for model diagnostics. Every final-cycle
checkpoint is evaluated; there is no seed or checkpoint selection.

| Setting | Shared or method-specific behavior |
| --- | --- |
| Actor | H10 observations of 93 channels; current/F10 reference goals of 338 channels; causal relative balance feedback |
| Physical exploration | Gaussian standard deviation 0.03 in 29 raw action logits, followed by the same bounded action map |
| Reward | Shared body/root position, sign-invariant root orientation and joint tracking terms, with action-change penalty |
| End | Hard fall at root height <0.35 m or upright Z <0.5; finite reference end has zero continuation value |
| Critic | Same architecture, common-data normalization and physical Monte Carlo return fitting; 128 updates/cycle |
| World model | Own physical replay only; eight-step residual fit, 300 updates/cycle; frozen during actor updates |
| Model actor | 32 imagined steps from current-cycle episode starts, then physical-return critic tail; mean actions |
| PPO | Pre-fit physical GAE, gamma 0.99, lambda 0.95, clip 0.2; KL 0.02 can stop updates early |
| Final quality | All 27 cells complete, zero falls; per-trial joint RMSE ≤0.03 rad, body/root position RMSE ≤0.05 m, root orientation RMSE ≤0.1 rad |

The critic includes physical state relative to reference root position, H10
history, actual/reference velocity EMA memory, current reference, context,
clip identity, phase and remaining time. These are training privileges, not
new actor inputs. Carrying the EMA is necessary because ten observations alone
do not specify the full controller state. Imagined steps preserve that memory,
actual previous controls, reference phase and finite-end semantics.

The reward is a local design, with a smooth orientation surrogate, not an exact
implementation of the paper's reward or quality metric. This critic fits
physical returns rather than the paper's imagined-GAE recipe. PPO has stochastic
physical exploration; model optimization uses deterministic imagined means.
Equal maximum steps and episode counts do not imply equal actual optimizer
steps, transitions, arithmetic or wall time.

## Physical results

The first frozen protocol collects from 5/15/25 seconds across the three
cycles. The separate follow-up collects from 0/10/20 seconds to include startup.
Both evaluate all nine clips at 0/10/20 seconds, running their remaining
30/20/10 seconds. They are known training-family coverage cells.

| Training origins | Method | Seed | Falls / 27 | Mean survival s | Pooled joint RMSE rad | Actor steps |
| --- | --- | --- | --- | --- | --- | --- |
| 5/15/25 s | Model-based | 0 | 27 | 3.869 | 0.06988 | 36 |
| 5/15/25 s | PPO | 0 | 27 | 5.733 | 0.05357 | 6 |
| 5/15/25 s | Model-based | 1 | 27 | 5.869 | 0.05342 | 36 |
| 5/15/25 s | PPO | 1 | 27 | 5.582 | 0.05303 | 7 |
| 5/15/25 s | Model-based | 2 | 24 | 7.534 | 0.05231 | 36 |
| 5/15/25 s | PPO | 2 | 27 | 5.618 | 0.05276 | 7 |
| 0/10/20 s | Model-based | 0 | 27 | 1.525 | 0.27359 | 36 |
| 0/10/20 s | PPO | 0 | 27 | 5.342 | 0.05464 | 5 |
| 0/10/20 s | Model-based | 1 | 27 | 6.696 | 0.05793 | 36 |
| 0/10/20 s | PPO | 1 | 27 | 5.837 | 0.05368 | 5 |
| 0/10/20 s | Model-based | 2 | 27 | 5.999 | 0.05682 | 36 |
| 0/10/20 s | PPO | 2 | 27 | 5.896 | 0.05357 | 7 |

Pooled RMSE is weighted by recorded steps, including early falls; qualification
uses every individual trial and completion, not this pooled number. The first
model seed 2 completes only three remaining-ten-second cells. It does not
complete any remaining-thirty/twenty-second cell or pass the quality gate.

The follow-up removes the omitted first-five-second collection region, but
does not solve qualification. Reset states and remaining collection horizons
both change, so it does not isolate a duration effect. Each cycle still uses
one origin across all clips; actor updates target current-cycle origins. The
small sequential curriculum may forget earlier origins. These results do not
show that coverage is irrelevant, nor that either algorithm cannot learn with
a more suitable model, exploration or budget.

Both reports mark cost-to-target `not-reached`. There are only initial/final
quality checks, so exact first crossing is unmeasured. The complete sequential
CPU provider intervals are 371.29 and 353.29 seconds, with 1.63 and 1.28 seconds
of preceding setup. Reports separately retain collection, model/critic/actor
optimization, diagnostics, serialization and final evaluation. Native
verification and historical prior development are outside those provider
intervals. These times are not successful cost-to-target or GPU equivalents.

## Verification and diagnostic limits

Each study contains 333 episodes: 27 initial, 27 shared first collections,
9 model diagnostics, 108 method-exclusive later training and 162 final tests.
The two studies contain 666 recorded episodes and 167,996 transitions
(84,259 + 83,737), all streamed through the native MotionDataset reader.
Shared episodes are physically stored once per study, while their cost is
charged to each method. Repeated baselines across studies are not independent
evidence of new motion coverage.

Numerical archives store state/observation/action tensors in float32. Original
MuJoCo quality scalars use float64; these archives do not retain bit-exact
float64 trajectories. Independent reconstruction checks causal histories,
reference features, saved actor logits, seeded exploration, applied actions,
reward, termination, continuity and quality. Across both studies the largest
action reconstruction error is 0.00002379 rad, below the frozen 0.00008-rad
tolerance; shared reward reconstruction is exact. Reconstructed quality metrics
differ from original scalars by at most 5.71e-9 on these records.

A directional finite-difference check through the complete 32-step imagined
chain, controller EMA/history and critic tail agrees with automatic
differentiation to absolute error 1.12e-9 / 2.18e-9 for the two saved probes.
Model/value parameters stay unchanged. This verifies implementation gradients
at the checked points, not agreement with physical simulator Jacobians.

Post-training held-out diagnostics compare predicted position changes with
the trapezoidal integral of endpoint velocities. This is an approximation to
five MuJoCo substeps, not an identity or a new acceptance gate:

| Protocol | Physical root residual | Model root residual | Model / physical joint residual |
| --- | --- | --- | --- |
| 5/15/25 s, three seeds | 0.0835–0.0853 mm | 1.022–1.724 mm | 1.139–1.223 |
| 0/10/20 s, three seeds | 0.0865–0.0883 mm | 0.788–0.929 mm | 1.193–1.240 |

This motivates testing a structured root position/velocity update before
scaling training. It does not prove this residual caused the falls. Joint
integration residuals differ much less and should not be described as a
general failure of every state channel. Better model prediction versus
persistence likewise does not establish useful control gradients.

## Artifacts and next work

- [First verified report](../output/research/g1-reference-learning-comparison.json)
- [Startup-coverage verified report](../output/research/g1-reference-learning-full-phase.json)
- [First frozen config](../examples/learning/g1-reference-learning-comparison.json)
- [Follow-up frozen config](../examples/learning/g1-reference-learning-full-phase.json)
- [Fit orchestration](../scripts/fit_g1_reference_learning.mbtx)
- [Verification orchestration](../scripts/report_g1_reference_learning.mbtx)
- [Learning implementation](../providers/motion_learning/reference_learning.py)
- [Task/reward implementation](../providers/motion_learning/reference_task.py)

Study directories are `target/learning/g1-reference-learning-comparison` and
`target/learning/g1-reference-learning-full-phase`. They preserve incoming and
cycle checkpoints, physical archives, frozen numerical sources, charter,
report and `model-consistency.json`. Source report hashes are respectively
`6bd12a20a0e2c2760d480e5d5994310be69301ce7bab7ac8b202400f22490df7`
and `8f95fdad0f0d0b0b7f20bee654f0ceaae13093230ee32ae5e5bccbe3ab973ada`.

These new studies are research artifacts and have not yet been registered in
MoonData; the previously registered reference initialization studies remain
available. Next freeze a measured model-consistency intervention, evaluate its
physical return directions, and compare learning with adequate exploration,
coverage and budgets. Keep the same physical quality target. Full body/model
3D inspection, broader motion inputs, E1 adaptation and hardware remain open
in the [phase plan](SUPERMIMIC_PHASE_PLAN.md).

The subsequent [root integration diagnostic](G1_REFERENCE_ROOT_INTEGRATION.md)
now tests that measured hypothesis with paired fits and 75 new physical probes.
Short root prediction improves, but every integrated positive-direction probe
reduces physical return. A post-hoc decomposition identifies critic-tail sign
reversal in two seeds, alongside other model-prefix errors. A controlled
prefix-only direction test is next; no new policy or default model is adopted.
