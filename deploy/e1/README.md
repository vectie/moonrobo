# E1 commissioning deployment

This directory preserves the January-protocol E1 transport and isolated
fixtures used on the Atlas host. MoonBit owns reference generation and checks;
`january_transport.py` independently publishes DDS frames. The live website is
read-only. This is deterministic commissioning, separate from LunaKine actor
inference and LunaFlux/MiniCPM planning.

See [findings and trial results](../../docs/E1_COMMISSIONING_FINDINGS.md) before
using this on a different firmware or unit. The robot exposes 24 motor records
for 23 modeled joints plus reserved slot 23. Mode 2 is a request, not a reported
firmware acknowledgement. Endpoint deletion is not physical handback evidence.

## Build and dependencies

From the repository root:

```sh
moon build cmd/e1_commission --target native
moon test src/e1_elbow_control tests/e1_ankle_shadow cmd/e1_elbow_shadow --target native
```

Python 3 with the pinned `requirements.txt` is needed on Linux. Install into a
dedicated environment (`python3 -m venv .venv`, then
`.venv/bin/pip install -r requirements.txt`); Cyclone DDS may require its native
runtime/headers when a wheel is unavailable. The verified deployment used
Python 3.10 and cyclonedds 11.1.0. Set `MOONROBO_E1_PYTHON` to the environment's
absolute Python path. MoonBit async is pinned at 0.20.2 in the scripts.

Packet inspection additionally needs `tcpdump`, `iproute2`, the compiled
status decoder library and capture privileges. SDK-free decoder/guard tests:

The [SDK migration/build notes](../../src/sdk_e1_native/MIGRATION.md) describe
the decoder and vendor-adapter build variants. These tests need neither the
vendor archive nor a robot:

```sh
cmake -S src/sdk_e1_native -B /tmp/e1-status-tests -DMOONROBO_E1_STATUS_TESTS_ONLY=ON
cmake --build /tmp/e1-status-tests
ctest --test-dir /tmp/e1-status-tests --output-on-failure
```

## Receive-only telemetry and website

The qualified link is `eno1`, host `192.168.55.101/24`, E1
`192.168.55.102`; management uses a separate port. These are deployment-specific
addresses. Confirm this is the only development computer before adopting the
reserved `.101` address. `dds-robot.example.xml` is an example, not an automatic
network configuration script.

From this directory, with the robot link already configured:

```sh
export CYCLONEDDS_URI="file://$PWD/dds-robot.example.xml"
python3 receive.py /tmp/e1-mirror
```

`receive.py` dynamically resolves the advertised status schema, validates IDs
0–23 and writes 23 named joint positions plus IMU to an atomic local pose file.
It creates no motor or mode publishers. The website fixes root position; IMU
provides orientation. For an SSH relay, run `follow.mbtx` remotely and pipe its
output to `relay.mbtx LOCAL_POSE_JSON` locally. A stale source stops refreshing
the file rather than replaying old telemetry.

From `ui/rabbita-cockpit`, set `MOONROBO_E1_LIVE_FILE` to that local file and run
`npm run dev:e1-live`; open `/e1-live.html`. The left pane is measured telemetry,
the right is a labeled reference preview. The endpoint accepts local GET only;
an expired file yields HTTP 503. Preview controls remain local to the page.

Use only one status observer during a trial. Stop this standalone receiver
before launching the packet observer below; its decoder can update the same
mirror through `MIRROR_DIR`. Duplicate RTPS DATA from concurrent subscriptions
previously tripped continuity checks. Restart the receiver after disconnection.

## Shadow and explicit powered stages

`preflight.py NEW_PREFLIGHT_JSON` is receive-only: it discovers the exact
January motor/mode subscriber types, rejects existing command publishers and
requires complete healthy status. A preflight is valid for 120 seconds.
Run `start_stage.mbtx` from this directory with all paths explicit:

```text
moon run start_stage.mbtx live|shadow STAGE PREFLIGHT NEW_RUN_DIR \
  HANDBACK_OR_DASH CONTROLLER_BINARY DECODER_LIBRARY MIRROR_DIR_OR_DASH
```

Stages are `hold`, `elbow` (15-second 5°), `elbow90` (180-second fold/return),
`drums` (four 10° strokes) and `raised-drums` (90°/60° alternating sequence).
Shadow accepts hold/drums/raised-drums and creates no command publisher.
Shadow motion feedback is explicitly simulated while other telemetry remains
measured; this validates the target path, not actual elbow tracking. Live
`elbow` requires a fresh hold/handback receipt through `HANDBACK_OR_DASH`.
After reviewing a successful real hold and observing actual handheld/factory
control, `confirm_handback.mbtx HOLD_RUN OPERATOR OBSERVATION NEW_RECEIPT`
records that operator observation. It does not perform the physical check and
refuses an expired or unsuccessful hold.
Other stages retain the deployed suspended commissioning behavior; accepting
their arguments does not establish physical support or handback.

The launcher requires existing capture privileges (`sudo -n`); it stores no
password. The output directory must be new. It archives status, targets,
transport/planner receipts and wire capture for that run. Select `live` only
for supervised powered commissioning. Nothing automatically starts from boot,
the website, an LLM response or a test command.

The deployed interface is action 11, zero axes, one mode-2 request, 24 motor
records and host-domain timestamps. The independent sender has a 2 ms publish
interval, 40 ms freshness checks and a 10 ms publication-lateness check. Mirror
I/O uses a bounded worker; planner heartbeats are separate from target ticks.
These are software checks, not hardware braking or real-time guarantees.

## Isolated regression tests

Build the controller first. From this directory on Linux, set absolute paths
for `MOONROBO_MOON`, `MOONROBO_E1_PYTHON` and `MOONROBO_E1_CONTROLLER`. Then:

```sh
sudo -E unshare --net "$MOONROBO_MOON" run isolated_tests.mbtx
sudo -E unshare --net "$MOONROBO_MOON" run isolated_tests.mbtx raised-only
```

The harness refuses any namespace containing an interface other than `lo`,
brings loopback up and forces `dds-loopback.xml`. It cannot reach the E1 link.
The default suite checks hold, accepted suspended settling, gentle elbow,
motor error, input stall and sender watchdog. Raised-only checks the full
two-elbow reference against decoded wire commands and simulated feedback.
`recorded-only` additionally needs `MOONROBO_E1_RECORDED_STATUS`, an external
saved capture. Repeated runs use fresh ignored `runs/` subdirectories.

`measure_trial.mbtx`, `measure_strokes.mbtx` and the Python transport auditors
analyze completed archives; they do not publish commands. Retain raw archives
outside Git and record their hashes alongside a sanitized report.
