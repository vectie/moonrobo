# SDK E1 Bridge Helpers

This folder contains the first sidecar scaffold for the Noetix E1 SDK reference.

The collector emits the snapshot JSON consumed by the MoonBit `src/sdk_e1`
adapter. It deliberately exposes only read APIs:

- `get_mode()`
- `get_joint_state()`
- `get_imu_data()`
- `from_dds_get_joydata()`

It does not call `publish_cmd` or low-control APIs.

The high-control writer is separate. It watches one MoonRobo command JSON file
and publishes only the allowlisted SDK-shaped envelopes that the MoonBit bridge
writes after the normal task-message safety gates.

## Fixture Smoke

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --once
python3 bridges/sdk_e1/sdk_e1_high_control_writer.py --self-check
```

This emits one fixture snapshot and does not require a built SDK or a robot.

To write the snapshot file consumed by the MoonBit bridge sidecar:

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --once --output .tmp/products/moonrobo/sdk-e1/snapshot.json
moon run cmd/main --target native -- sdk-telemetry-file examples/noetix-e1 .tmp/products/moonrobo/sdk-e1/snapshot.json
```

To dry-run one high-control command file without loading the live SDK binding:

```text
moon run cmd/sdk_e1_bridge --target native -- route examples/noetix-e1 POST /intents/execute '{...ExecuteIntent...}' '' control-gated .tmp/products/moonrobo/sdk-e1/command.json
python3 bridges/sdk_e1/sdk_e1_high_control_writer.py --input .tmp/products/moonrobo/sdk-e1/command.json --dry-run
```

The emergency route uses the same command outbox but does not require the
normal task-message dry-run or approval flow:

```text
moon run cmd/sdk_e1_bridge --target native -- route examples/noetix-e1 POST /emergency/stop '{...EmergencyStop...}' '' control-gated .tmp/products/moonrobo/sdk-e1/command.json
python3 bridges/sdk_e1/sdk_e1_high_control_writer.py --input .tmp/products/moonrobo/sdk-e1/command.json --dry-run
```

## Live SDK Smoke

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --live --once --sdk-root ../sdk --output .tmp/products/moonrobo/sdk-e1/snapshot.json
```

Live mode expects the SDK Python binding to be built under `../sdk/build` and
sets `CYCLONEDDS_URI` to `../sdk/config/dds.xml` unless already provided.
Without `--once`, the collector loops and atomically replaces the output file at
`--interval-ms`. The sidecar can read the same file:

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --live --sdk-root ../sdk --output .tmp/products/moonrobo/sdk-e1/snapshot.json
python3 bridges/sdk_e1/sdk_e1_high_control_writer.py --watch --input .tmp/products/moonrobo/sdk-e1/command.json --sdk-root ../sdk
moon run cmd/sdk_e1_bridge --target native -- serve examples/noetix-e1 127.0.0.1 5391 .tmp/products/moonrobo/sdk-e1/snapshot.json control-gated .tmp/products/moonrobo/sdk-e1/command.json
moon run cmd/main --target native -- observe-run-sidecar examples/noetix-e1 live-check 3 .tmp/products/moonrobo/sdk-e1/snapshot.json
```

## Contract

The JSON shape is:

```text
SdkE1Snapshot
  frame_id
  captured_at_ms
  mode
  telemetry_age_ms
  joints[24]
  imu
  joy
  errors
```

MoonBit validates that the 24 SDK motor IDs match the `RobotProfile` joint
indices before converting a snapshot into `TelemetryFrame` or bridge protocol
JSON.

High-control command JSON is:

```text
SdkE1HighControlCommand
  intent_id
  capability
  action
  action_code
  vertical
  horizontal
  duration_ms
  data
```

The writer accepts only `WALK`, `RUN`, and emergency `DEFAULT` envelopes.
Low-control and unsupported capabilities stay rejected by the MoonBit bridge
before a command file is written.
