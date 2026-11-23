# Supported live-inference elbows, 23 November 2026

The operator requested trained-model inference with only the two elbows moving,
after accepting the two supported deterministic elbow trials and a 5° feedback
envelope. This path runs the frozen 23-joint actor on LunaKine's Ascend FP32
backend using live E1 joint and IMU observations. The typing reference supplies
model goals; its joint positions are not replayed as robot commands.

## Control and admission

`MOONROBO_E1_ACTOR_HOLD_PROFILE` explicitly selects the tested v2
[`supported-elbow-5deg.json`](../deploy/e1/supported-elbow-5deg.json) holding
parameters. `SupportedHoldFeedback` exposes the same bounded position integral
as the supported manual gesture, without calling a shadow-only control owner
from powered code. Only leg feedforward may adapt; every leg position reference
remains captured at takeover. Neither reported torque nor a nonzero-torque seed
is used.

Feedback updates occur once per new 20 ms model update. A repeated inference
heartbeat must retain identical motor records and holding metadata. The raw
ankle confirmation detector still observes every packet; its isolated-spike
handling, active continuity checks and 40 ms expiry remain in force. Both elbow
following and all other relative joint bounds use the explicitly approved 5°
envelope. Default hold/actor admission remains unchanged.

The first supported actor configuration preserves the model/reference hashes,
23-axis calibration, 25% policy authority, previous-applied-action feedback,
filter, engagement and slew rates. Its absolute elbow bounds are narrowed to
−6° through 0° for both elbows, close to the small movement just exercised.
Other 22 position references stay fixed; 10 entire motor records stay fixed.
Slot 23 remains reserved with zero position, torque and proportional gain.

The independent transport composes `ActorValidator` with `ActorHoldValidator`.
The former recomputes the actor mapping and elbow adapter. The latter recomputes
the leg feedback integral, source-clock timestep, amplitude and slew saturation,
checks the stationary/following bounds, and binds each saved input to raw status.
The offline wire audit additionally requires an identical fresh complete motor
frame, with fresh original model input and inference timestamps.

This is a separate supported commissioning path. It requires its own completed
live-shadow audit, pinned to the exact actor-config and holding-profile hashes,
and a completed actual supported hold/gesture receipt for the same E1 peer and
measured-pose profile. It does not manufacture the old one-degree hold/handback
certificate. Endpoint deletion does not prove factory ownership; physical
observations remain separate from software receipts.

## Shadow and isolated transport

Private host root:
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121`.

`supported-actor-shadow-20261123-1` completed 1,576 real Ascend inferences,
including 1,177 policy updates and 2,714 target heartbeats. Maximum inference
time was 3 ms; input-to-result age was 4 ms and schedule lateness 5 ms. All
processes completed successfully, with capture timeout 124 as designed and no
command publishers created. Independent input/target/integral audit passed.
Both commanded elbows returned exactly to their captured references.

The left commanded offset reached −4.8744° and the right −3.1963°. The raw
policy elbow ranges were approximately −45.76° to −42.99° and −13.99° to
−12.73°. The left requested target was position-clipped on 1,129 policy updates;
this is deliberately constrained neural control, not unmodified whole-body
policy deployment. Shadow holding bias peaked at 0.137 Nm while factory control
remained active; this does not predict the effort required after takeover.

The loopback-only `supported-actor-isolated-20261123-2` replay passed 15,040
actual DDS motor frames / 360,960 records, exact elbow return and endpoint
cleanup. A second scenario kept transport telemetry fresh while freezing model
input; the sender rejected it as `actor input expired` and disconnected.
This replay tests the transport, not a new inference or physical E1 execution.
An earlier isolated attempt created no sender because sudo stripped PYTHONPATH;
the corrected harness supplies dependency paths explicitly inside the namespace.

Validation: 68 scoped native owner/control/ankle tests with warnings denied, 42 Python
deployment tests on `.191`, and release builds of owners, coordinator, launcher
and isolated actor replay. No warning policy or model numerical check was relaxed.

## Powered result

`supported-actor-powered-20261123-1` completed its finite live actor trial.

| Measurement | Result |
| --- | --- |
| Active command duration | 32.281 seconds |
| Live Ascend inference updates / policy updates | 1,615 / 1,177 |
| Target heartbeats / actual DDS motor frames | 2,784 / 15,400 |
| Independently checked wire motor records | 369,600 |
| Maximum inference / original-input age / lateness | 3 / 4 / 5 ms |
| Commanded left / right elbow offset | −4.8744° / −3.6602° |
| Measured left / right elbow offset | −4.6774° / −3.4097° |
| Measured elbow residual at disconnect | −1.2896° / −1.2240° |
| Measured elbow residual three seconds later | 0° / −0.0437° |
| Maximum accepted leg displacement | 3.2567°, left hip yaw, slot 5 |
| Maximum bounded leg holding bias | 7.5 Nm, reached its cap |
| Non-elbow position-target change | Exactly zero for all 22 records |
| Command protocol | Mode 2 once, action 11, axes zero |
| Completion and cleanup | All processes successful; sender participant deleted |

The independent proposal/integral audit matched every model input to the raw
24-record healthy telemetry. The wire audit matched all 15,400 complete frames
to identical fresh admitted actor proposals, including original inference-input
timestamps. The captured target return is exact for both elbows. The changing
live neural outputs differed from the preceding stationary shadow: for example,
the right target folded 3.6602° rather than the shadow's 3.1963°.

The legs were not physically motionless: unchanged position references still
allowed up to 3.2567° supported settling, within the approved 5° envelope.
Holding bias again reached its cap, so preload continuity and precision holding
remain unresolved. This result demonstrates a constrained supported inference
trial, not balance, walking or unmodified whole-body policy qualification.
The profile remains `power_qualified:false`.

The sender's raw receipt retains `physical_handback_verified:false`. The operator
was asked to confirm visible smoothness, steadiness and actual handheld response;
that observation is pending and is not inferred from standing or endpoint cleanup.
Raw archives stay on `.191`; hashes and compact results are recorded in the
[evidence record](evidence/e1-supported-actor-20261123.json).
