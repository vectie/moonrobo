# RobotBook Contract

A RobotBook is the durable home for a robot body, robot family, simulator, or
hardware bridge. Moonrobo reads and writes RobotBooks, but MoonBook remains the
durable owner.

RobotBooks make physical-world work inspectable:

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
robotbook/
  book.json
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

Not every RobotBook needs every file on day one. The minimum viable RobotBook
is:

```text
robot.json
safety/policy.json
bridge/bridge.json
runs/receipts/
```

## `robot.json`

`robot.json` is the stable identity and embodiment contract.

Draft shape:

```json
{
  "id": "noetix-e1-lab-01",
  "label": "Noetix E1 Lab 01",
  "kind": "humanoid",
  "platform": "noetix-e1",
  "profileVersion": 1,
  "model": {
    "primary": "model/robot.urdf",
    "alternates": ["model/robot.mjcf", "model/robot.usd"]
  },
  "bridge": {
    "id": "sdk-e1",
    "config": "bridge/bridge.json"
  },
  "joints": [],
  "sensors": [],
  "capabilities": [],
  "limits": {
    "requiresFreshTelemetryMs": 250,
    "requiresHeartbeatMs": 100,
    "defaultMode": "read-only"
  }
}
```

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

Receipts are not logs only. They are reviewable durable evidence.

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
- `POST /api/sessions/{session_id}/frames`: local host ingestion route that
  persists a typed telemetry frame and updates the active session ledger.
- `POST /api/moontown/tasks/observe-run`: bounded observation pipeline that
  writes session, telemetry, stop receipt, replay, review, and resident
  evidence.
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
builds them from `runs/observations/` and `runs/telemetry/` so RobotBook remains
the durable ledger and UI surfaces can stay read-only.
Process reviews are RobotBook evidence, not chat summaries. They are generated
from replay and receipt state so the review queue can be rebuilt or audited
without direct bridge access.

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
