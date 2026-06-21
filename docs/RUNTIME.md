# Moonrobo Runtime Slice

This slice turns the planning documents into a native MoonBit runtime path that
Rabbita and Lepus can build on.

## Current Runtime Boundary

The current runtime is intentionally small:

- load a RobotBook from disk
- decode `robot.json` into the MoonBit `RobotProfile` contract
- inspect required RobotBook paths
- produce deterministic mock telemetry
- pass a command intent through the safety pipeline
- start and stop read-only observation sessions with RobotBook evidence
- ingest typed telemetry frames into active observation sessions
- summarize persisted observation telemetry as replay timelines
- project the selected robot as a Moontown resident agent
- accept a Moontown observation task and route it through the same evidence flow

It does not start hardware sidecars or issue motion commands yet. The purpose is
to establish the file, contract, validation, and pipeline shape that the
operator interface can trust.

## Native CLI

The native CLI is the first stable integration seam:

```text
moon run cmd/main --target native -- inspect [robotbook-root]
moon run cmd/main --target native -- mock [robotbook-root]
moon run cmd/main --target native -- cockpit [robotbook-root]
moon run cmd/main --target native -- cockpit-sdk-file [robotbook-root] [snapshot-json]
moon run cmd/main --target native -- resident [robotbook-root]
moon run cmd/main --target native -- observe-task [robotbook-root] [task-id]
moon run cmd/main --target native -- replay [robotbook-root] [session-id]
moon run cmd/main --target native -- ingest-sdk-frame [robotbook-root] [session-id] [frame-id]
moon run cmd/main --target native -- api-snapshot [robotbook-root]
moon run cmd/main --target native -- api-health [robotbook-root]
moon run cmd/main --target native -- api-route [robotbook-root] [method] [path] [body-json]
moon run cmd/main --target native -- serve [robotbook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- host-manifest [robotbook-root] [ui-root] [host] [port]
moon run cmd/main --target native -- desktop-project [robotbook-root] [ui-root] [host] [port] [sidecar-path]
moon run cmd/main --target native -- plan-walk [robotbook-root]
moon run cmd/main --target native -- bridge-health [robotbook-root]
moon run cmd/main --target native -- bridge-telemetry [robotbook-root]
moon run cmd/main --target native -- sdk-health [robotbook-root]
moon run cmd/main --target native -- sdk-telemetry [robotbook-root]
moon run cmd/main --target native -- sdk-telemetry-file [robotbook-root] [snapshot-json]
moon run cmd/main --target native -- receipts [robotbook-root]
moon run cmd/main --target native -- receipt [robotbook-root] [receipt-id]
moon run cmd/sdk_e1_bridge --target native -- route [robotbook-root] [method] [path] [body-json]
moon run cmd/sdk_e1_bridge --target native -- serve [robotbook-root] [host] [port]
```

Default root:

```text
examples/noetix-e1
```

Command meanings:

- `inspect`: load and validate the RobotBook, then summarize identity,
  readiness, joints, capabilities, missing files, and validation issues.
- `mock`: load the RobotBook and emit one deterministic telemetry summary from
  the mock bridge.
- `cockpit`: emit the first-screen cockpit projection using mock bridge data.
- `cockpit-sdk-file`: emit the same projection from SDK sidecar snapshot JSON.
- `resident`: emit the Moontown-facing resident robot agent projection.
- `observe-task`: submit a Moontown-style standing-goal observation task.
- `replay`: emit the replay timeline for one observation session.
- `ingest-sdk-frame`: convert a deterministic SDK-shaped snapshot into a
  `TelemetryFrame` and append it to an active observation session.
- `api-snapshot`: emit the local host API body for `/api/cockpit/snapshot`.
- `api-health`: emit the local host API body for `/api/health`.
- `api-route`: probe the local host API router contract without starting a
  server, including POST body JSON for command-intent evaluation.
- `serve`: start the native localhost desktop host that serves the Rabbita UI,
  readiness JSON, and robot API routes together.
- `host-manifest`: emit the desktop host service manifest and route catalog.
- `desktop-project`: emit the Lepus project JSON that points a native window at
  the localhost host and sidecar command.
- `plan-walk`: create a high-level walk intent, evaluate it through the safety
  pipeline, and write the resulting receipt JSON under `runs/receipts/`. It
  should currently stop at dry-run collection.
- `bridge-health`: emit a typed bridge health response as JSON.
- `bridge-telemetry`: emit a typed latest-telemetry response as JSON.
- `sdk-health`: emit a bridge health response from an SDK-shaped snapshot.
- `sdk-telemetry`: emit a latest-telemetry response from an SDK-shaped snapshot.
- `sdk-telemetry-file`: convert sidecar snapshot JSON into a bridge telemetry
  response.
- `receipts`: list decoded RobotBook run receipts.
- `receipt`: print one decoded RobotBook run receipt as JSON.
- `cmd/sdk_e1_bridge route`: probe the SDK E1 bridge sidecar protocol routes
  without starting a server.
- `cmd/sdk_e1_bridge serve`: start the local SDK E1 bridge scaffold on
  `127.0.0.1:5391` by default.

## Rabbita/Lepus Path

The Rabbita cockpit should call into the same runtime contracts instead of
recreating robot parsing or safety checks in UI code.

Near-term screens should map directly to the CLI path:

- RobotBook picker and readiness summary from `inspect`
- mock bridge health and telemetry from `mock`
- proposed-command review from `plan-walk`
- first-screen cockpit projection from `cockpit` or `cockpit-sdk-file`

The Lepus desktop shell should package the native runtime and supervise later
sidecars. Scoped filesystem access belongs in Lepus; robot contract logic stays
in MoonBit packages.

The first Rabbita shell is in `ui/rabbita-cockpit`. It imports the
`src/cockpit` projection structs, renders a sample immediately, then loads the
same first-screen state from `/api/cockpit/snapshot` through Rabbita's HTTP
command path. The route contract lives in `src/host_api`; `src/desktop_host`
serves that route beside static Rabbita assets and emits the Lepus project JSON.
`POST /api/intents/evaluate` submits a command intent through the safety
pipeline and persists a RobotBook receipt, but it does not call hardware
execution. `POST /api/intents/dry-run` records dry-run evidence for a command
that needs simulation. `POST /api/intents/approve` records operator approval
against that dry-run evidence. `POST /api/intents/execute` consumes the same
evidence, re-runs the safety gate, dispatches the bridge execution boundary, and
persists an `executed` receipt.
`POST /api/sessions/observe` starts a read-only observation session through the
same safety gate and bridge protocol. `POST /api/sessions/{id}/frames` accepts
one typed `TelemetryFrame`, writes it under
`runs/telemetry/{session_id}/{frame_id}.json`, and updates the active session's
frame count, latest frame, and artifact list. `POST /api/sessions/{id}/stop`
marks that session stopped with a final telemetry frame count. Start and stop
routes write a run receipt and a `runs/observations/{session_id}.json` record.
`GET /api/moontown/resident` returns the same robot as a town resident agent:
identity, role, availability, bridge state, active observation, latest receipt,
capability count, and review count.
`POST /api/moontown/tasks/observe` accepts a standing-goal observation task,
plans it into a read-only observation session, persists the same RobotBook
evidence, and returns the updated resident projection.
Observation starts also write the first telemetry frame under
`runs/telemetry/{session_id}/{frame_id}.json`; receipts and resident
observation summaries link to that artifact for replay and review.
`GET /api/replays/{session_id}` returns a compact replay timeline over the
persisted session and sorted telemetry frame artifacts. The timeline includes
session lifecycle fields and per-frame artifact paths, timestamps, mode, joint
count, and error count, giving Rabbita and Moontown a stable read-only surface
without requiring them to parse RobotBook files directly.

Allowed evaluation receipts use `ready-for-execution`, not `executed`. The
`executed` status is reserved for the bridge execution route after the bridge
boundary has accepted and completed a command. This keeps cockpit
review, dry-run evidence, approval evidence, and live actuation auditable as
separate steps.

Example body:

```json
{
  "intent_id": "intent-cockpit-walk",
  "robot_id": "",
  "capability": "control.high.walk",
  "parameters": {
    "x": "0.10",
    "yaw": "0.00",
    "duration_ms": "1000"
  },
  "requester": {
    "kind": "operator",
    "id": "cockpit"
  },
  "receipt_id": "receipt-cockpit-walk",
  "now_ms": "1000",
  "approval_id": "",
  "dry_run_receipt_id": "",
  "developer_gate": false,
  "telemetry_age_ms": 10
}
```

An empty `robot_id` means “use the selected RobotBook profile”. Empty approval
and dry-run receipt IDs are treated as missing evidence, so high-control intents
first return `CollectDryRun` and persist a `WaitingForDryRun` receipt. After a
dry-run and approval are recorded, resubmitting the same intent with both IDs
returns `Execute` with a `ready-for-execution` receipt. Submitting that same
payload to `/api/intents/execute` records the bridge completion receipt as
`executed`.

## Reference Direction

The sibling robot-canvas work and local SDK remain references for model loading,
file access, hardware configuration, and bridge behavior. Moonrobo should reuse
that learning while keeping its own product boundary: physical-world agent
operation with RobotBooks, safety gates, receipts, and Moontown-visible robot
residents.

## Next Runtime Steps

1. Replace the SDK E1 bridge scaffold snapshot source with live SDK polling
   while preserving the `src/sdk_e1` snapshot contract behind
   `cmd/sdk_e1_bridge`.
2. Replace the deterministic `ingest-sdk-frame` smoke path with live sidecar
   polling that posts `TelemetryFrame` JSON into `POST /api/sessions/{id}/frames`.
3. Replace the local deterministic bridge completion with the SDK-backed bridge
   sidecar once the sidecar process lifecycle and safety interlocks are
   supervised.
4. Package the desktop host, bridge sidecar, and Rabbita build in a Lepus desktop
   prototype.
5. Add live bridge lifecycle supervision to the desktop host manifest.
