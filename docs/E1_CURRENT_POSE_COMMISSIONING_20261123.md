# E1 measured-pose commissioning, 23 November 2026

The constrained actor completed live shadow on `.191`, but the first powered
pose hold stopped on left-hip movement. **The real actor elbow trial did not
start.** A steady robot and a responding handheld after disconnect do not turn
this aborted hold into a completed commissioning receipt.

## Scope and preparation

The operator confirmed Walk mode, feet planted with nearly straight knees, a
crane bearing the robot's weight, a clear area and an operator at handheld
emergency disable. These conditions were reconfirmed before the powered hold.

The preceding raw-packet investigation established a persistent SDK motor 19
reading of `-0.00476837158203125` rad, independently matching the decoder. It
did not establish a unit-specific encoder zero. An explicit optional
`moonrobo.e1-current-pose-commissioning.v1` profile therefore preserves that
exact measured knee position for an unchanged hold and elbow-only actor trial.
It does not write a zero, clip telemetry or permit leg target changes. Other
legs retain nominal SDK admission limits, and the relative stationary and
isolated-ankle checks remain active. Default powered admission remains strict.

`scripts/prepare_e1_current_pose_commissioning.mbtx` generates this profile
from the independent raw-knee audit and binds its SHA-256 digest. The runtime
loads it only when `MOONROBO_E1_CURRENT_POSE_PROFILE` is explicitly set. The
transport requires the actor and its successful hold/handback receipt to use
the same profile. A handback receipt cannot be issued for this aborted hold.

For actor operation, SDK elbows 3 and 14 are the only moving targets. The
right-elbow exemption applies only to the relative stationary guard; the actor
still checks both elbows' position, slew and following limits. Hold mode keeps
all 24 command records unchanged. The SDK's record 23 remains reserved with
zero position gain, rather than being treated as a physical waist-roll joint.

## Completed software and shadow checks

The model was the existing frozen 23-motor actor, executed by LunaKine Ascend
FP32 on the 310P3, with 25% policy authority. Its OM SHA-256/model identity is
`031c4f35c09b86233d4ae05a44fdf5b6942a327224b112f7bc043b53c59727c0`.
There was no LLM action generation or preset fallback.

| Check | Observed result |
| --- | --- |
| Live hold shadow | 1,001 ms, 702 packets, 87 proposal heartbeats; all 24 targets fixed |
| Hold-shadow leg variation | Maximum 0.0218566°; one isolated left ankle spike cleared |
| Live actor shadow | 31,683 ms, 1,585 inference updates, including 1,177 policy updates |
| Actor timing | Maximum inference 3 ms, scheduling lateness 5 ms, input age 5 ms |
| Actor target audit | 22 fixed records; both elbows returned exactly to baseline |
| Isolated transport completion | 15,229 frames / 365,496 records; one mode-2 request; exact return |
| Isolated stale-inference test | Stopped after 16 frames when model input expired despite fresh telemetry |

The isolated transport tests replayed genuine saved actor proposals with clocks
rebased inside a loopback-only network namespace. They exercised the actual DDS
sender but could not reach the E1. They were not physical-motion or closed-loop
qualification. Shadow following is likewise not physical tracking validation.

## Powered hold and stop

The run `current-pose-powered-hold-20261123-1` sent one mode-2 request and
46 motor-command frames before the existing stationary guard stopped SDK
motor 7, left hip pitch. Active transmission lasted approximately 93 ms.

The independent outbound CDR audit checked all 1,104 motor records. All 24
targets, gains, desired velocities and feedforward torques remained exactly
unchanged. Both command endpoints were deleted after the stop. The planner
failed, so there is no completed hold planner report or valid hold/handback
qualification for the actor stage.

The subsequent [holding-effort investigation](E1_HOLDING_EFFORT_20261123.md)
exposed intermittent nonzero torque that the earlier single-frame snapshots and
shadow JSON did not reveal. It records the remaining prerequisites for an
effort-preserving transition; the powered hold here remains an aborted trial.

The saved telemetry gives a different signature from the isolated ankle
glitches:

| Measurement | Result |
| --- | --- |
| Initial left hip | -5.8030380° |
| First sample beyond 1° relative displacement | 96.390 ms after the first target's receipt timestamp |
| Samples beyond 1° | 118 consecutive samples, through 436.730 ms |
| Peak relative displacement | -2.6446492° at 285.306 ms |
| Integrated reported velocity at that peak | -2.7343139°, differing from measured displacement by 0.0896646° |
| Left hip at roughly 3 s | About -0.131° relative to baseline |

These times use the first proposal's host receipt timestamp; the sender's
93 ms active duration starts at actual first transmission. The peak occurred
after transmission stopped. Velocity agreement is evidence consistent with
physical settling, not independent external proof of motion: both signals come
from the robot's status stream. This event must not be discarded by extending
the one-packet ankle filter. The right hip also changed during the transition.

The operator reported **steady; handheld responds; no visible leg movement**
after disconnect. A subsequent receive-only preflight collected 690 complete,
error-free samples, with the same robot participant and no competing motor or
mode publisher discovered. No further powered trial was performed during this
investigation.

## Remaining cause and next qualification

An unchanged position target is not the same as preserving the factory
controller's holding effort. `Sample::stand_candidate` uses measured positions,
zero desired velocities and feedforward torques, position gain 50 and damping
5, except ankle damping 1. The full 24-record low-level command takes over leg
holding as well as the elbows. The supplied SDK example also sends complete
arrays and uses configurable, model-dependent gains for its locomotion policy.
Neither that example nor the status stream identifies the active factory
Walk controller's commanded targets, gains or gravity-support effort.

A change in support effort at takeover is therefore a plausible explanation,
not an established firmware or decoder defect. No gain increase, torque bias,
range widening or factory-controller-equivalence claim was made from this
capture. The feet-planted, crane-supported posture also does not establish
the loads on each leg.

Before another powered actor trial, qualify a holding transition that actually
preserves the current supported posture: establish the appropriate leg holding
gains and support effort, or establish a documented interface that retains
factory leg control while commanding the elbows. The current SDK array API
does not document that partial-ownership behavior. Test the resulting path in
replay and live shadow, then complete a fresh hold and observed handback before
starting the actor. Do not substitute an expired or aborted hold receipt.

## Evidence and verification

Remote artifacts are under
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121/`:

- `current-pose-hold-shadow-20261123-1/`
- `current-pose-actor-shadow-20261123-1/`
- `isolated-current-pose-20261123-1/{complete,stale-inference}/`
- `current-pose-powered-hold-20261123-1/`, including raw `wire.pcap`, decoded
  `status.ndjson`, `targets.ndjson`, `wire-audit.json`, `measured-motion.json`
  and `hip-stop-audit-v2.json`.

Local report copies are in the ignored
`output/e1-current-pose-commissioning-20261123/` directory. The reproducible
offline analysis is `scripts/audit_e1_hold_stop.mbtx`; it reads saved reports
and telemetry only and creates a new diagnostic report. The captured-wire
auditor now also supports strict actor-proposal matching and freshness checks
through `--actor-profile`.

Validation after the stop: 24 native tests passed on both macOS and `.191`
with `--deny-warn --warn-list +73`; 21 network-free transport/audit tests passed
on `.191`; scoped native checks passed. The hip regression verifies that the
first over-limit hip sample still stops even with both elbows enabled. Scoped
interfaces and formatting were refreshed without changing unrelated training
or website work. The additional 23 native ankle-detector regression tests also
passed locally with warnings denied.
