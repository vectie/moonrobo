# RoboBook Contract

A RoboBook is the robot-domain decorator on a MoonBook. MoonBook owns the
durable book/workspace: pages, attachments, evidence ledgers, datasets, review
queues, and memory packs. RoboBook adds the robot-specific contract for a robot
body, robot family, simulator, or hardware bridge.

Moonrobo reads and writes the RoboBook decorator through MoonBook paths. The
important boundary is simple: MoonBook is the durable substrate; RoboBook is the
robot view, schema, and evidence projection.

RoboBook should stay small. It is not a second durable knowledge system and it
should not fork conversation or memory away from MoonBook. It is the physical
wrapper around a MoonBook workspace:

```text
MoonBook = durable memory, conversation, task messages, accepted summaries
RoboBook = MoonBook + robot identity, bridge, safety, runtime, and evidence
```

If data is conversation, recall, summary, or durable agent memory, it belongs in
MoonBook. If data is robot identity, bridge configuration, safety policy,
runtime health, calibration, telemetry, receipt, dispatch, or task-execution
proof, it belongs in the RoboBook decorator and should be summarized back into
MoonBook when it changes the robot agenda.

RoboBooks make physical-world work inspectable:

- what the robot is
- what it can do
- what limits it has
- what bridge controls it
- what commands were proposed
- what safety verdicts were returned
- what actually happened
- what evidence was accepted

## Directory Layout

```text
moonbook-workspace/
  moonbook/
    book.json
    pages/
    attachments/
    memory/
  robot.json
  model/
    robot.urdf
    robot.mjcf
    robot.usd
    meshes/
    calibration/
  safety/
    policy.json
    zones.json
    approvals.jsonl
    emergency.md
  bridge/
    bridge.json
    health.json
    capabilities.json
  runs/
    receipts/
    runtime-health/
    runtime-validation/
    runtime-calibration/
    task-executions/
    observations/
    telemetry/
    replays/
    failures/
  datasets/
    episodes/
    annotations/
    exports/
  wiki/
    index.md
    operating-notes.md
    maintenance.md
    reviews/
  skills/
    inspect/
    simulate/
    diagnose/
    summarize-run/
  schemas/
```

Not every RoboBook needs every file on day one. The minimum viable RoboBook
decorator inside a MoonBook workspace is:

```text
robot.json
safety/policy.json
bridge/bridge.json
runs/receipts/
moonbook/memory/
```

## `robot.json`

`robot.json` is the stable identity and embodiment contract.

Draft shape:

```json
{
  "id": "noetix-e1-lab-01",
  "label": "Noetix E1 Lab 01",
  "kind": "Humanoid",
  "platform": "noetix-e1",
  "profile_version": 1,
  "model": {
    "primary": "model/robot.urdf",
    "alternates": ["model/robot.mjcf", "model/robot.usd"]
  },
  "bridge": {
    "id": "sdk-e1",
    "kind": "SdkE1",
    "config_path": "bridge/bridge.json"
  },
  "joints": [],
  "sensors": [],
  "capabilities": [],
  "limits": {
    "telemetry_freshness_ms": 250,
    "heartbeat_ms": 100,
    "default_mode": "read-only",
    "high_control_max_x_abs": 0.25,
    "high_control_max_yaw_abs": 0.5,
    "high_control_max_duration_ms": 1500
  }
}
```

The high-control limit fields are enforced by the safety gate before a
walk/run command can collect dry-run approval or reach a physical bridge. The
SDK bridge also re-runs the same gate before writing the high-control command
outbox.

## Model Artifacts

The `model.primary` field points to the canonical robot embodiment artifact for
inspection, calibration, simulation, and replay. The preferred first artifact is
`model/robot.urdf`, with optional alternates such as MJCF or USD when a
simulator or renderer needs them.

Current support is the first viewport implementation: Moonrobo records the URDF
path in `robot.json`, requires the declared model artifact for RoboBook
readiness, parses URDF links, joints, parent/child edges, joint origins, axes,
and limits, surfaces the resolved model path in the Rabbita cockpit, and
projects the parsed model plus live or replayed telemetry into a schematic URDF
viewport. The viewport now exposes both joint pose rows and a link-pose
simulation graph: root link, parent joint, depth, accumulated URDF origin
position, and transform annotation for each link. It normalizes each mapped
joint position against URDF limits and reports below-limit or above-limit poses
as model diagnostics. A mesh
resolver, 3D mesh renderer, and physics simulator are not part of the current
runtime yet.

The place to visualize the current URDF simulation is the Rabbita cockpit's
digital-twin viewport. Today that viewport is intentionally schematic: it shows
the resolved URDF, link and joint counts, RoboBook-to-URDF mapping coverage,
parent/child joint edges, accumulated link poses, telemetry-bound joint poses,
normalized pose position, and limit diagnostics. It is enough for one-to-one
model inspection, calibration checks, replay review, and "is this telemetry
plausible for this body?" debugging before Moonrobo graduates to full mesh
rendering or physics.

The cockpit drawing is generated from the same link-pose projection exposed to
agents: each simulated link becomes a front-view node, and each URDF parent
relationship becomes an edge. The UI therefore remains a view over RoboBook and
URDF evidence, not a separate hand-drawn robot model.

The intended viewer path is:

- load `robot.json` from the RoboBook decorator
- resolve `model.primary` relative to the RoboBook root
- parse links, joints, joint origins, joint limits, and mesh references from
  URDF
- render the body, link-pose graph, and joint tree in the Rabbita cockpit
- bind live or replayed telemetry frames to joint transforms
- persist model warnings, missing mesh references, and calibration mismatches
  back into RoboBook evidence

Simulation should remain safety-gated evidence. A simulated run should produce
a receipt or dry-run artifact before any physical bridge receives the matching
control intent.

## Capabilities

Capabilities are the only way an agent or operator can request action. A bridge
may support many vendor functions, but Moonrobo exposes only named
capabilities.

Examples:

- `observe.telemetry`
- `observe.joints`
- `observe.imu`
- `simulate.motion`
- `control.hold`
- `control.high.walk`
- `control.high.run`
- `control.high.teach.start`
- `control.high.teach.play`
- `control.low.joint-position`

Low-control capabilities should default to disabled and require explicit
developer policy.

## Safety Policy

`safety/policy.json` should answer:

- which capabilities are allowed
- which capabilities require human approval
- which require dry-run or simulation first
- which are disabled
- what telemetry freshness is required
- what bridge heartbeat is required
- whether low-control APIs are blocked
- what to do on stale telemetry, bridge errors, or operator disconnect

Draft shape:

```json
{
  "policyVersion": 1,
  "defaultDecision": "deny",
  "telemetryFreshnessMs": 250,
  "heartbeatMs": 100,
  "capabilities": {
    "observe.telemetry": { "decision": "allow" },
    "control.high.walk": {
      "decision": "approval-required",
      "requiresDryRun": true
    },
    "control.low.joint-position": {
      "decision": "deny",
      "reason": "low-control disabled by default"
    }
  }
}
```

## Run Receipts

Every command attempt must produce a receipt, including denied attempts.

Receipt fields:

- receipt id
- robot id
- command intent
- requester
- source surface
- bridge id
- safety verdict
- approval record
- run status (`ready-for-execution`, waiting states, denied, executed, failed)
- started and ended timestamps
- telemetry summary
- artifact paths
- original bridge error if any

Receipts are not logs only. They are reviewable durable evidence in MoonBook
with a RoboBook projection for robot inspection.

## Process Evidence

High-control commands create additional evidence beside receipts:

- `runs/dry-runs/{id}.json`: dry-run evidence linked to the waiting receipt.
- `runs/approvals/{id}.json`: operator approval linked to the dry-run evidence.
- `runs/observations/{session_id}.json`: read-only observation session state
  with start/stop timestamps, requester, telemetry frame count, latest frame,
  and linked receipt.
- `runs/telemetry/{session_id}/{frame_id}.json`: captured telemetry frame
  artifacts linked from the observation session and receipt.
- `runs/reviews/{review_id}.json`: deterministic process review and diagnosis
  records linked to receipts, observations, telemetry, and replay evidence.
- `runs/runtime-health/{health_id}.json`: active runtime and bridge telemetry
  health evidence. `runs/runtime-health/latest.json` is the latest poll result
  used by MoonBook memory and Moontown resident planning.
- `runs/runtime-validation/{report_id}.json`: live SDK readiness report
  joining supervisor-plan, process, collector snapshot, command outbox,
  control-gated bridge wiring, telemetry identity, and runtime-log evidence.
  `runs/runtime-validation/latest.json` is the latest operator-facing readiness
  gate for the selected RoboBook and bridge.
- `runs/bridge-contracts/{contract_id}.json`: persisted live bridge authority
  contract sampled from `GET /contract`.
  `runs/bridge-contracts/latest.json` is the latest contract used by runtime
  validation and platform readiness to prove the bridge identity and enabled
  hardware-motion routes.
- `runs/runtime-validation/sessions/{session_id}.json`: repeated readiness
  samples aggregated into one live-SDK validation session.
  `runs/runtime-validation/latest-session.json` is the latest stability proof
  before calibration or physical task execution.
- `runs/runtime-calibration/{plan_id}.json`: actionable calibration plan
  derived from blocked validation reports or validation sessions, grouped by
  failing readiness check.
  `runs/runtime-calibration/latest.json` is the latest operator worklist for
  making the selected RoboBook and bridge ready. The host API projects this file
  into `/api/agent/work-queue` as `calibrate-runtime` whenever blockers remain,
  and exposes the latest plan at `/api/agent/runtime-calibration/latest`.
- `runs/runtime-supervisor/{launch_id}.log`: stdout and stderr from the active
  physical runtime supervisor and its collector, writer, and bridge child
  processes.
- `runs/task-executions/{snapshot_id}.json`: compact task execution snapshots
  linking the MoonBook task message, receipt, bridge dispatch, MoonBook memory,
  runtime-health evidence, and supervisor log for one user-visible task.
- `moonbook/memory/{pack_id}.json`: MoonBook memory packs distilled from
  resident state, latest observation/review evidence, runtime health, and next
  queued work.
- `POST /api/sessions/{session_id}/frames`: local host ingestion route that
  persists a typed telemetry frame and updates the active session ledger.
- `POST /api/moontown/tasks/observe-run`: bounded observation pipeline that
  writes session, telemetry, stop receipt, replay, review, and resident
  evidence.
- `POST /api/moontown/tasks/message`: user-message ingress that maps
  observation text to read-only task evidence and maps command or maintenance
  text to durable review-classified task-message plans under
  `moonbook/task-messages/`.
- `GET /api/moonbook/task-messages`: local host task-board projection over
  persisted task-message plans, including lifecycle stage, next route, and gate
  flags for operator review and work-queue prioritization.
- `GET /api/moonbook/conversation`: local host conversation projection over
  the same persisted task-message plans, including user text, Robo reply,
  lifecycle stage, next route, and gate flags for Rabbita or Moontown message
  surfaces.
- `GET /api/replays/{session_id}`: local host projection over the persisted
  observation and telemetry artifacts.
- `GET /api/reviews`: local host projection over persisted process review
  records and human-review counts.

The safety pipeline consumes these IDs on the next evaluation. A command becomes
`ready-for-execution` only after the dry-run and approval IDs match the same
intent identity. The execution route consumes the same evidence and writes a
separate `executed` receipt after bridge completion is accepted.

Observation sessions use the same safety gate and receipt ledger, but they are
read-only. Starting and stopping a session writes an `executed` receipt for the
accepted bridge operation while the session file records the current session
state for cockpit and Moontown projections. The first observation frame is
persisted as a telemetry artifact so resident and review surfaces can link to
concrete replay evidence instead of only counters.
Active sessions can ingest additional `TelemetryFrame` records through the host
API. The route rejects stopped sessions, robot mismatches, bridge mismatches,
and duplicate frame artifacts before updating the session ledger.
The bounded observation run route composes task planning, session start, frame
ingest, session stop, replay projection, deterministic diagnosis, and resident
projection. It is the first process-level contract for Moontown scheduling and
later bridge polling.
Replay timelines are projections, not a separate source of truth. The host API
builds them from `runs/observations/` and `runs/telemetry/` so MoonBook remains
the durable ledger and RoboBook remains the robot-domain view.
Process reviews are RoboBook evidence, not chat summaries. They are generated
from replay and receipt state so the review queue can be rebuilt or audited
without direct bridge access.
MoonBook memory packs are not raw logs. They are compact recall records that
answer what the robot last observed, what review or evidence matters, and what
the next safe work item is. Rebuilding a memory pack from RoboBook evidence is
possible, but persisting it in MoonBook is the required path for MoonClaw,
Moontown, and tool agents to resume without forgetting the current robot agenda.
The MoonClaw robot routine must therefore treat RoboBook evidence as the raw
physical ledger and MoonBook memory as the durable context for the next action.

## Dataset Episodes

Dataset exports should be derived from accepted runs, not from arbitrary bridge
logs. Each episode needs:

- robot profile version
- safety policy version
- model/calibration version
- command intent
- observations
- actions
- rewards or labels if available
- operator annotations
- exclusion reason if rejected

This keeps robot learning work tied to the same evidence model as robot
operation.
