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
against that dry-run evidence.

Allowed evaluation receipts use `ready-for-execution`, not `executed`. The
`executed` status is reserved for the later bridge execution route after a
sidecar has accepted and completed a physical command. This keeps cockpit
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
returns `Execute` with a `ready-for-execution` receipt.

## Reference Direction

The sibling robot-canvas work and local SDK remain references for model loading,
file access, hardware configuration, and bridge behavior. Moonrobo should reuse
that learning while keeping its own product boundary: physical-world agent
operation with RobotBooks, safety gates, receipts, and Moontown-visible robot
residents.

## Next Runtime Steps

1. Start a read-only SDK bridge sidecar that polls the SDK and emits the
   `src/sdk_e1` snapshot contract.
2. Connect `bridges/sdk_e1/sdk_e1_readonly_bridge.py` output directly to the
   typed bridge protocol.
3. Package the desktop host sidecar and Rabbita build in a Lepus desktop
   prototype.
4. Add live bridge lifecycle supervision to the desktop host manifest.
