# SuperMimic to Noetix E1: target-specific adaptation

Status (2026-11-10): native offline E1 training, warm resume, actor export and
full-clip evaluation run on DGX Spark. No physical qualification.

The [November 11 arm retargeting audit](E1_RETARGETING.md) follows the
completed 7k and 14k evaluations with calibrated G1-to-E1 references,
per-frame collisions and matched policy replays.

**Current implementation:** [native E1 training](../src/learning_e1_training/README.md)
uses 178 for data and 179 for model execution. It supports a 23-axis simulation
profile derived by fixing waist roll in the vendor 24-axis model, plus an explicit
24-axis profile. It reuses the native learner through a declared 29-axis internal
embedding, with inactive actions/state/observation channels masked. The older
compact 24-axis SDK observation contract described below remains a separate API.
Initial data uses four vendor E1 clips, with separate training/validation files.
This is not a full BONES E1 transfer or a convergence result. G1 CSV retargeting
currently emits independently audited kinematic candidates.

The current official E1 SDK guide explicitly describes external-board development
over the back Ethernet port with the original development board's fixed IP.
An original onboard development board is therefore not a prerequisite for this
offline software or, per that documented route, the only compute-host option.
Actual firmware/network/stop behavior still requires hardware validation.

**Revision note — 2026-10-29:** the source-level SDK findings below describe the
older SDK used by this integration. The current sibling `../sdk` is SDK 3.1.0,
with a different namespace, callback/status API and prebuilt-library layout;
`DEFAULT` is 14 and 12 is `DANCE`. MoonRobo's existing adapter/build still targets
the older interface. The old 21-of-24 read finding is not verified against the
current vendor binary. The sibling `../lab` also supplies E1 URDF/MJCF assets,
which still need reconciliation with the example model and physical hardware.
See the [dated SDK and model audit](engineering/RESOURCE_AUDIT.md#e1-sdk-mismatch-a-concrete-integration-blocker)
before using this historical implementation description for new integration work.

The 29-DoF G1 checkpoint and its 40 LAFAN1 retargeted clips cannot be loaded as a
24-DoF E1 controller. The learning algorithm can be reused after creating an E1
articulation and motion catalog; the G1 action weights, default pose, actuators,
kinematics and reward body list cannot.

## Historical integration interfaces

`examples/noetix-e1/robot.json` and the preserved E1 SDK both expose 24 motor
indices: five arm, six leg per side and two waist. The MoonBit native E1 bridge
reads motor position/velocity/torque, an IMU quaternion/angular velocity/linear
acceleration, and joystick state. It writes only the SDK high-control WALK,
RUN and DEFAULT commands. The `control.low.joint-position` capability is
disabled. The high-control command outbox cannot carry the 24 target positions
from a SuperMimic actor.

The SDK contains a separate `LowController::set_joint` interface with 24
position/velocity/torque/stiffness/damping commands. That source is not a
qualified policy runner. In the older source-based SDK audited for this integration, `get_joint_state()`
copies only motor slots 0–20 into a 24-element result; slots 21–23 are not
copied. `send_thread_func()` republishes the most recently buffered command
every 2 ms without a local command-age timeout or explicit buffer clearing.
These source-level findings must be resolved and checked on the target SDK
revision before a low-control bridge is considered. A disabled, repository-owned
[source candidate](../src/sdk_e1_native/lowcontrol_candidate/README.md) now
copies all 24 states, rejects malformed/stale status and stops republishing
stale setpoints; it does not establish motor stop semantics or enable actuation.
Neither low-control interface is called by the new adaptation code.

The repository E1 URDF is an example model: its `base.obj` explicitly says
"placeholder"; there is no accompanying E1 MJCF/USD, actuator identification,
contact calibration, or verified inertial model. Its kinematics and limits are
not evidence for physics-equivalent training. The IMU quaternion order/frame
and the location of the IMU relative to the policy root are likewise not
established by the snapshot schema. The SDK read path also does not provide
root XY position, world heading, root linear velocity or contact states.

## Implemented non-actuating boundary

`src/learning_e1` defines the canonical 24-motor order and accepts an E1
snapshot only if motor IDs, joint count, finite state, reported motor faults and
total timestamp age pass validation. Its observation builder reproduces the
paper-style structure for **24**, not 29, joints:

| Input variant | Layout | Width |
| --- | --- | ---: |
| E1 paper-style | `q - q_default - delta_q_ref`, `qd`, body gyro, body gravity, previous action | 78 |
| E1 SMC-style extension | preceding plus relative reference orientation in 6D | 84 |
| E1 observable extension | preceding plus body-frame reference-root displacement | 87 |

The caller must supply *calibrated* body-frame angular velocity and gravity;
this code does not assume the SDK IMU quaternion or gyro frame. The 6D/3D
extensions require a separate reference alignment and root pose estimate.
Without them, E1 has the same unobservable XY/yaw reward issue identified for
the G1 paper-style proprioceptive observation. The action helper computes
`q_target = q_default_E1 + scale_E1 * actor_action + calibration_E1` after
24-element and finite checks. It does not copy the G1 per-joint scale or write
to a robot. A 10-frame history, 10-frame reference preview, normalized inputs
and 50 Hz control are training/runtime requirements, not yet an E1 runner.

## Work required before comparing an E1 policy

1. Obtain a manufacturer-confirmed E1 model including link inertias, collision
   geometry, foot contacts, firmware revision and motor/encoder signs. Measure
   stiffness, damping, torque/velocity limits, latency, default pose, safe joint
   ranges and the actual servo command convention. Bind all of it to versioned
   hashes and machine-readable calibration records.
2. Retarget the selected source motions to this 24-DoF body with foot-contact,
   support, joint-limit and self-collision checks. Preserve source/provenance,
   frame rate, train/held-out split and each transformed clip's checksum. The
   G1 LAFAN1 CSVs are not E1 references by renaming columns. If BONES-SEED
   access is obtained, use the same source split and filtering for G1 and E1,
   then perform distinct robot-specific retargets. Add E1-recorded safe
   motions as a separate domain-adaptation set, never silently merge them
   into the held-out test split.
3. Parameterize the aligned model-based trainer for 24 joints, the verified E1
   kinematics and tracked bodies, E1 action scales, control/physics periods and
   sensor noise. Keep the paper's 8-step model fit, 32-step imagination,
   relative-reference termination, soft survival, imagined GAE critic and
   adaptive time-bin reset. Retrain the actor/critic/world model for E1.
4. Run full-clip simulation evaluation with normalized return and termination
   count, plus a separate unseen-motion split and disturbances. Only then
   export an E1-specific checkpoint with exact robot, dataset, actuator,
   estimator and observation-schema identities.
5. Build a robot-local inference process and low-control interface with exclusive
   ownership, bounded setpoints/gains, deadline and stale-state handling,
   watchdog/stop/takeover semantics. Verify complete 24-motor reads and command-age
   behavior against the selected SDK revision; the historical 21-of-24 bug and
   repeated-command findings do not characterize the current prebuilt SDK.
   Exercise recorded telemetry, simulation and
   device stubs before any physical-motion decision.

No claim of E1 deployability follows from G1 training, the 24-channel snapshot,
or the non-actuating contract alone.
