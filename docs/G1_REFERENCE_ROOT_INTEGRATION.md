# G1 Reference Root Integration Diagnostic

Updated: 2026-10-23. Status: paired models and 75 physical probes completed.
Root translation integration improves short prediction, but does not supply a
better policy direction in this experiment. It is not adopted as the default
model or a qualified skill.

The [preceding reference-learning comparison](G1_REFERENCE_LEARNING_COMPARISON.md)
found a root position/velocity consistency gap. This study tests that measured
hypothesis before spending more on full policy training. It is local SM-3
research, not completion of the quality/cost or complete platform gates.

## Controlled intervention

The [frozen charter](../examples/learning/g1-reference-root-integration.json)
uses the completed startup-coverage study's three seeds. Each seed contributes
only its nine shared first-collection episodes at reference origin zero.
Neither arm fits later method-specific episodes or the three held-out noisy
diagnostic episodes. No source-control actor labels are introduced.

Each pair receives identical model tensors, train-only normalization, replay,
minibatch sequence, optimizer settings and 900 eight-step updates. The free arm
predicts all state residuals. The integrated arm replaces root translation by
`p_next = p + dt/2 * (v_world + v_world_next)`; joint positions, velocities and
quaternion retain the existing residual model. Both have the same parameter
count, with the integrated arm's three direct-position output channels unused.
This is an approximation to five simulator substeps, not an exact physical law.

The incoming actor is the same nonpassing zero-output checkpoint with inherited
relative feedback and normalization. Each seed uses its already fitted common
cycle-one physical-return critic, shared between the two new arms. No critic
or actor is trained here. The resulting models differ from the preceding
study's final models: these receive 900 updates on first-collection data only.

One H32 full-parameter actor gradient is computed from all nine training resets
for each model. Its scale is calibrated by raw action-logit RMS response on that
seed's complete common training collection. Both signs at RMS 0.001 and 0.005
are tested on three predeclared known clips: stand, pose-offset and independent
joint-sines, all at origin zero with friction 1. Calibration does not prescribe
identical action changes on subsequent closed-loop physical states.

One deterministic baseline per clip is shared across seeds/arms. The six
directions × two signs × two amplitudes × three clips plus three baselines
produce 75 actual episodes. Each restores simulator integration state only at
reset and then evolves normally. Full remaining-reference discounted returns
and their first-32-step prefixes use the preceding shared reward and gamma 0.99.
No model/seed/checkpoint is selected and no 27-cell qualification is claimed.

## Prediction and physical direction results

Held-out metrics use overlapping autoregressive windows from three new-noise
realizations per seed. They are not unseen reference families or independent
windows. Root RMSE below averages squared coordinate errors across all window
steps, rather than Euclidean endpoint distance.

| Seed | H8 free root RMSE mm | H8 integrated mm | H32 free mm | H32 integrated mm |
| --- | --- | --- | --- | --- |
| 0 | 2.802 | 1.083 | 10.273 | 6.071 |
| 1 | 3.415 | 1.454 | 12.648 | 17.192 |
| 2 | 3.944 | 1.224 | 23.519 | 13.123 |

H8 root prediction improves in all three seeds; H32 improves in two and worsens
in one. Global normalized H8 MSE improves slightly in all three, while H32
global MSE improves in two. Better integration consistency alone does not
establish improved long-horizon predictions in every state channel.

| Arm | Raw-logit RMS | Seeds with improved mean full return, + direction | Same, − direction | + direction trials improving / 9 |
| --- | --- | --- | --- | --- |
| Free | 0.001 | 1 / 3 | 2 / 3 | 3 / 9 |
| Free | 0.005 | 1 / 3 | 2 / 3 | 3 / 9 |
| Root-integrated | 0.001 | 0 / 3 | 3 / 3 | 0 / 9 |
| Root-integrated | 0.005 | 0 / 3 | 3 / 3 | 0 / 9 |

Both integrated-arm amplitudes reduce full physical return on every selected
clip when moving in the positive training-gradient direction. Reverse probes
improve all three seed means. All 75 episodes still fall. This rejects adopting
the tested root integration change as a demonstrated policy-learning fix; it
does not prove that structure is always harmful or that reverse-gradient
training is a valid algorithm. Directions optimize nine starts, whereas these
physical diagnostics use only the fixed three-clip subset. Finite parameter
steps can also cross nonlinear regions; some large-step predicted returns
decrease even in the positive direction.

## Prefix and critic-tail decomposition

After completing the frozen experiment, a separate numerical diagnostic splits
the existing directions into predicted H32 prefix and critic-tail derivatives.
It creates no new directions or physical data. Below derivatives are with
respect to signed raw-logit RMS calibration along the saved direction. Physical
numbers are central secants between the ±0.001 probes, not exact derivatives.

| Arm / seed | Model prefix derivative | Critic tail derivative | Physical H32 secant | Physical full secant |
| --- | --- | --- | --- | --- |
| Free 0 | −2.44 | +78.43 | −3.98 | −16.67 |
| Integrated 0 | −27.33 | +85.42 | −3.74 | −19.81 |
| Free 1 | +0.30 | +43.41 | −3.65 | −12.35 |
| Integrated 1 | +5.64 | +15.56 | −1.83 | −6.53 |
| Free 2 | +87.91 | +145.86 | −0.0023 | +3.95 |
| Integrated 2 | −55.99 | +1830.79 | −0.99 | −7.18 |

For integrated seeds 0 and 2, the modeled prefix correctly predicts the sign
of the observed negative physical prefix change along this direction, while
the much larger positive critic tail reverses the full modeled derivative.
Seed 1 also has a wrong prefix sign, so attributing every error to the critic
would exceed the evidence. These observations motivate a fresh, controlled
prefix-only direction comparison. No tail-free gradient has been physically
tested in this study, and no successful training result follows from this
decomposition.

The first float64 finite-difference check at raw-logit RMS step 1e-6 does not
agree for free seed 2. An explicit 1e-6/1e-7/1e-8 sweep reduces its full
derivative error from 96.72 to 0.949 to 0.00949 (AD derivative 233.77). All twelve
prefix/full checks meet the stated local tolerance at 1e-8. All base/plus/minus
rollouts retain all 96 active imagined steps, so fall-mask changes do not
explain this discrepancy. The initial result is preserved separately. This
shows substantial local curvature and implementation consistency at the
checked points, not physical derivative correctness or a globally smooth
objective.

## Verification and artifacts

All 75 episodes / 26,217 transitions pass the native MotionDataset reader.
Reconstruction from the incoming checkpoint, saved parameter directions and
coefficients agrees with recorded logits to 1.68e-8, applied actions to
0.00001601 rad and causal features to 1.26e-6. Reward and discounted return
reconstruction match. Archives are float32, with original scalar physical
quality metrics calculated by float64 MuJoCo. New integrated checkpoints use
an explicit format/loader and preserve prediction through save/reload; the
existing residual model and checkpoint loader are unchanged.

- [Verified physics/model report](../output/research/g1-reference-root-integration.json)
- [Post-hoc gradient decomposition](../output/research/g1-reference-root-decomposition.json)
- [Numerical experiment](../providers/motion_learning/reference_root_integration.py)
- [Integrated model](../providers/motion_learning/root_integrated_dynamics.py)
- [Fit/probe orchestration](../scripts/probe_g1_reference_root.mbtx)
- [Verification orchestration](../scripts/report_g1_reference_root.mbtx)

The study directory `target/learning/g1-reference-root-integration` contains
frozen numerical sources/configuration, six models, six saved directions,
physical archives and numerical decomposition. Source report SHA-256:
`512bb2ed61d9ba77e3117465c9f5d4933ed6570a909bc1aae90095ea747e7fa8`.
Provider time is 127.48 seconds on local CPU, excluding native verification and
post-hoc decomposition. Prior data/value fitting costs remain separate. No
successful cost-to-target, registration in MoonData or hardware result is
claimed. The [full phase plan](SUPERMIMIC_PHASE_PLAN.md) remains active.

The subsequent [tail direction comparison](G1_REFERENCE_TAIL_DIRECTIONS.md)
now tests new prefix-only directions using these same frozen models. All six
model/seed means improve at both amplitudes; free-model directions improve
all nine individual full-return cells, integrated directions eight. All 72
new episodes still fall. This supports an actual training ablation, not a
qualified policy or adopting the integrated model as the default.
