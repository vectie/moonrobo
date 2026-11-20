# Minimum-motion E1 candidate search — 20 November 2026

No powered motion was started. The quietest training reference and the closest
reference to the current robot pose were both tested through the real actor on
Atlas `.191` using live E1 telemetry. Both still produced substantial leg PD
targets. Choosing a quieter reference did not isolate the trained whole-body
policy's leg output.

The [evidence manifest](evidence/e1-minimum-motion-20261120.json) pins the raw
rankings, prepared references, live inputs/outputs, independent CPU replays and
checks. Raw artifacts are outside Git in
`output/e1-minmotion-20261120-edhu16RZ`. The corresponding Atlas installation is
`/home/jiaanguo/lunakine-deployment-20261117/minmotion-20261120-edhu16RZ`.

## Reference selection

All 75 original curriculum motions were checked against their dataset hashes.
The dataset SHA-256 matches the frozen actor's saved identity:
`346d00c65383dc9bb08627307cca7f76f9b627c5bc769838bd5b977c257ecaf5`.
The 40 previously saved fine-tuned-policy simulation trajectories were also
hash-checked and ranked separately. Their quietest saved rollout,
`dance/B_DadDance`, has 50.45° peak-to-peak excursion in its most active leg
joint; that is not a small-leg-motion candidate.

For the training references, two different questions matter:

| Reference | Largest leg-joint excursion within clip | Largest initial leg adjustment from live pose | Largest leg displacement from live pose over full clip |
| --- | ---: | ---: | ---: |
| Cellphone typing while standing, `bones-230711__cellphone_typing_stand_one_hand_idle_R_001__A423_M` | **2.10°** | 18.02° | 19.25° |
| Neutral idle, `bones-230104__neutral_idle_loop_002__A103_M` | 5.74° | 11.72° | **12.20°** |

Typing ranks first by within-clip leg excursion; neutral idle ranks first by
maximum full-clip leg displacement from the captured live pose. Each has 677
reference frames / 13.52 seconds. Typing has 14.55° maximum within-clip movement
across all joints; neutral idle has 5.74°. These are reference-coordinate
measurements using candidate +1 direction / zero-0 calibration, not verified
hardware tracking or predicted actuator motion. Entry into the reference pose
must not be omitted from the movement comparison.

`scripts/rank_e1_training_motion.mbtx DATASET LIVE_STATUS NEW_REPORT` reproduces
the reference ranking, checks all motion hashes/23-axis padding and requires a
healthy complete 24-ID status snapshot. It reports both criteria explicitly.

## Actual policy outputs on live telemetry

Both references were exported using the existing
`e1_train export-lunakine-reference` command and training's
`MotionLibrary::goal`, including velocities and heading-relative previews.
The offline exporter verified the scene, mesh, profile and motion identities;
it opened no simulator, SDK, tensor backend or accelerator. Its full executable
was rebuilt with existing warnings visible (465 warnings); a warning-denied
full training build is not claimed. The separate native deployment runner
passes its warning-denied check.

The receive-only runner now accepts an optional prepared-reference JSON after
its existing arguments. It uses the validated deployment `Clip` reader,
preserves source tilt, aligns initial reference heading to measured heading,
and samples the original 20 ms timeline without looping or stretching it.
Actual goals and all raw observation features are recorded each tick. Reference
sampling creates no control authority or writer.

| Live NPU shadow result | Typing | Neutral idle |
| --- | ---: | ---: |
| Actor updates | 676 | 676 |
| Missed 20 ms periods | 0 | 0 |
| Maximum inference time | 3 ms | 3 ms |
| Left ankle-roll target range | **19.77–36.97°** | **24.53–42.23°** |
| Largest target offset from measured leg pose | **34.55°** | **39.81°** |

Measured baseline left ankle roll was approximately 2.43°. The typing policy
also requested left hip yaw up to 25.56°. These are **nominal position-PD
targets**, not measured leg motion. They are sustained actor outputs, not the
previous one-packet ankle telemetry artifact. The simulation allows PD targets
outside joint travel with force limits, so the selected model's ±0.26 rad ankle
travel is not treated as a verified hardware command limit or silently applied
as a clipping rule.

Eight captured inputs from each run, spanning startup, history rollover and the
last frame, were replayed through independent ONNX Runtime CPU FP32. Maximum
error across each set of 232 outputs was `3.5762786865234375e-6` for idle and
`2.2649765014648438e-6` for typing, below the unchanged `0.0001` comparison
tolerance. The CPU replay consumes each tick's actual goals; it does not reuse
the first preview for later ticks.

All 1,352 status frames retain IDs 0–23, six inactive internal actor channels
remain zero, and SDK slot 23 remains inactive. Post-run discovery/telemetry
preflight passed. The actor sessions exited; no motor/mode command was sent and
no automatic control service was installed. Eight native tests passed,
including noncommuting reference-heading/tilt alignment. The operator confirmed
crane support, Walk mode and emergency-disable attendance before these checks;
that confirmation was not used to override unresolved actuator calibration.

## Remaining powered-control work

Neither tested actor output meets the intended minimal-leg-motion trial.
The existing unverified whole-body joint/IMU calibration and hardware gain/limit
questions from the [deployment record](E1_TRAINED23_DEPLOYMENT_20261120.md) also
remain. Do not feed these raw whole-body outputs to the January sender.

Keeping leg command records fixed would require an explicit constrained actor
adapter, with simulation and live-shadow validation of the changed controller,
plus verified calibration/gains for the arm joints it will move. That is a
different controller from the currently evaluated whole-body policy and must be
identified as such. The previously commissioned deterministic elbow path does
not establish that qualification, and it was not silently substituted for this
trained-model request.
