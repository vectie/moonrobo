# SDK E1 Read-Only Bridge

This folder contains the first sidecar scaffold for the Noetix E1 SDK reference.

The sidecar emits the snapshot JSON consumed by the MoonBit `src/sdk_e1`
adapter. It deliberately exposes only read APIs:

- `get_mode()`
- `get_joint_state()`
- `get_imu_data()`
- `from_dds_get_joydata()`

It does not call `publish_cmd` or low-control APIs.

## Fixture Smoke

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --once
```

This emits one fixture snapshot and does not require a built SDK or a robot.

To write the snapshot file consumed by the MoonBit bridge sidecar:

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --once --output /tmp/moonrobo-sdk-e1.json
moon run cmd/main --target native -- sdk-telemetry-file examples/noetix-e1 /tmp/moonrobo-sdk-e1.json
```

## Live SDK Smoke

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --live --once --sdk-root ../sdk --output /tmp/moonrobo-sdk-e1.json
```

Live mode expects the SDK Python binding to be built under `../sdk/build` and
sets `CYCLONEDDS_URI` to `../sdk/config/dds.xml` unless already provided.
Without `--once`, the collector loops and atomically replaces the output file at
`--interval-ms`. The sidecar can read the same file:

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --live --sdk-root ../sdk --output /tmp/moonrobo-sdk-e1.json
moon run cmd/sdk_e1_bridge --target native -- serve examples/noetix-e1 127.0.0.1 5391 /tmp/moonrobo-sdk-e1.json
moon run cmd/main --target native -- observe-run-sidecar examples/noetix-e1 live-check 3 /tmp/moonrobo-sdk-e1.json
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
