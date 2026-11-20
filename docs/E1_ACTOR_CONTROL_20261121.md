# E1 constrained actor deployment — 21 November 2026

The real-inference elbow controller is installed on Atlas `.191`. Software
qualification covers real Ascend inference on saved E1 telemetry, an independent
FP32 oracle, closed-loop MuJoCo feedback and isolated January DDS transport.
**It has not yet driven the physical E1.** On this date `eno1` is administratively
up but reports `NO-CARRIER`, carrier `0`, and no IPv4 address. The persistent
`E1 robot (eno1)` connection remains configured. Management Ethernet and the
310P3 NPU are healthy. No physical motor or mode writer was started for this work.

The [previous elbow transfer](E1_ELBOW_TRANSFER_20261120.md) used a deterministic
entry/hold/return trajectory. Its successful physical result is not evidence
that model inference controlled the robot. This implementation adds that missing
feedback-to-model-to-command path while retaining the elbows-first scope.

## What executes

```
24 decoded motor records + IMU
  -> calibrated 23-joint observation + previous applied action
  -> ten-frame history + reference goals
  -> frozen LunaKine / Ascend FP32 neural actor at 50 Hz
  -> explicit elbow adapter -> full 24-record command
  -> independent January sender at 500 Hz
```

Every model update records the actual observation, goals, raw actions, previous
and newly applied actions, original input receipt, inference and scheduled times,
reference step and model identity. Heartbeats cannot extend the model input's
age. Artifact SHA-256 checks bind `actor.json`, parameters, robot definition,
Ascend OM and reference. There is no preset or CPU fallback after inference fails.

The frozen artifact remains the 23-joint actor selected on 20 November, with
99 observation features, ten history frames, 730 goals and 29 action channels.
Six inactive action channels stay zero. SDK slot 23 remains a reserved, zero-gain
record and is not treated as a learned physical axis. Ongoing 24-joint training
work is separate and was not included in this deployment.

Only motor 3 (left elbow pitch) and motor 14 (right elbow pitch) can change. All
other 22 **complete records**, including gains, velocity and torque, remain equal
to the initial hold. Position targets being fixed does not guarantee no measured
leg movement under gravity, compliance or load.

## Explicit experimental controller

The actor is constrained, rather than represented as an unchanged whole-body
policy. The profile uses these settings:

| Setting | Value / basis |
| --- | --- |
| Model authority | 25% of raw target displacement from the sampled starting pose |
| Engagement | Two-second minimum-jerk authority ramp |
| Response | 500 ms first-order target filter |
| Maximum speed | Left about 2.197°/s; right about 0.600°/s, derived from the completed 60-second commissioning entry |
| SDK position envelope | Left −82.953° to 0°; right −31.135° to 0°, enclosing the completed commissioning path |
| Reference | Ten-second NN-driven approach at the first goal, then the 13.52-second minimum-motion typing clip |
| Handover | Explicit initial hold, filtered return to the exact captured elbow targets, then disconnect |
| Following error | Existing 5° elbow tolerance in powered operation; not asserted by shadow execution |
| Freshness | Original input and inference at most 40 ms old; scheduling/publication lateness at most 10 ms |

Full-authority simulation exposed persistent slew limiting and, with a longer
approach, position-envelope saturation. Those results did not qualify the raw
whole-body actor. The selected reduced-authority controller completed the
experiment without position clipping. Slew limiting remains active and is
counted in the evidence, rather than hidden or called model output.

The next observation uses the inverse of the filtered, held-joint **applied**
command, not the unconstrained neural output. Shadow applies the same command
calculation without executing it. It retains motor errors, ranges, source age,
leg continuity and the validated isolated-ankle-glitch guard. No thresholds were
relaxed for this deployment. Whole-body sign/zero and IMU calibration remain
diagnostic; this record does not qualify whole-body actuation.

## Evidence and limits

The compact [evidence manifest](evidence/e1-actor-control-20261121.json) identifies
the artifacts and qualification results; raw traces stay outside Git under
`output/e1-actor-elbows-20261121` locally and
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121` on `.191`.

- Native warning-denied checks include the actor owner and simulation owner.
  Actor, mapping, adapter, old shadow and elbow-control tests pass with the real
  frozen bundle; no fixture-dependent actor tests were skipped.
- MuJoCo 3.3.7 closes the sensor loop for 1,542 ticks, including 1,177 policy
  updates. Both raw inference and filtered commands respond to a changed elbow
  observation. Other 22 targets stay fixed and the commanded return is exact.
  Simulated leg displacement still reaches about 2.17°. A root weld approximates
  crane support; supplied inertia/force bounds do not identify physical hardware.
- Actual 310P3 runs use the saved E1 sensor stream, with only clocks rebased.
  They are **recorded-input inference**, not fresh live telemetry. Every proposed
  record is audited independently against the affine model mapping, filter,
  authority, slew, action feedback, clocks and held-joint invariants.
- Eight exact recorded model input histories, including advancing-reference
  phases, are executed independently by ONNX Runtime CPU FP32. The unchanged
  maximum absolute-error threshold is `1e-4`; this is sampled numerical parity,
  not task-quality or bit-exact qualification.
- A loopback-only Linux network namespace replays the real Ascend proposals
  through the actual January DDS sender/receiver. All 22 other targets stay
  fixed, both elbows return exactly, and endpoints close. A separate injected
  stalled model input is rejected even while telemetry/heartbeats remain fresh.
  This establishes transport behavior, not physical motion or fresh inference
  during that transport replay.
- Recorded run 8 stopped before commanding a baseline: an ankle excursion
  arrived without sufficient stationary history during NPU startup. The failed
  archive is retained. Subsequent offline runs used the same saved window and
  unchanged guard. Physical retries must not be inferred from these offline runs.

## Next physical sequence

1. Restore the E1 link to `eno1`; verify carrier, the persistent
   `192.168.55.101` address and receive-only discovery. Rediscover the actual
   status GUID and January reader type identifiers; do not reuse yesterday's GUID.
2. With **no command writer**, run the new owner against fresh E1 status in
   shadow. Audit all 24 records, live timing, original inference-input freshness,
   isolated spikes, fixed other targets and exact return. Historical replay does
   not substitute for this check.
3. Establish current Walk mode, crane support bearing weight, clear area and an
   operator at the paired handheld's emergency disable. These are physical facts
   not supplied by telemetry. Run a fresh one-second current-pose hold using the
   already commissioned owner, disconnect and observe actual factory handback.
4. Record the operator's real observation through `confirm_handback.mbtx`.
   A successful, recent hold/handback receipt is required for `live actor-elbows`.
   Run the constrained controller once; on a fault stop and inspect its archive.
5. Audit the independently captured wire commands and actual tracking, and
   observe handback after disconnect. Only this step can establish physical
   policy execution. Additional arm or leg axes require separate qualification.

The website at `/e1-live.html?gesture=policy` shows the saved Ascend raw targets,
constrained candidates and historical measured input separately. It labels them
as historical and unsent. Its left pane requires fresh live telemetry and stays
empty while disconnected. Website controls only affect visualization.
