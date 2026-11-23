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

For a recorded training gesture, set `MOONROBO_E1_REPLAY_FILE` to a private
`moonrobo.e1-gesture-replay.v1` tape before starting the live site. The
`/__e1_replay` endpoint is local, same-origin, GET-only and remains available
if the separate live feed goes offline. The right-hand source selector switches
between reference joint poses and recorded, unsent Actor PD targets; those
targets are not predicted physical motion. The left pane stays on current
telemetry. Playback and scrubbing never publish robot commands.

Create a tape using the original hash-verified dataset and saved shadow run:

```text
moon run scripts/prepare_e1_gesture_replay.mbtx DATASET SHADOW_TRACE SHADOW_REPORT NEW_TAPE_JSON
```

The helper keeps reference, actor-target and measured channels separate, uses
the run's recorded reference steps/heading alignment, and fixes displayed root
position as the live mirror does. Playback uses actual recorded sample times.
`/e1-live.html?play=1` starts the visual replay after loading, except when reduced
motion is requested. This entry point does not start an SDK or inference session.
See the [minimum-motion results](../../docs/E1_MINIMUM_MOTION_20261120.md) for the
typing reference, live-shadow measurements and remaining control qualification.

## Shadow and explicit powered stages

`preflight.py NEW_PREFLIGHT_JSON` is receive-only: it discovers the exact
January motor/mode subscriber types, rejects existing command publishers and
requires complete healthy status. A preflight is valid for 120 seconds.
Run `start_stage.mbtx` from this directory with all paths explicit:

```text
moon run --target native --release start_stage.mbtx live|shadow STAGE PREFLIGHT NEW_RUN_DIR \
  HANDBACK_OR_DASH CONTROLLER_BINARY DECODER_LIBRARY MIRROR_DIR_OR_DASH
```

Stages are `hold`, `elbow` (15-second 5°), `elbow90` (180-second fold/return),
`drums` (four 10° strokes), `raised-drums` (90°/60° alternating sequence) and
`typing-elbows` (60-second smooth entry into the typing reference's two elbow
angles, two-second hold, 60-second return). Shadow accepts hold/drums/
raised-drums/typing-elbows and creates no command publisher.
Shadow motion feedback is explicitly simulated while other telemetry remains
measured; this validates the target path, not actual elbow tracking. Live
`elbow` and `typing-elbows` require a fresh hold/handback receipt through `HANDBACK_OR_DASH`.
After reviewing a successful real hold and observing actual handheld/factory
control, `confirm_handback.mbtx HOLD_RUN OPERATOR OBSERVATION NEW_RECEIPT`
records that operator observation. It does not perform the physical check and
refuses an expired or unsuccessful hold.
Other stages retain the deployed suspended commissioning behavior; accepting
their arguments does not establish physical support or handback.

The [elbow-transfer record](../../docs/E1_ELBOW_TRANSFER_20261120.md) separates
its isolated tests/live-shadow result from the partial powered trial. Only SDK
motors 3 and 14 can change. This step does not commission the other arm joints
or run the whole-body actor. `measure_elbow_transfer.mbtx RUN NEW_REPORT` checks
every reference frame and all 22 fixed motor records from the saved planner
targets; live runs additionally require the independent wire and telemetry audits.

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
The coordinator is run as a native executable for commissioning. Its saved
`pipeline_timing_ms` reports capture archival latency, kernel-arrival-to-planner
latency, planner pipe writes and active coordinator polling gaps. This helps
distinguish delivery stalls from incoming telemetry gaps; it does not alter the
40 ms or 10 ms deadlines. File serialization after control stops is excluded
from the active polling measurement.

## Isolated regression tests

### Feedback-driven actor elbows

`actor-elbows` is a separate, experimental policy stage. It runs the frozen
LunaKine Ascend model on actual decoded status/IMU history, restricts model
authority to SDK elbows 3/14, holds all 22 other full records, and feeds the
inverse applied command back into the next observation. Its shadow mode keeps
**measured** joint feedback; it does not synthesize elbow tracking. It creates
only a file sink and exempts the physical following-error requirement while
retaining elbow bounds, freshness, motor errors and the stationary/glitch guard.
Nominal SDK leg ranges are reported as diagnostics for unqualified raw feedback
in shadow. Powered admission keeps the strict SDK range gate. See the
[right-knee investigation](../../docs/E1_KNEE_SHADOW_FIX_20261123.md); shadow does
not calibrate zeros or qualify a physical hold.
Live execution requires the same fresh real hold and observed-handback receipt
as the typing stage. Neither offline qualification nor a shadow result proves
handback or physical following.

See the [dated qualification and physical sequence](../../docs/E1_ACTOR_CONTROL_20261121.md).
The profile is generated with
`scripts/prepare_e1_actor_elbows.mbtx BUNDLE OM_SHA SHADOW_CONFIG REFERENCE NEW_CONFIG`.
It pins all model/reference hashes, 25% authority, a ten-second model-driven
approach and explicit filter/envelope/speed settings. The whole-body calibration
is diagnostic and must not be described as qualified hardware calibration.

Build `cmd/e1_actor_elbows` with native release warning denial. Precompile
`start_stage.mbtx` and `actor_stage.mbtx` as native release executables before
commissioning; no compilation should consume the fresh handback interval.
The `actor_stage` launcher accepts:

```
shadow|live hold|actor-elbows PREFLIGHT NEW_RUN HANDBACK_OR_DASH
```

Set absolute paths in `MOONROBO_E1_DEPLOY_DIR`, `MOONROBO_E1_COORDINATOR`,
`MOONROBO_E1_HOLD_CONTROLLER`, `MOONROBO_E1_ACTOR_CONTROLLER` and
`MOONROBO_E1_DECODER_LIBRARY`; optionally set `MOONROBO_E1_MIRROR_DIR`.
The coordinator is the compiled `start_stage` executable, and the hold owner
is the already commissioned `e1_commission` executable. The actor also needs
`MOONROBO_E1_ACTOR_BUNDLE`, `MOONROBO_E1_ACTOR_MODEL`,
`MOONROBO_E1_ACTOR_CONFIG`, `MOONROBO_E1_ACTOR_REFERENCE` and
`MOONROBO_E1_CANN_LIBRARY`, with the installed CANN/driver loader paths.
Set `MOONROBO_E1_PYTHON`, the existing CycloneDDS Python environment and the
interface-bound `CYCLONEDDS_URI` as for the January owner. The launcher obtains
capture credentials through sudo's terminal and stores no password.

On `.191`, the private native `e1-actor-stage.mbtx` wrapper is installed under
`/home/jiaanguo/lunakine-deployment-20261117/actor-elbows-20261121` with these paths
preconfigured. Nothing starts automatically. A receive-only fresh `preflight.py`
receipt is required before either live shadow or a powered stage.

`audit_actor_targets.py CONFIG TARGET_TRACE NEW_REPORT` checks every saved
proposal, model sequence, original model-input age, affine conversion, applied
previous action, authority/filter/slew, fixed records and exact return. It does
not open network sockets or assert that a proposal reached the physical wire.
The passive status decoder deduplicates exact RTPS writer sequences before
delivering samples. Multiple local DDS readers can receive identical copies.
Only matching raw CDR bytes and source timestamps are suppressed, and the first
kernel receipt remains authoritative. Conflicting duplicates and unknown old
samples fail; missing unique sequences still reach the continuity guard as gaps.
The bounded identity cache does not reorder, interpolate or refresh telemetry.
`test_status_packets.py` exercises those cases without SDK or network access.
`extract_e1_actor_inference.mbtx` preserves exact observed model inputs for
sampled CPU ONNX comparison; `compare_e1_live_shadow_onnx.mbtx prepare-phased`
selects baseline and advancing-reference frames without changing tolerances.

`test_actor_transport.mbtx TRACE CONFIG NEW_DIRECTORY` must run in a lo-only
network namespace. Precompile `replay_actor_targets.mbtx` and set its native
executable path in `MOONROBO_E1_ACTOR_REPLAY`. The test replays saved real model
proposals through actual DDS and injects a stale model input despite fresh
telemetry. It cannot reach `eno1`; it is transport qualification, not a fresh
closed-loop model run. `replay_actor_input.mbtx STATUS SKIP_MS` separately
rebases saved sensor clocks for recorded-input NPU tests and never sends commands.

### Reported leg-effort shadow hypothesis

The raw-packet [torque investigation](../../docs/E1_TORQUE_SOURCE_20261123.md)
locates intermittent zeros upstream of the host SDK. Set
`MOONROBO_E1_REPORTED_EFFORT_SHADOW=1` only with `shadow hold` or
`shadow actor-elbows` to test the nonzero preload counterfactual. It waits for
a complete nonzero leg report after stationary validation, freezes the leg
positions and damping-compensated feedforward, and records the full source
sample with `power_qualified:false`. This does not establish torque validity.
The launcher/owners/sender prohibit promoting this hypothesis to live control.
Default powered gains, zero feedforward and admission limits are unchanged.

`audit_shadow_hold_effort.py RUN NEW_REPORT` checks the hold. For actor traces
with this marker, `audit_actor_targets.py CONFIG TARGETS NEW_REPORT --status STATUS`
requires a captured-status match in addition to the original model/target
checks. `prepare_hold_trial.mbtx` preserves both hypotheses and remains unarmed
until a reliable active effort source and the physical transition are qualified.

### Existing commissioning regression suite

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

## Position-feedback hold experiment

`MOONROBO_E1_POSITION_HOLD_SHADOW` selects an explicit
[`position-hold-shadow.json`](position-hold-shadow.json) configuration for the
existing **`shadow hold`** stage only. It keeps all 24 position records fixed
and computes bounded leg effort from position error without using reported
torque. This stage observes 15 seconds; it creates no mode/motor publishers.
Live and actor stages reject this experiment. Its target marker is also
rejected by the independent live transport, even with the shadow flag removed.
Do not combine it with `MOONROBO_E1_REPORTED_EFFORT_SHADOW=1`.

After a completed run, `audit_shadow_hold_effort.py RUN NEW_REPORT` independently
checks every proposal against the captured inputs. See the
[implementation, parameters and live evidence](../../docs/E1_POSITION_HOLD_SHADOW_20261123.md).
The successful shadow does not prove powered holding or handback.

## Finite position-feedback hold commissioning

The separate [`position-hold-trial.json`](position-hold-trial.json) request
admits a one-second **hold-only** commissioning attempt after explicit operator
authorization and current physical setup confirmation. Set
`MOONROBO_E1_POSITION_HOLD_TRIAL` to this request and
`MOONROBO_E1_POSITION_HOLD_SHADOW_AUDIT` to its pinned prior shadow audit. Use
`shadow hold` to preview this exact path, then one separately requested
`live hold`. Keep older shadow/reported-effort flags unset. No actor or elbow
stage follows automatically.

The sender independently checks the evidence digest, fixed references,
feedback calculation and deadline. See
[completed tests and handback verification](../../docs/E1_POSITION_HOLD_TRIAL_20261123.md).
The first real attempt stopped for continuous left-hip drift; powered holding
has not been qualified. The operator reported steadiness and normal handheld
response after the stop. Do not use this failed trial to commission actor takeover.
