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

The first `sdk-e1` bridge should start with read-only observation.

## Local HTTP Shape

Draft routes:

```text
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

All mutating routes return a receipt fragment. Moonrobo turns that into a full
RobotBook receipt.

The first local desktop API exposes this as `POST /api/intents/evaluate`: it
accepts a command-intent submission, runs the MoonBit safety pipeline, and writes
a RobotBook receipt. It is an evaluation path only; bridge execution remains a
separate future route.

The MoonBit protocol package mirrors this shape as typed request and response
envelopes. Sidecars can expose HTTP, stdio, or local process transports, but
they should preserve the same operation names, request IDs, bridge IDs, robot
IDs, and response payload fields.

Native protocol smoke commands:

```text
moon run cmd/main --target native -- bridge-health [robotbook-root]
moon run cmd/main --target native -- bridge-telemetry [robotbook-root]
moon run cmd/main --target native -- sdk-health [robotbook-root]
moon run cmd/main --target native -- sdk-telemetry [robotbook-root]
moon run cmd/main --target native -- sdk-telemetry-file [robotbook-root] [snapshot-json]
```

These commands currently use the deterministic mock bridge and print protocol
JSON. The `sdk-*` commands use SDK-shaped snapshot DTOs and the read-only SDK
adapter, but they do not import or command the SDK. They are the contract seed
for the Rabbita cockpit, Lepus sidecar supervision, and future SDK bridge
process.

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

The initial sidecar scaffold is:

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --once
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --live --once --sdk-root ../sdk
```

Fixture mode emits a deterministic `SdkE1Snapshot`. Live mode imports the SDK
Python binding from `../sdk/build` and still uses only read APIs.
`sdk-telemetry-file` turns a sidecar snapshot file into typed bridge protocol
JSON through the MoonBit adapter.

High-control mapping:

- `publish_cmd(x, yaw, action, index)` only after safety approval

Low-control mapping:

- `set_joint(...)` disabled by default

## Process Lifecycle

The Lepus desktop shell can supervise local Moonrobo and bridge sidecars. The
bridge lifecycle should be explicit:

- start
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
