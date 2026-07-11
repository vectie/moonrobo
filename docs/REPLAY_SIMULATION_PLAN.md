# Replay And Simulation Plan

MoonRobo should treat replay, dataset playback, and browser-side simulation as
evidence and inspection lanes. They can make robot work easier to inspect and
debug, but they must not become a hidden physical-control path.

The sibling `../lpp` project is a useful reference for this lane. Its best
ideas are a compact public replay protocol, browser-safe NPZ upload, explicit
unit and quaternion conventions, scene overlays for planner state, and a clear
boundary that browser physics is a demo surface rather than a production
controller.

## Current State

MoonRobo already has:

- RoboBook-backed observation sessions and telemetry frames
- replay timeline projection for recorded telemetry frames
- dataset episode contracts
- Rabbita task, readiness, execution, and runtime panels
- URDF/STL viewport driven by MoonBit model projections
- execution snapshots that bind task messages, bridge dispatch, receipts,
  runtime health, and physical feedback

MoonRobo does not yet have:

- a public trajectory artifact format for cockpit playback and dataset review
- browser-safe NPZ upload or conversion rules
- trajectory overlays for planned targets, contact events, command ghosts, or
  verification state
- a clear simulation-sandbox contract separate from physical bridge execution
- policy upload or ONNX/MuJoCo-style browser experimentation surfaces

## Reference Pattern From `../lpp`

Borrow the pattern, not the product boundary.

Useful reference choices:

- replay files use aligned arrays, not opaque logs
- required fields are small and stable
- optional overlays are allowed but ignored when missing
- units are explicit: seconds, metres, metres per second, radians
- quaternions use one declared order, currently `wxyz` in `lpp`
- browser uploads reject private paths, pickle/object payloads, and raw recorder
  metadata
- converters normalize rich recorder output into a public replay artifact
- replay mode works without a policy file
- physics mode requires an explicit uploaded policy and remains a browser demo
- visual overlays show the operator what the planner thought was happening

MoonRobo should translate those ideas into RoboBook evidence terms instead of
copying the ping-pong-specific fields directly.

## Product Boundary

Replay and simulation are allowed to:

- inspect persisted RoboBook evidence
- render live or recorded telemetry against the selected robot model
- compare command intent, planned target, bridge dispatch, runtime feedback, and
  verified outcome
- import browser-safe public replay artifacts into dataset review
- export sanitized dataset episodes for sharing or offline analysis
- run local browser-side sandbox experiments with explicit non-production
  labeling

Replay and simulation must not:

- call raw SDK or bridge control APIs
- bypass MoonRobo safety verdicts, approval, readiness, or runtime validation
- convert a browser policy output into physical actuation
- write RoboBook model or run evidence directly from the browser without a typed
  host route
- leak local filesystem paths, private robot config, or raw capture metadata in
  public replay artifacts

## Target Architecture

```text
RoboBook runs and dataset episodes
  -> typed replay export/import contract
  -> browser-safe trajectory artifact
  -> Rabbita replay and simulation surfaces
  -> viewport overlays and timeline scrubber
  -> review annotations and accepted evidence
  -> MoonBook memory summary
  -> MoonClaw and MoonTown context
```

The physical execution path remains separate:

```text
MoonClaw or operator task
  -> MoonRobo command intent
  -> safety/readiness/runtime gates
  -> supervised bridge sidecar
  -> receipt and physical feedback
```

## Public Replay Artifact

MoonRobo should define a public replay format, for example
`moonrobo.replay.v1`.

Required arrays should be robot-generic:

| Field | Shape | Meaning |
|---|---:|---|
| `t` | `(T,)` | Time in seconds. |
| `joint_name` | `(J,)` | Joint names in the same order as joint arrays. |
| `qj` | `(T, J)` | Joint positions in radians or metres by joint type. |
| `dqj` | `(T, J)` | Joint velocities. |
| `mode` | `(T,)` | Runtime or bridge mode code. |
| `frame_id` | `(T,)` | Stable frame id or numeric frame index. |

Optional arrays should support richer review:

- `base_pos`
- `base_quat`
- `imu_orientation`
- `imu_angular_velocity`
- `imu_linear_acceleration`
- `command_capability`
- `command_intent_id`
- `target_pos`
- `target_quat`
- `planned_contact`
- `actual_contact`
- `limit_state`
- `verification_state`
- `bridge_status`
- `planner_status`
- `annotation_id`

Metadata should be plain JSON and include:

- protocol
- robot id
- bridge id
- RoboBook root or sanitized source label
- source evidence paths when the artifact is private
- recording duration and tick count
- units
- quaternion order
- joint order digest
- model source digest
- exported-at timestamp

Public/shared artifacts should omit local paths and private metadata. Private
RoboBook artifacts may retain evidence paths because they stay inside the
selected MoonSuite book.

## Retargeting Boundary

Retargeting is required when a trajectory, task, policy trace, or planner output
is reused across different robot bodies. It is not required for replaying
source evidence on the same robot model. A replay artifact should first preserve
what happened on the source robot; retargeting should produce a derived artifact
with its own evidence and validation status.

Retargeting is needed because robots may differ in:

- link lengths and body proportions
- joint names and joint order
- joint limits and velocity or torque limits
- base frame conventions
- end-effector frames
- contact surfaces
- actuator response and control rates
- sensor placement and calibration
- available capabilities

MoonRobo should distinguish these artifact classes:

- `recorded`: source telemetry or execution feedback from one robot
- `simulated`: sandbox playback or generated simulation output
- `retargeted`: derived trajectory mapped from a source robot to a target robot
- `physical-feedback-verified`: target robot feedback linked to a real receipt

Retargeting must be explicit and reviewable. It should never rewrite the
original replay, and it should never make the target robot look physically
verified before a real target-robot execution receipt and feedback snapshot
exist.

The retargeting layer should take:

- source replay artifact
- source robot model digest
- target RoboBook profile and model digest
- joint and frame correspondence map
- task-space anchors such as feet, hands, tool center point, base, or camera
- target joint, velocity, and torque limits
- timing policy: preserve timestamps, resample, slow down, or segment
- safety policy for the target robot

The retargeting output should include:

- retarget id
- source replay id
- source and target robot ids
- source and target model digests
- mapping version
- transformed joint or task-space arrays
- clamped or dropped segments
- diagnostics and confidence
- validation summary
- target readiness blockers
- receipt path when a later physical run verifies the result

The first retargeter should be conservative. Prefer task-space intent and
end-effector/base targets over blind joint-angle copying. For example, a walk,
reach, hit, or grasp trace should map through named frames and limits first,
then produce target-specific joint trajectories only after target model
validation passes.

## Converter And Import Rules

MoonRobo should add a converter lane that can normalize internal captures into
the public replay format.

The converter should:

- require the minimal aligned arrays
- fill optional arrays with neutral values or `NaN`
- preserve only plain numeric, boolean, string, and JSON metadata payloads
- reject object arrays, pickle-dependent arrays, and browser-unsafe payloads
- validate all per-frame arrays share the same `T`
- validate joint arrays match the declared joint order
- write a manifest with generated files, protocol, duration, tick count, and
  source label

The import path should produce RoboBook evidence, not mutate execution history.
Imported replay data can become dataset episodes, replay artifacts, annotations,
or review work, but it should not claim that a physical command executed unless
it is linked to an existing receipt and feedback snapshot.

## Cockpit Surfaces

Rabbita should gain a replay lane that builds on the current digital-twin
viewport.

Expected controls:

- upload replay artifact
- load replay from RoboBook run or dataset episode
- timeline scrubber
- play, pause, speed, and reset controls
- selected frame details
- joint-limit overlay
- command intent ghost pose or target marker
- runtime feedback marker
- verification status marker
- annotations panel
- export sanitized replay artifact

Viewport overlays should be domain-specific but generic enough for multiple
robots:

- recent end-effector trail
- planned target
- base target
- velocity arrow
- contact marker
- stale telemetry warning
- unmapped joint warning
- command/feedback mismatch marker

The first implementation should avoid a separate visualizer app. It should
extend the existing Rabbita cockpit viewport and reuse the `model_viewport`
projection.

## Simulation Sandbox

MoonRobo can support a browser-side simulation sandbox later, but it should be
visibly separate from execution.

Allowed sandbox behavior:

- load selected model assets into an isolated browser or runtime simulation
- run replay-only playback without any policy
- optionally upload a policy file for local experimentation
- record sandbox output as simulation evidence
- compare simulated output against recorded evidence

Required warnings and gates:

- sandbox output is never a bridge command
- policy files are user supplied and not trusted
- sandbox results require review before becoming accepted evidence
- physical dispatch still requires the normal MoonRobo command path

The first sandbox can be a proof surface for policy and planner analysis, not a
replacement for runtime validation.

## Host API Boundary

Proposed routes:

```text
GET  /api/moonrobo/replays
GET  /api/moonrobo/replays/{replay_id}
POST /api/moonrobo/replays/import
POST /api/moonrobo/replays/export
POST /api/moonrobo/replays/annotate
POST /api/moonrobo/replays/validate
POST /api/moonrobo/replays/retarget
```

Possible later sandbox routes:

```text
POST /api/moonrobo/simulation/session
GET  /api/moonrobo/simulation/sessions/{session_id}
POST /api/moonrobo/simulation/accept-evidence
```

Every host route should return evidence paths, validation status, and a clear
classification: `recorded`, `imported`, `simulated`, `sandboxed`, or
`retargeted`, or `physical-feedback-verified`.

## Validation Rules

Blocking diagnostics:

- missing required arrays
- mismatched frame counts
- joint array width does not match joint names
- unknown unit declaration
- unsupported quaternion order
- malformed metadata
- private path found in public export
- object or pickle-dependent payload
- replay robot id conflicts with selected RoboBook identity
- replay joint names cannot be reconciled with the selected model
- retarget request missing source or target model digest
- retarget map references unknown source or target joints
- retarget output violates target joint, velocity, or torque limits

Advisory diagnostics:

- missing optional velocity arrays
- missing IMU
- missing command intent linkage
- missing receipt linkage
- no physical feedback snapshot
- model digest differs from selected RoboBook model
- replay contains joints not present in URDF
- URDF contains joints not present in replay
- retargeted segment required clamping
- retarget confidence is low for a named frame or contact surface

## Milestones

### Milestone 1: Protocol Doc And MoonBit DTOs

- add `moonrobo.replay.v1` document
- add MoonBit DTOs for replay metadata, array manifest, validation report, and
  import/export receipt
- test JSON serialization and validation rules

### Milestone 2: RoboBook Replay Export

- export existing observation sessions and telemetry frames into the public
  replay manifest
- bind exported replay artifacts to dataset episodes
- include model and joint-order digests

### Milestone 3: Browser Upload And Validation

- allow Rabbita to upload `.json` replay artifacts
- add `.npz` parsing only after the JSON path is stable
- show validation diagnostics before accepting the replay into RoboBook

### Milestone 4: Timeline And Overlays

- drive the existing URDF/STL viewport from uploaded or persisted replay frames
- add timeline controls
- render target, contact, velocity, limit, and verification overlays

### Milestone 5: Converter Tooling

- add a converter for private recorder archives into `moonrobo.replay.v1`
- write a manifest
- prove browser-safe payloads by loading without object arrays or private paths

### Milestone 6: Simulation Sandbox

- load model and replay artifacts into a non-production sandbox surface
- optionally accept uploaded policy files
- persist sandbox outputs as simulation evidence only
- require review before any sandbox result informs physical work

### Milestone 7: Retargeting Evidence

- add source-to-target joint and frame correspondence maps
- produce retarget receipts from source replay to target replay
- validate target model digest, joint limits, timing, and capability support
- mark retargeted output as unverified until target physical feedback exists

## First Implementation Slice

Start with the narrow replay path:

1. Define `moonrobo.replay.v1` in docs.
2. Add MoonBit validation DTOs in `src/replay`.
3. Export one existing `ReplayTimeline` plus frame paths into a replay manifest.
4. Add tests for missing arrays, mismatched frame counts, unit declarations,
   and robot-id mismatch.
5. Add a Rabbita read-only replay panel that can scrub persisted replay frames
   through the current URDF/STL viewport.

This gives MoonRobo a useful inspection surface without expanding the physical
execution boundary.
