# Bridge Protocol

Robot bridges are sidecars that translate Moonrobo contracts into simulator,
SDK, or ROS-style hardware calls.

Moonrobo should not link vendor control logic directly into UI code or generic
agent tools. A bridge sidecar owns vendor-specific dependencies, process
lifecycle, and hardware transport.

## Bridge Types

Initial bridge types:

- `sim`: local simulator or replay fixture
- `sdk-e1`: Noetix E1 SDK sidecar using `../sdk`
- `ros2`: future ROS 2 adapter
- `mock`: deterministic test bridge

## Required Capabilities

Every bridge should support:

- health
- metadata
- capabilities
- observe telemetry
- start observation session
- stop observation session
- dry-run command intent
- execute command intent if enabled
- emergency stop or hold if supported

The `sdk-e1` bridge supports read-only observation and a separate
`control-gated` mode for allowlisted high-control commands. Motion remains
unavailable unless Moonrobo readiness, safety, approval, dispatch evidence, and
bridge receipts agree.

## Local HTTP Shape

Draft routes:

```text
GET  /contract
GET  /health
GET  /metadata
GET  /capabilities
GET  /telemetry/latest
POST /sessions/observe
POST /sessions/{id}/stop
POST /intents/dry-run
POST /intents/execute
POST /emergency/stop
```

`GET /contract` is the machine-readable bridge boundary. It returns the
protocol version, bridge and robot identity, read-only mode, and every supported
operation with method, path, mutability, intent/session requirements, hardware
motion risk, and whether that operation is enabled for the current sidecar mode.
MoonClaw, Moontown, Rabbita, and desktop runtime code should use this manifest
as the authority surface before deciding what a bridge may be asked to do.

All mutating routes return a receipt fragment. Moonrobo turns that into a full
RoboBook receipt.

The first local desktop API exposes this through six routes:

- `POST /api/intents/evaluate`: run the safety pipeline and write a receipt.
- `POST /api/intents/dry-run`: write dry-run evidence for a command that needs
  simulation.
- `POST /api/intents/approve`: write operator approval against dry-run
  evidence.
- `POST /api/intents/execute`: validate the same evidence, build a bridge
  `ExecuteIntent`, write the bridge completion receipt, and persist the bridge
  dispatch evidence.
- `POST /api/sessions/observe`: start a read-only observation session and write
  a RoboBook observation record.
- `POST /api/sessions/{id}/stop`: stop that observation session and persist the
  final telemetry summary.

The local execution route uses the bridge protocol boundary and deterministic
completion while the SDK sidecar is not yet supervised. It also writes
`runs/bridge-dispatches/{dispatch_id}.json`, which records the request id,
bridge route, operation, intent id, response status, and produced receipt. The
route shape is the same boundary a physical bridge sidecar must implement.

When evaluation returns `allow`, the persisted receipt status is
`ready-for-execution`. The `executed` status belongs to the execution route
that dispatches an already-approved command through the bridge boundary and
records its completion response.
The task-message execution route uses the same dispatch evidence contract, so a
message-derived command is auditable from MoonBook task plan to dry-run,
approval, bridge dispatch, and executed receipt.

The MoonBit protocol package mirrors this shape as typed request and response
envelopes. Sidecars can expose HTTP, stdio, or local process transports, but
they should preserve the same operation names, request IDs, bridge IDs, robot
IDs, and response payload fields.

`src/bridge_sidecar` describes the concrete bridge process contract for a
RoboBook profile: command, environment, protocol version, contract route, health
route, telemetry route, execution route, supervision policy, and launchability
status. It also describes the first physical runtime process graph: SDK snapshot
collector, SDK high-control writer, and bridge sidecar, sharing one
`SdkE1Snapshot` JSON file for telemetry and one high-control command JSON file
for accepted motion envelopes. The host exposes it at `/api/bridge/sidecar`, and
`moon run cmd/main -- bridge-sidecar` prints the same manifest for scripts and
agents.
`/api/runtime/supervisor` and
`moon run cmd/main -- runtime-supervisor` convert that graph into the current
launch, wait, health-probe, and stop plan.
`/api/runtime/supervisor/script` and
`moon run cmd/main -- runtime-supervisor-script` emit the executable POSIX
runner for that plan.

Native protocol smoke commands:

```text
moon run cmd/main --target native -- bridge-health [robobook-root]
moon run cmd/main --target native -- bridge-sidecar [robobook-root]
moon run cmd/main --target native -- bridge-telemetry [robobook-root]
moon run cmd/main --target native -- sdk-health [robobook-root]
moon run cmd/main --target native -- sdk-telemetry [robobook-root]
moon run cmd/main --target native -- sdk-telemetry-file [robobook-root] [snapshot-json]
```

These commands currently use the deterministic mock bridge and print protocol
JSON. The `sdk-*` commands use SDK-shaped snapshot DTOs and the read-only SDK
adapter, but they do not import or command the SDK. They are the contract seed
for the Rabbita cockpit, Lepus sidecar supervision, and future SDK bridge
process.

The first launchable sidecar scaffold is a native MoonBit wrapper around the
same typed SDK E1 adapter:

```text
moon run cmd/sdk_e1_bridge --target native -- route [robobook-root] [method] [path] [body-json] [snapshot-json] [read-only|control-gated] [command-json]
moon run cmd/sdk_e1_bridge --target native -- serve [robobook-root] [host] [port] [snapshot-json] [read-only|control-gated] [command-json]
```

It serves the bridge protocol routes for `contract`, `health`, `metadata`,
`capabilities`, latest telemetry, and read-only observation session lifecycle.
Without a
snapshot file it uses generated SDK-shaped snapshots; with a `snapshot-json`
argument it reads the latest `SdkE1Snapshot` file produced by an SDK collector.
That collector maps the reference SDK `get_joint_state()`, `get_imu_data()`,
`from_dds_get_joydata()`, and `get_mode()` calls into Moonrobo telemetry. The
execute route parses and validates `ExecuteIntent` envelopes. It rejects by
default in read-only mode; when launched as `control-gated`, it translates only
allowlisted high-control walk/run intents into SDK E1 command envelopes using
the reference `HighController::publish_cmd(vertical, horizontal, action, data)`
shape, writes that envelope to the configured command JSON outbox, and includes
both the logical command URI and outbox path in the accepted receipt. Accepted
command responses also include a telemetry frame whose `operator_input` echoes
the command capability, intent id, bridge request id, receipt id, and persisted
motion parameters; the host persists that frame as task-execution feedback.
The supervised writer process
watches that outbox and publishes through the SDK binding. Low-control and
unsupported capabilities remain rejected at the bridge boundary. The same
control-gated bridge exposes `POST /emergency/stop`; it requires the command
outbox, writes a zero-motion SDK `DEFAULT` envelope, and returns an
`EmergencyStop` receipt plus command feedback telemetry without requiring a
task-message dry-run or approval.
`src/bridge_client` is the native runtime client for this boundary:
`observe-run-sidecar` calls `/telemetry/latest` over localhost HTTP and feeds
the returned `TelemetryFrame` values into the bounded observation pipeline
without importing SDK bridge gateway internals. `bridge-execute` posts a typed
`ExecuteIntent` envelope to `/intents/execute` and parses the typed bridge
response. The SDK sidecar rejects that request when launched read-only, while
the supervised runtime launches the same transport in `control-gated` mode for
reviewed task-message execution. In `control-gated` mode the SDK bridge
re-runs the Moonrobo safety gate, including profile motion limits, before it
writes the high-control command outbox.
`src/bridge_execution` closes the native ledger loop for reviewed task messages:
it reloads the MoonBook task plan, verifies dry-run and approval evidence,
posts the matching `ExecuteIntent` through `src/bridge_client`, and persists
the actual sidecar response. Accepted responses become `Executed` receipts;
rejected or error responses become `Failed` receipts with `bridge_error`, while
the dispatch record still captures request id, route, status, message, and
receipt id. If the accepted response includes telemetry, bridge execution writes
it to `runs/telemetry/sidecar-execution/`, records a healthy runtime snapshot
for that command, appends the feedback artifact to the executed receipt, and
links it from `runs/task-executions/{snapshot_id}.json`. `message-sidecar` is
the one-command native workflow for the same path: user message, MoonBook safety
gates, bridge sidecar call, persisted response ledger.

## Health Response

```json
{
  "bridgeId": "sdk-e1",
  "status": "ok",
  "mode": "read-only",
  "robotId": "noetix-e1-lab-01",
  "startedAt": "2026-06-21T00:00:00Z",
  "lastTelemetryAt": "2026-06-21T00:00:01Z",
  "capabilitiesHash": "sha256:..."
}
```

## Telemetry Frame

```json
{
  "frameId": "tf-000001",
  "robotId": "noetix-e1-lab-01",
  "bridgeId": "sdk-e1",
  "capturedAt": "2026-06-21T00:00:01Z",
  "mode": "read-only",
  "joints": [],
  "imu": null,
  "operatorInput": null,
  "errors": []
}
```

The frame should preserve vendor errors instead of normalizing them away.

## Command Intent

```json
{
  "intentId": "intent-000001",
  "robotId": "noetix-e1-lab-01",
  "capability": "control.high.walk",
  "parameters": {
    "x": 0.1,
    "yaw": 0.0,
    "durationMs": 500
  },
  "requestedBy": {
    "kind": "operator",
    "id": "local"
  }
}
```

The bridge should reject unknown capabilities. Moonrobo should reject them
before calling the bridge.

## Noetix E1 Reference Bridge

The local `../sdk` repository suggests these bridge layers:

```text
sdk-e1-bridge
  -> Python or C++ wrapper
  -> high-control read APIs
  -> low-control read APIs
  -> optional high-control execute APIs
  -> DDS transport
```

Read-only mapping:

- `get_mode()` -> telemetry mode
- `get_joint_state()` -> joint state
- `get_imu_data()` -> IMU
- `from_dds_get_joydata()` -> operator input

The MoonBit `src/sdk_e1` package defines the raw snapshot contract for these
reads and converts it into `TelemetryFrame`, `BridgeHealth`, and bridge protocol
responses. The later sidecar should only need to poll the SDK and emit this
snapshot shape.

The MoonBit sidecar scaffold is:

```text
moon run cmd/sdk_e1_bridge --target native -- route examples/noetix-e1 GET /health ''
moon run cmd/sdk_e1_bridge --target native -- route examples/noetix-e1 GET /telemetry/latest ''
moon run cmd/sdk_e1_bridge --target native -- route examples/noetix-e1 POST /sessions/observe '{...StartObserve...}'
moon run cmd/sdk_e1_bridge --target native -- serve examples/noetix-e1 127.0.0.1 5391 [snapshot-json] [read-only|control-gated] [command-json]
```

The live SDK collector should write the same `SdkE1Snapshot` contract consumed
by the bridge routes. Moonrobo should not expose raw SDK objects to Rabbita,
Lepus, or Moontown. `sdk-telemetry-file` remains the fixture path for turning a
captured sidecar snapshot file into typed bridge protocol JSON.

The default runtime manifest uses this launch order:

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --live --sdk-root ../sdk --output /tmp/moonrobo-sdk-e1.json --interval-ms 100
python3 bridges/sdk_e1/sdk_e1_high_control_writer.py --watch --input /tmp/moonrobo-sdk-e1-command.json --sdk-root ../sdk --poll-ms 50
moonrobo-sdk-e1-bridge serve examples/noetix-e1 127.0.0.1 5391 /tmp/moonrobo-sdk-e1.json control-gated /tmp/moonrobo-sdk-e1-command.json
```

The bridge process depends on the collector and writer processes. The desktop
supervisor starts all three and stops them in reverse order.

High-control mapping:

- `publish_cmd(x, yaw, action, index)` only after safety approval

Low-control mapping:

- `set_joint(...)` disabled by default

## Process Lifecycle

The Lepus desktop shell can supervise local Moonrobo and bridge sidecars. The
desktop bundle writes `moonrobo.release-build.sh` for native command
installation, `moonrobo.desktop-launch.sh` as the Lepus command, and
`moonrobo.runtime-supervisor.sh` as the physical runtime command. The bridge
lifecycle is explicit:

- start
- start SDK snapshot collector
- start SDK bridge sidecar after the collector snapshot path is available
- health probe
- observe
- execute if enabled
- stop
- collect logs

Moontown may request tasks, but it should not directly own bridge processes.

## Test Bridge

A deterministic mock bridge is required before hardware work. It should:

- replay fixture telemetry
- return controlled bridge errors
- simulate stale telemetry
- simulate unsupported capabilities
- simulate emergency stop receipts

This lets safety and UI work progress without access to a robot.
