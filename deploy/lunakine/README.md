# LunaKine two-host software deployment

DGX Spark runs LunaFlux + MiniCPM. The separate Atlas 300V host runs LunaKine
inference and MoonRobo's local reference/control loop. MoonRobo training stays
LibTorch + CUDA. No LLM call belongs in the actor tick.

The Atlas task NIC connects to Spark; its other NIC connects to E1. Use distinct
subnets and bind the task listener to the task-facing address. The robot NIC's
SDK/DDS binding is an explicit setting of the later exact-SDK adapter, not IP
forwarding through the task server. Two Ethernet ports do not change either
runtime's API. All examples below are software/shadow commands.

## Installed Atlas stack, 2026-11-17

`jiaanguo@192.168.2.191` runs HDK26.1.1 on kernel6.8.0-149 after the
authorized reboot at2026-11-17 16:14:56. The DKMS driver loads automatically.
The card reports Atlas300V / Ascend310P3, logical device0, healthOK. CANN9.1.0
toolkit and310P ops are installed in `/home/jiaanguo/Ascend/cann-9.1.0`, with
the vendor environment entrypoint `/home/jiaanguo/Ascend/cann/set_env.sh`.
Offline compiler Python dependencies are isolated in
`/home/jiaanguo/lunakine-deployment-20261117/cann-python`; the LunaKine inference
process uses native AscendCL and requires no Python or training framework.

Deployment source, actor and reports are under
`/home/jiaanguo/lunakine-deployment-20261117`. The actual
`e1-actor-fp32.om` compiles for `Ascend310P3` with FP32 I/O and
`must_keep_origin_dtype`. The native live comparison passes1,000 calls and
29,000 action checks after reboot: maximum LibTorch error2.861e-6, mean
latency2.333ms, p99 latency2.392ms including transfers. The
[post-boot report](../../output/lunakine-host-verification-20261117/actor-live-fp32-postboot-v2.json)
records the sampled scope. The vendor upgrade tool confirms activated
firmware9.0.0.9.220 for hboot1a, hboot1b and hlink. The NPU returns to idle
after runtime cleanup. SDK calibration, sustained timing and physical E1
control remain separate acceptance.

The recorded-feature task service also passes on the actual NPU: local HTTP
submission reaches Completed through the shared live-clock runner and Ascend
actor, with no SDK or motor publication. See
[`atlas-actor-shadow-npu-v1/report.json`](../../output/lunakine-host-verification-20261117/atlas-actor-shadow-npu-v1/report.json).
The owned build toolchain is
`/home/jiaanguo/lunakine-deployment-20261117/moon-toolchain-0.10.15`
(moon0.1.20261012 / moonc0.10.15+943464bfa), independent of temporary mounts.

`scripts/stage_lunakine_actor_host.mbtx REPO NEW_ROOT/moonrobo` stages only the
eight deployment packages for `cmd/e1_actor`, with a minimal module manifest
and a workspace referencing sibling `NEW_ROOT/lunakine`. It copies source,
not a second actor implementation. Build with the owned toolchain and
`CC=/usr/bin/gcc-12`; training, simulator and SDK packages are absent.

Add the optional `planner` argument to stage the four-package task coordinator
for Spark instead. That source view depends only on MoonBit async, with no
actor runtime dependency. The actual text-only and image-assisted coordinator
calls to native MiniCPM and the LAN Ascend shadow service both reach Completed:
[`two-host-report-v1.json`](../../output/lunakine-host-verification-20261117/two-host-report-v1.json).
The native model's JSON/SSE/auth/media smoke is retained in
[`spark-live-http-v1/report.json`](../../output/lunakine-host-verification-20261117/spark-live-http-v1/report.json).
These temporary services ran recorded conversion probes. Both listeners were
stopped after testing.

## Prepare the E1 SDK before connecting the robot

On 2026-11-18, Atlas `.191` built the native SDK shadow executable and both
adapters in `/home/jiaanguo/lunakine-deployment-20261117/e1-sdk-3.1.0`.
Both adapters linked the Noetix 3.1.0 x86-64 SDK archive and passed
`ldd -r` with the bundled CycloneDDS libraries. The loopback test used a
test double for the robot and ran the trained actor on the real Atlas 300V.
It recorded two 24-slot command frames with publication disabled. The test
service stopped after completion.
[Atlas shadow test result](../../output/lunakine-e1-prep-20261118/atlas-sdk-shadow-smoke.json).

Stage the SDK shadow source on the Atlas host:

```sh
moon run scripts/stage_lunakine_actor_host.mbtx ABSOLUTE_REPO NEW_ROOT/moonrobo sdk-shadow
```

Place LunaKine in `NEW_ROOT/lunakine` and the Noetix SDK 3.1.0 checkout
(`3055bdc644f61caf948d935ee274c5c48703c24f`) in `NEW_ROOT/noetix-sdk`. Keep
the SDK's x86-64 library and CycloneDDS directory together, including the
shared-library symlinks. From the staged MoonRobo source, with its native
MoonBit toolchain on PATH:

```sh
cmake -S src/sdk_e1_native -B ../sdk-build -DMOONROBO_E1_SDK_API=3.1 -DSDK_ROOT=/ABSOLUTE/NEW_ROOT/noetix-sdk
cmake --build ../sdk-build --target moonrobo_e1_low moonrobo_e1_status
env LD_LIBRARY_PATH=/ABSOLUTE/NEW_ROOT/noetix-sdk/dds/x86_64/lib ldd -r ../sdk-build/libmoonrobo_e1_status.so
moon build --release --target native --deny-warn cmd/e1_sdk_shadow
```

Use Eigen 3 from the host or supply `-DEigen3_DIR=.../share/eigen3/cmake`
for a staged installation. Check that the loader resolves both DDS libraries
and reports no missing symbols. These steps compile and inspect the software
without initializing the vendor controller.

Connect the E1 cable to Atlas port `eno1` (MAC `30:9c:23:20:97:f3`).
Port `enp4s0` carries the cluster address `192.168.2.191`. Check Ethernet carrier
before setting a robot address or starting a DDS session. The vendor's external
host instructions use `192.168.55.101/24` with DDS peer `192.168.55.102`
when the external host replaces the development board. Confirm whether the
E1 has an active onboard board at that address before assigning it to Atlas.
[Noetix E1 SDK guide](https://web.noetixrobotics.com/docs/%E9%80%9A%E7%94%A8%E4%BA%BA%E5%BD%A2%E6%9C%BA%E5%99%A8%E4%BA%BA/E1%20SDK%E5%BC%80%E5%8F%91%E6%8C%87%E5%8D%97/).
The SDK shadow CLI initializes the vendor controller and requires the robot's
actual joint/IMU calibration and prepared references. Keep physical control
disabled during connection and telemetry qualification.

## Software available now

- Portable trained actor export, static ONNX, explicit ATC command generation.
- Native AscendCL prepare/run-into/close with reused buffers and named inputs.
- Typed skill catalog/supervisor, task HTTP client/server, and LLM coordinator.
- Local actor tick with history, previous actions, expiry, observed completion,
  error/telemetry stop and a supplied output sink.
- Offline E1 actor replay and a task-driven shadow service. Both record outputs
  without loading the E1 SDK or publishing motor commands.
- The selected Spark model is **MiniCPM-V 4.7 35B-A3B**, prioritizing capability.
  LunaFlux now has its full BF16 text plan, resident/request owners and an
  inspect/run/serve executable. Actual GPU execution and the vision path remain open.
  Small MiniCPM5-2B compatibility tests do not establish flagship model support.

The catalog example is a software fixture, not a physical skill catalog.
Replace its reference IDs with evaluated references only when the E1 adapter
and its calibration/control contract are ready.

## Export and replay

Use sibling checkouts `moonrobo`, `lunakine`, `moonnum`, and `moonphys` as listed
in `moon.work`. From MoonRobo:

```sh
moon run cmd/e1_train --target native -- export-lunakine --actor SOURCE_ACTOR --tensor-library LIBTORCH_PLUGIN --output NEW_BUNDLE
moon run cmd/e1_train --target native -- compare-lunakine --actor SOURCE_ACTOR --tensor-library LIBTORCH_PLUGIN --bundle NEW_BUNDLE --output NEW_COMPARISON.json
moon run scripts/make_actor_shadow_fixture.mbtx NEW_COMPARISON.json NEW_TAPE.json
moon run cmd/e1_actor --release --target native -- shadow-reference NEW_BUNDLE NEW_TAPE.json NEW_REPORT.json
```

The E1 CLI currently compiles the existing MuJoCo adapter. Set `CPATH` to the
matching MuJoCo include directory when building. Source actor conversion needs
the tensor plugin; the portable and LunaKine actor loaders do not load it.
For the Atlas deployment path, the standalone entrypoint imports the deployment
actor/shadow and typed task packages, and needs no MuJoCo headers or LibTorch:

```sh
moon run cmd/e1_actor --release --target native -- inspect NEW_BUNDLE
moon run cmd/e1_actor --release --target native -- reference NEW_BUNDLE INPUT_JSON NEW_OUTPUT_JSON
```

`INPUT_JSON` contains `history` rows and flat `goals`. These commands produce
inspection/actions/nominal positions with `published:false`; they initialize no
SDK or accelerator. The [deployment actor guide](../../src/e1_actor/README.mbt.md)
also documents explicit Ascend inference for after the model/CANN target is
qualified. Existing `e1_train` recorded-shadow commands remain compatibility
wrappers around the same deployment-only shadow implementation.

The generated tape contains synthetic conversion probes. For a real recording,
`ActorReplayFrame` stores calibrated 99-feature observations, 730 goal features
for the default actor, and 50 Hz capture timestamps. Replay replaces the 29
previous-action features with the selected actor's own outputs. Reports include
physical-axis actions and nominal setpoints; calibration offsets and physical
publication belong to the robot adapter.

## Task-driven shadow service

On the Atlas host, initially with the explicit offline reference backend:

```sh
moon run cmd/e1_actor --release --target native -- serve-shadow-reference NEW_BUNDLE NEW_TAPE.json 127.0.0.1:8171
```

Use the Atlas task-facing IP instead of loopback when testing from Spark. This
service replays recorded feature values under its local replay clock; it does
not establish live telemetry freshness or 50 Hz NPU performance. It prints
`published=false` shadow ticks. In a separate terminal, from MoonRobo:

```sh
moon run cmd/actor_task --target native -- catalog http://127.0.0.1:8171
moon run cmd/actor_task --target native -- submit http://127.0.0.1:8171 deploy/lunakine/proposal.example.json task-one 1000
```

`GET /v1/state` returns the current execution. Reference completion produces
`Completed`; it does not certify physical task success. `POST /v1/cancel`
interrupts the named execution. `actor_task serve CATALOG.json IP:PORT` provides
a standalone task service for protocol work, without an actor runner.

Once a LunaFlux MiniCPM chat instance is qualified on Spark:

```sh
moon run cmd/actor_task --target native -- plan http://ATLAS_TASK_IP:8171 http://127.0.0.1:8000 MiniCPM-V-4.7-35B-A3B 'Run the fixture skill' task-two 1000
```

For explicit snapshots, point the planner at LunaFlux `serve-media` and pass
local PNG/JPEG files:

```sh
moon run cmd/actor_task --target native -- plan-images http://ATLAS_TASK_IP:8171 http://SPARK_TASK_IP:8000 MiniCPM-V-4.7-35B-A3B 'Select a catalog skill for these views.' visual-one 1000 front.png hand.jpg
```

Files are read before planning and sent as labeled inline image parts. Camera
adapters can instead pass immutable encoded frames to the typed planner API.
The actor loop remains separate; capture freshness/calibration and actual model
grounding still need the supplied hardware. The 30-second planner timeout does
not consume the skill's execution TTL. The existing context recheck and bounded
skill validation apply before submission.

Set `LUNAFLUX_API_KEY` in both the server and planner environment for the new
buffered endpoint, which uses LunaFlux's existing bearer policy. The coordinator
accepts one completed JSON proposal, then adds request identity, sequence and
expiry. It rejects a changed control context during generation. It does not
retry a rejected proposal automatically.

## Spark text preparation

From the sibling LunaFlux checkout, the source exporter and resident executable
share the same initial 32-row/4096-token flagship program builder. Prepare and
inspect staged assets without device access:

```sh
moon run cmd/minicpm_v47_prepare --target native -- ASSET_DIRECTORY HEADER_DIRECTORY NEW_PREPARATION_DIRECTORY
moon run scripts/build-minicpm-v47-aot.mbtx NEW_PREPARATION_DIRECTORY NEW_AOT_DRY_RUN
moon run cmd/minicpm_v47_generate --release --target native -- inspect MODEL_ROOT cmd/minicpm_v47_generate/requests.example.json NEW_INSPECTION_DIRECTORY
```

`MODEL_ROOT` inspection needs the staged shard files so their bounded headers can
be read. A separate software smoke can create explicitly labelled sparse zero
fixtures; those are not inference weights. See the
[LunaFlux executable guide](../../../lunaflux/cmd/minicpm_v47_generate/README.md)
for reproduction and the explicit run-mode command after hardware is supplied.
The local executable smoke verifies no-GPU inspection, not upload or generation.
New preparations also export an eighth `vision_encoder.cu` module. Its full
318-stage program has independent native loading/storage/frame/execution owners
and a separate combined image runtime now binds it to decoder prefill through
`image_scatter.cu`. Its asynchronous owner keeps features on device and prevents
reuse until decoding retires. v19 records combined residency, preserving all nine
v18 CUDA sources. The planned combined allocation payload is 71.01 GB before
driver/module/queue overhead. The executable below still uses its seven text
modules. Local `inspect-media`/`run-media` modes now use all nine modules for
PNG/JPEG queues. JSON/SSE HTTP images are also implemented below; Spark
acceptance remains pending.
The executable handles repeated greedy text requests and result files. It now
also exposes buffered or streaming chat over the same resident owner. On the supplied Spark,
after staging the actual checkpoint and matching compiled modules, use:

```sh
moon run cmd/minicpm_v47_generate --release --target native -- serve MODEL_ROOT CUBIN_ROOT 127.0.0.1:8000 0 100000000000
```

For local PNG/JPEG image queues, run from LunaFlux with the same selected model
and all nine matching AOT modules:

```sh
moon run cmd/minicpm_v47_generate --release --target native -- inspect-media MODEL_ROOT MEDIA_ROOT cmd/minicpm_v47_generate/media-requests.example.json NEW_INSPECTION_DIRECTORY
moon run cmd/minicpm_v47_generate --release --target native -- run-media MODEL_ROOT CUBIN_ROOT MEDIA_ROOT cmd/minicpm_v47_generate/media-requests.example.json NEW_RESULT_DIRECTORY 0 100000000000
```

Inspection reads image payloads and bounded tensor headers, not tensor payloads,
and opens no GPU. The local smoke uses labelled sparse-zero shard fixtures and
synthetic PNG/JPEG images, never an inference checkpoint. Run mode remains
unexecuted on real Spark hardware. Direct camera RGB frames can use the same
typed media preparer once the SDK adapter is supplied; the HTTP endpoint above
still accepts text only. Decoder metadata/precision limits are explicit in the
[RGB8 contract](../../../lunaflux/media/rgb8/README.mbt.md).

For inline PNG/JPEG HTTP requests, use the same model and all nine
CUBINs from LunaFlux:

```sh
moon run cmd/minicpm_v47_generate --release --target native -- serve-media MODEL_ROOT CUBIN_ROOT 127.0.0.1:8000 0 100000000000
```

It uses the existing bearer key/timeout environment and `/v1/chat/completions`
route. Send `stream:false` for one JSON response or `stream:true` for SSE,
greedy controls, and user text or ordered
text/`image_url` content parts with inline PNG/JPEG data URIs. The full HTTP body
is at most 16 MiB; remote/file URLs are not fetched. The synthetic protocol
example is `cmd/minicpm_v47_generate/media-chat.example.json`. Native scripted
tests cover replies, usage, cancellation and reuse; real checkpoint serving and
visual quality remain unverified. See the
[image chat guide](../../../lunaflux/integration/minicpm_v47_chat/README.mbt.md).

MoonRobo's planner continues to request complete buffered proposals. Streaming
is available to interactive callers; partial deltas never become actor commands.
After SSE headers, timeout/disconnect closes the stream and retires native work
before the next request. Canonical completion/failure includes terminal usage
or error and one `[DONE]`; an interrupted stream has no synthetic completion.

Set `LUNAFLUX_API_KEY` before starting the server. The model alias matches
`actor_task plan` above. The client sends fixed-length UTF-8 JSON; the initial
bounded ingress does not accept chunked requests. Buffered responses include
`stop`/`length`, and the planner rejects truncated content. One request executes
at a time, with 429 on capacity and native cleanup before timeout/disconnect
reuse. Streaming and model/health discovery routes remain open. Software tests
cover canonical HTTP with scripted native outputs, not real model understanding;
the real planner-to-model link still needs hardware and task-quality acceptance.

## Compile and select Ascend

From LunaKine, after the installed card reports its exact SoC and CANN is ready:

```sh
moon run scripts/compile_actor.mbtx NEW_BUNDLE EXACT_SOC OUTPUT_PREFIX EXPLICIT_PRECISION --dry-run
moon run scripts/compile_actor.mbtx NEW_BUNDLE EXACT_SOC OUTPUT_PREFIX EXPLICIT_PRECISION
```

On the Atlas host:

```sh
moon run cmd/e1_actor --release --target native -- shadow-ascend NEW_BUNDLE LIBASCENDCL ACTOR.om NEW_TAPE.json NEW_NPU_REPORT.json
moon run cmd/e1_actor --release --target native -- serve-shadow-ascend NEW_BUNDLE LIBASCENDCL ACTOR.om NEW_TAPE.json ATLAS_TASK_IP:8171
```

Actor model inputs are static FP32 `history` and `goals`, with FP32 output. Compiler
precision is explicit and needs action-error evaluation. No missing library or
unsupported model selects a CPU fallback. Keep runtime/session preparation
outside the tick and close sessions before their runtime.

## Task wire contract

The transport is small HTTP/JSON on the task network:

| Endpoint | Meaning |
| --- | --- |
| `GET /v1/catalog` | Host `now_ms`, catalog ID, control-context version, last accepted sequence, and skills. |
| `GET /v1/state` | Host time, context version, execution object or `null`. |
| `POST /v1/skills` | `policy_skills.Request`; returns the existing or newly accepted execution. |
| `POST /v1/cancel` | Object containing `request_id`; interrupts that execution. |

Int64 times, sequences and context versions are decimal **JSON strings**, matching
MoonBit serialization. The LLM emits only `{"skill_id":"...","parameters":{}}`.
The coordinator uses advertised Atlas time; Spark and Atlas do not need matched
clock epochs for this protocol. Request TTL starts after planning. Parameter
bounds/defaults belong to the catalog; an E1 reference adapter must explicitly
implement any offered parameter transform. Recorded reference adapters offer none.

Execution is `Accepted -> Running -> Completed|Failed|Interrupted`. Exact request
retries are idempotent, stale sequences are rejected, and active work requires
explicit cancellation before replacement. State is process-local: after a service
restart, fetch a fresh catalog and context. The local runner checks expiry and
telemetry freshness without waiting for another task message. A task disconnect
does not immediately cancel a bounded running skill; it ends at local completion,
expiry, failure, or operator stop. Start/finish have no remote endpoints.

The [local actor runner](../../src/policy_runner/README.mbt.md) takes one
nondecreasing host clock at construction. `tick()` rechecks task ownership,
expiry and telemetry after reference/inference calls before publishing. The
shadow service shares its task clock; deterministic replay advances a separate
explicit replay clock. Post-call checks do not interrupt a blocked vendor call
or replace a qualified independent device watchdog.

The shared [task host](../../src/policy_host/README.mbt.md) now owns that HTTP
service and20ms loop for both shadow and E1 composition. Its factory receives
the same clock/supervisor used by admission. Slow ticks discard missed slots
and wait a full period; cooperative cancellation/error interrupts the owned
execution and invokes the supplied stop callback once. Incomplete HTTP bodies
do not block ticks. This remains a cooperative event loop: a synchronous vendor
call blocks it, and physical authority/watchdog/stop acceptance is separate.

The actual portable actor's live-clock, shadow-only task smoke is reproducible:

```sh
moon run scripts/test_lunakine_actor_clock.mbtx ABSOLUTE_MOONROBO PORTABLE_BUNDLE RECORDED_TAPE NEW_OUTPUT
moon run scripts/test_lunakine_actor_clock.mbtx ABSOLUTE_MOONROBO PORTABLE_BUNDLE CANN_LIBRARY MODEL_OM RECORDED_TAPE NEW_OUTPUT
```

It builds only the deployment CLI, opens local HTTP and runs recorded features
through the real actor, with no training/simulator import, SDK or motor sink.
The fresh result is `output/e1-actor-shadow-service-v1/report.json`. See the
[shadow package](../../src/e1_actor_shadow/README.mbt.md) for ownership and
recorded-feature scope. The native archive's v1/v2 contract text stays frozen for
compatibility; its historical runtime description does not enumerate the
separate LunaKine/ONNX exporter capabilities.

## SDK-input shadow service

The separate [SDK-input shadow CLI](../../src/e1_actor_sdk_shadow/README.mbt.md)
can exercise calibrated sensor input and task-driven inference while recording
complete mapped command frames. It never calls SDK command publication; the
original `cmd/e1_actor` keeps its SDK-free dependency boundary. With the selected
plugin, initialization behavior, calibration and references confirmed, run:

```sh
moon run cmd/e1_sdk_shadow --release --target native -- reference BUNDLE SDK_PLUGIN SESSION_JSON 127.0.0.1:8171
moon run cmd/e1_sdk_shadow --release --target native -- ascend BUNDLE CANN_LIBRARY MODEL_OM SDK_PLUGIN SESSION_JSON 127.0.0.1:8171
```

On the Atlas host, set `SDK_PLUGIN` to `sdk-build/libmoonrobo_e1_status.so`
under the installed E1 SDK directory. This receive-only adapter resolves the
publisher's DDS status type, checks all 24 motor IDs and rejects command
publication. Opening it starts DDS discovery. File replay can call its
`moonrobo_e1_status_decode` entry point without opening a DDS participant.
Recording schema 0 uses the Atlas capture layout and reports workmode as
unknown (−1). Schema 1 reads the SDK 3.1 workmode field. Select the schema
from the recording provenance because both messages occupy 1156 bytes.

The Ascend variant also initializes CANN and loads the model.
Use the package's documented `moonrobo.e1-sdk-shadow.v1` session fields: a typed
skill catalog, explicit joint/IMU calibration, prepared reference paths and local
receipt-age budget. No hardware values are guessed. Starting it accepts no
task automatically; submit a bounded skill through the existing task API.
JSON command records retain `published:false` and `hardware_qualified:false`.
Recording failures fail the owned task; software stop notification is not a
physical stop. The retained actor/controller must outlive host cleanup.

The new fake-SDK tests assert that the native publication counter stays unchanged.
The standalone actual trained-actor smoke passes at
`output/e1-sdk-shadow-service-v1/report.json`, with synthetic calibration and
references and no hardware access. Do not reuse its generated fake-only session
as real calibration. Actual sensor semantics, NPU timing and robot behavior
remain unqualified.

## Tomorrow's hardware work

The [SDK 3.1 low-control transport](../../src/sdk_e1_low/README.mbt.md) is now
available separately from the high-level WALK/RUN bridge. The SDK 3.1 CMake
selection builds `moonrobo_e1_low`; its MoonBit package provides reusable raw
capture, SDK joint-name lookup and complete 24-slot commands. Actual-header,
fake-SDK C++ and MoonBit/native checks pass, including ASan/UBSan. It is not
wired to a physical actor sink. The separate
[explicit mapping](../../src/sdk_e1_policy/README.mbt.md) now converts actor-order
q/qd and complete24-slot position-PD commands using supplied calibration, with
ASan/UBSan fake-SDK evidence. It requires named axes, expected status IDs,
signs, zeros, gains and a full command for every non-actor motor; no hardware
values are supplied automatically. Resolve the actual23/24/29 correspondence,
calibration, gains, IMU conventions and qualified watchdog/stop/takeover first.
Install the low plugin with its sibling `moonrobo_e1_low_worker_v1`. The last
supervised handle's `close` terminates host publication and reaps the worker.
After the first publish the worker expires stale commands after 100 ms.
The robot-side disconnect response and timing need separate verification.

The mapping package now also has an explicit `ImuCalibration`/`Imu` and prepared
`Observer`. It converts SDK q/qd/quaternion/gyro into the actor's99 features
using saved feature scales. The deployed legacy actor uses velocity0.1 and
gyro0.25; physical gyro-unit conversion happens before these feature factors.
Supply verified quaternion order/direction, gyro frame/units, sensor-to-body
mounting and SDK-world-to-actor-world alignment, plus reference rotations in
that actor world. No numeric hardware calibration defaults are shipped.
The software comparisons and actual-header fake-SDK sanitizer path pass; see the
[sensor mapping contract](../../src/sdk_e1_policy/README.mbt.md). Retain actual
capture time and `Sample::age_ms` when composing runner inputs; observation
construction itself does not assert sensor freshness or publish motor commands.

The deployment-only [control composition](../../src/e1_actor_control/README.mbt.md)
now connects a borrowed controller/observer, selected actor, reference provider
and mapping to the existing runner. Publication and qualified stop behavior are
explicit callbacks. It timestamps samples conservatively from capture start
minus local receipt age minus1ms for SDK rounding, and prepares motor frames
before the final freshness/deadline checks. The caller schedules ticks and owns
the references and hardware integration. `target/sdk-e1-control-validation-v1/report.json`
passes actual-header fake-SDK ASan/UBSan through numerical inference and complete
mapped frames, with synthetic calibration. This adds no physical sink or motor
CLI and does not qualify real stop behavior or50Hz timing.

Prepared motion references are now separate deployment artifacts. With complete
matching prepared dataset assets, export a selected clip using the existing
training preview encoder, then inspect it without training dependencies:

```sh
moon run cmd/e1_train --release --target native -- export-lunakine-reference --dataset DATASET --bundle BUNDLE --clip-id CLIP_ID --split validation --output NEW_REFERENCE_JSON
moon run cmd/e1_actor --release --target native -- inspect-reference BUNDLE REFERENCE_JSON
```

The [reference reader](../../src/e1_actor_reference/README.mbt.md) supplies raw
preview goals and reference body rotations to the control callback. It checks
profile/joint order,20ms cadence, shapes and rotations once at load; the selected
reference ID must match the accepted task and parameters must be empty. The
final stored state reports completion after N-1 action ticks. No alignment,
time/amplitude transform or looping is implicit. Qualified motion quality and
alignment to the installed E1 still need separate acceptance. The export command
initializes no tensor backend, simulator or robot transport.

Record exact Atlas SoC/CANN/driver and Spark software identities; compile/load the
actor; compare actions against the retained LibTorch/ONNX fixtures; measure
transfer-inclusive repeated NPU latency. Compile the selected MiniCPM-V 4.7
text AOT modules, upload the actual weights through the resident executable,
complete its serving and vision work, and validate exact `sm121` execution,
logits, token IDs, generation,
stops and task quality. Confirm E1 SDK/firmware, motor mapping, signs, quaternion
and gyro frames, calibration, reference alignment, authority/stop integration and
the low-level command ABI before creating a physical output sink.

Existing high-level WALK/RUN publication is not a low-level actor-action adapter.
The present shadow service does not enable physical joint control.
