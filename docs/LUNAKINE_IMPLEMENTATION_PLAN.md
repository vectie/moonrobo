# LunaKine implementation phases

## Current record, 19 November 2026

The [E1 commissioning findings](E1_COMMISSIONING_FINDINGS.md) supersede earlier
statements below that no E1 sensor session or actuation had occurred. SDK
24-record decoding, shutdown isolation, January command compatibility and
supervised crane-supported deterministic elbow motions have since been tested.
The latest two-elbow retry completed; it is not a learned-actor physical test.
The [sanitized manifest](evidence/e1-commissioning-20261119.json) preserves the
run results/hashes, while the [runbook](../deploy/e1/README.md) documents the
portable sources and isolated tests.

Earlier phase reports below remain dated evidence, not current-state checks.
References into `output/` identify external local archives and are not shipped
reports. The later [workspace integration](WORKSPACE_INTEGRATION_20261119.md)
publishes MoonRobo's training and actor packages as well. LunaFlux and LunaKine
implementations remain in their independent sibling repositories.

Started 2026-11-17. Cluster access became available on 2026-11-17; the initial
software-only evidence below predates physical verification. The
[deployment architecture](LUNAKINE_DEPLOYMENT_PLAN.md) owns
the two-host placement and product boundaries.

## Physical host verification, 2026-11-17

The working cluster gateway uses SSH port **32123**. The `.179` Spark is
`192.168.2.179` (`wlc004s`); the actor host is `192.168.2.191` (`jiaanguo`).
Credentials stay outside repository configuration and evidence files.

| Host | Observed state | Acceptance status |
| --- | --- | --- |
| Spark `.179` | NVIDIA GB10, AArch64, Ubuntu24.04.2, driver580.178.04; CUDA13.0.88 compiler available at `/usr/local/cuda-13.0/bin/nvcc`. About108GiB memory available and1.5TiB disk free at initial inspection. | All nine modules compile/load; all sixteen checkpoint shards are verified. Four native text requests match upstream greedy output across34 sampled steps, including EOS. Real vision returns `Red`/`Blue`, then text reuse returns `ready`. Real JSON/SSE chat and two-host text/image planning to the NPU shadow actor pass. Measured logit differences, broader visual/planner quality, sustained serving and physical E1 acceptance remain open. |
| Atlas host `.191` | Ubuntu22.04.1, x86_64, kernel6.8.0-149; Atlas300V / Ascend310P3, `19e5:d500` at `0000:17:00.0`, healthOK. | Driver26.1.1, firmware9.0.0.9.220 and CANN9.1.0/310P ops verified after the authorized reboot. Actual FP32 actor passes 1,000 post-boot NPU calls; transfer-inclusive p99 is2.392ms. Physical E1 control and sustained timing qualification remain open. |

Spark deployment is isolated under
`/home/wlc004s/lunakine-deployment-20261117`: native source/build, nine CUBINs,
the hardware probe and the selected-model checkpoint destination. The exact
MiniCPM revision remains `98e79ba972b586ac6146d3505771ce1467e199ba`.
Direct Hugging Face access times out; the resumable deployment downloader can
use the pinned mirror or ModelScope transport. ModelScope payloads are checked
once against all sixteen SHA-256 values from the pinned Hugging Face manifest;
that acquisition scan is outside runtime startup and token execution.

The compiler compatibility fix preserves image normalization's FP64-to-FP32
conversion through `Float::from_double`, and replaces three removed `try?`
test expressions. The affected local processor/parallel suite passes42/42.
The separate ingress increment also adds EXIF orientation and corrects buffered
progressive-JPEG entropy consumption:126 orientation cases and72 full PNG cases
match the upstream reference;54 JPEG cases retain sampled channel error up to3.
Neither those CPU references nor the scatter probe qualify complete-model
numerics or robot control.

At initial inspection, the next steps were checkpoint acquisition and Spark
comparisons, Ascend stack selection/installation, ATC compilation and real NPU
measurements. Installation and subsequent reboot progress are recorded below.
No E1 actuation has occurred.
The older software-only entries below remain scoped to their original tests.

Installation update: the user authorized installing the Ascend stack and
selected CANN 9.1. The installed stack is CANN 9.1.0 with HDK 26.1.1 and matching
firmware 9.0.0.9.220, using Huawei's 310P compatibility/download guidance. The
earlier HDK25.5.2 attempt failed on a kernel `MIN` macro redefinition and was
uninstalled. The unmodified26.1.1 source builds with GCC12 for the existing
6.8.0-138 kernel and installs successfully without a reboot. `npu-smi` now
identified Atlas300V / Ascend310P3, logical device0, card5632, healthOK and
21,524MiB reported memory. The matching firmware upgrade succeeded and initially
required a reboot to activate. CANN 9.1.0 toolkit and 310P
operator installation both completed successfully under
`/home/jiaanguo/Ascend/cann-9.1.0`.

The actual trained actor compiles successfully for `Ascend310P3` with FP32 I/O
and `must_keep_origin_dtype`. LunaKine's real AscendCL runtime passes 1,000 calls
across the three saved input cases, checking all 29,000 output actions. Maximum
absolute error is `2.86102294921875e-6` against LibTorch and
`1.0967254638671875e-5` against the portable reference. After ten warm-up calls,
transfer-inclusive latency is 2.213 ms mean, 2.297 ms p99 and 2.462 ms maximum.
The runtime/session close successfully; `npu-smi` reports no remaining NPU
process and memory returns to its initial level. The local report is
[`actor-live-fp32-v1.json`](../output/lunakine-host-verification-20261117/actor-live-fp32-v1.json).
This first report predates the reboot and is sampled actor inference evidence.

Post-reboot update: an earlier external restart selected the already installed
6.8.0-149 kernel. The matching driver was installed through DKMS for that kernel.
After the user explicitly authorized rebooting, the host restarted at
2026-11-17 16:14:56 local time. The driver loads automatically, the card reports
healthOK, and the vendor upgrade tool confirms hboot1a, hboot1b and hlink at
9.0.0.9.220. The same 1,000-call/29,000-action comparison passes after startup
with unchanged numerical errors: mean2.333ms, p992.392ms and maximum2.445ms
including transfers. The session closes and no NPU process remains. See
[`actor-live-fp32-postboot-v2.json`](../output/lunakine-host-verification-20261117/actor-live-fp32-postboot-v2.json)
and `driver-dkms-149.log` in the same evidence directory. Firmware activation
and post-reboot actor acceptance are complete; sustained timing and physical
E1 control remain separate gates.

The deployment-only MoonRobo task service is now built and exercised on `.191`
with the actual NPU actor. HTTP admission, the shared live-clock runner,
recorded99-feature inputs and Ascend inference reach Completed, then stop and
close cleanly with no motor publication. The retained
[`atlas-actor-shadow-npu-v1/report.json`](../output/lunakine-host-verification-20261117/atlas-actor-shadow-npu-v1/report.json)
has `hardware_access:true` and `physical_timing_qualified:false`. Its source view
contains only eight actor/task packages and sibling LunaKine. An owned
moon0.1.20261012/moonc0.10.15 toolchain replaces the temporary compiler mount
that disappeared at reboot; it does not change the system-wide toolchain.

On Spark, the extended native text diagnostic completes four requests and
retains34 complete vocabulary logit rows, including EOS, for offline comparison.
The combined text/vision resident also runs real inference: two lossless448x448
square images produce `Red` and `Blue` for the same color question, then a
text-only request returns `ready` after clearing image state. Each image uses
64 feature rows and a108-token prompt. See `spark-native-logits-v2` and
`spark-native-vision-v1` under the host-evidence directory. These are sampled
GPU execution/grounding results, not broad visual or planner quality acceptance.
The first upstream reference loader exhausted host memory before inference;
the revised isolated reference loads CPU-backed weights then moves the same
70,425,751,904-byte model entirely to CUDA before computation. Reference
comparisons and real serving remain separate gates.

That upstream comparison has now completed on CUDA with unchanged
Transformers5.18.0/PyTorch2.14 eager model arithmetic. All four native generated
sequences and finish reasons match; all34 sampled argmax decisions, including
EOS, agree. The diagnostic compares8,436,896 finite logit values and records
maximum absolute difference1.53125. This is measured finite-precision behavior,
not numerical equivalence or broad task-quality acceptance. See
[`spark-native-upstream-text-v3.json`](../output/lunakine-host-verification-20261117/spark-native-upstream-text-v3.json).

Actual native `serve-media` also passes401 authentication rejection, buffered
text/image JSON, image SSE completion and text reuse; see
[`spark-live-http-v1/report.json`](../output/lunakine-host-verification-20261117/spark-live-http-v1/report.json).
The real coordinator on Spark then completes both text-only and image-assisted
planning through LAN task admission and the Ascend actor on Atlas. Both
recorded conversion-probe tasks reach Completed with no motor publication; see
[`two-host-report-v1.json`](../output/lunakine-host-verification-20261117/two-host-report-v1.json).
Temporary diagnostic listeners were stopped; both accelerators return to idle.

The user reports the E1 connected to the other Ethernet port and is preparing
the robot. Keep motor publication disabled while preparation continues. No SDK
initialization, sensor/control session or physical robot command was performed
by these diagnostics. Exact E1 addressing, SDK/firmware, calibration and
supervised physical acceptance remain unverified.

## Architecture and implementation rules

MoonRobo keeps LibTorch/CUDA training, export, motion/reference construction,
skill supervision, and E1 control. The new sibling `lunakine` repository owns
portable actor artifacts and native Ascend inference. LunaFlux targets flagship
**MiniCPM-V 4.7 35B-A3B** inference on Spark. The actor loop never waits for the
LLM/task connection. MiniCPM5-2B is a separate compatibility fixture, not the
selected deployment model.

Use small public packages for artifacts, offline conversion, execution, and
task coordination. Backend resources remain private to their implementation.
Keep interfaces about numeric inputs/outputs and typed skills, not vendor
handles or E1 SDK types. Start with one static actor and one compiled CANN model.
Extend at real variation points instead of building a universal graph compiler.

Validate shapes, numerical outputs, ownership, and request ordering where they
affect behavior. Avoid cryptographic admission layers, repeated payload scans,
generic policy engines, or multiple equivalent configuration representations.
Use existing MoonRobo authority and robot controls rather than inventing a
second approval system. New automation is MoonBit `.mbtx`.

## Phases and evidence

| Phase | Deliverables | Software verification | Hardware follow-up |
| --- | --- | --- | --- |
| 0 Contracts and repository | Create the local `lunakine` repo, public artifact/API contracts, and this phase ledger. | Native typecheck and example artifact validation. | Record the exact board/SoC, Spark build environment, and E1 SDK revision. |
| 1 Portable actor | Extract frozen weights and normalizers from existing MoonRobo E1 actor archives into a device-independent bundle. Include the real encoder/decoder, ELU/tanh, ordering, and action mask. | Fixture reference values, malformed-shape rejection, and comparisons with LibTorch when the local plugin is available. | Compare actual trained-checkpoint fixtures on Spark. |
| 2 Offline Ascend model | Emit a static ONNX actor and provide explicit ATC compilation tooling. Keep compiler dependencies outside the deployment process. | Parse exported ONNX with an independent tool and compare its output with the reference actor. | Compile for the 300V's reported SoC and measure numerical differences. |
| 3 LunaKine native runtime | Add an explicit prepare/run-into/close AscendCL backend, preallocated buffers, and a small inference CLI. | Test unavailable-library and load/execute/close behavior against a native test double; no CPU fallback presented as NPU execution. | Execute on the card, measure transfer-inclusive latency, memory, and repeated use. |
| 4 MoonRobo actor integration | Select LunaKine in an E1 inference/evaluation path independently of the training backend. Adapt portable actor outputs to existing E1 semantics. | Recorded/stubbed inputs and simulator comparisons where dependencies are available. | Run the same actor in CPU MuJoCo evaluation on the 300V host. |
| 5 Skills and task link | Typed skill catalog, bounded request parameters, reference selection, execution status, and an asynchronous Spark-facing task service. | Request/reply integration, duplicate/stale/expired handling, skill completion and transitions, and task-link loss without blocking actor ticks. | Bind task traffic to one host NIC and robot SDK/DDS to the other. |
| 6 Spark flagship model | Integrate MiniCPM-V 4.7 35B-A3B: exact hybrid MoE decoder, tokenizer/chat and vision encoder/processor; map proposals through the task coordinator boundary. Start with text requests to this same model, then visual inputs. | Model-format/tokenizer, state/attention/expert/vision checks and recorded planner-to-skill fixtures. | Verify exact `sm121` execution, numerical behavior, visual grounding, cancellation, and resource/latency budgets. |
| 7 E1 runner | Local observation/history/reference loop, action conversion, explicit SDK adapter, shadow mode, and existing stop/takeover integration. | Recorded telemetry and device stubs exercise the real runner path without enabling motor control. | Verify exact SDK/firmware, timing, fallback semantics, then supervised physical trials. |
| 8 Deployment | Host configuration examples, commands, compatibility matrix, and operations documentation. | Reproduce export and software integration from documented commands. | Full two-host acceptance under task traffic/disconnects and sustained E1 execution. |

Phases 1–4 form the actor path. Skills/task-link work can proceed independently
of the model-specific LunaFlux implementation after its contracts are defined.
Hardware follow-up remains explicit pending work, not a prerequisite for writing
or testing the corresponding software.

## Current progress

| Phase | Current evidence | Remaining work |
| --- | --- | --- |
| 0 | Local `/Users/kq/Workspace/lunakine` Git repository created with module, package ownership, and runtime contracts. | Pin hardware/software identities when supplied. |
| 1 | Existing trained 9,116,477-parameter E1 actor exported to portable FP32 weights, specification, and robot companion. Three-input LibTorch/reference comparison passed with maximum absolute action error `8.106231689453125e-6`. | Additional recorded trajectories and target precision comparisons. |
| 2 | Framework-free ONNX exporter and independent CPU comparison pass. Actual CANN 9.1.0 ATC compilation for Ascend310P3 succeeds with FP32 I/O and `must_keep_origin_dtype`. | Additional recorded trajectories and precision profiles as needed. |
| 3 | Native AscendCL runtime and real trained actor pass 1,000 post-reboot NPU calls and 29,000 action comparisons: maximum LibTorch error `2.86102294921875e-6`, transfer-inclusive p99 2.392 ms. Resources close and the device returns to idle. Firmware activation is confirmed. Local ABI/ASan evidence remains scoped below. | Longer sustained resource/timing measurements and physical E1 qualification. |
| 4 | MoonRobo export/comparison commands and explicit LunaKine/portable-reference loaders implemented. The new deployment-only `e1_actor` package/CLI imports no trainer or LibTorch; the existing evaluation loaders delegate to it. Full-clip evaluator accepts a backend-independent predictor. Real trained-actor adapter/replay comparison passes after extraction. | Full simulator comparison on complete matching assets and actual NPU backend. |
| 5 | Typed skill supervisor, HTTP client/server, planner adapter and local runner implemented. Twenty focused tests pass with warnings denied. Text and labeled PNG/JPEG snapshots share completed-proposal, context recheck, execution TTL and exact UTF-8 framing rules. `plan-images` and the release CLI are implemented. A real cross-repository client -> LunaFlux HTTP/media/native plumbing -> task supervisor smoke accepts the expected reference with scripted model tokens and clean model teardown. | Real model output quality, evaluated references, camera capture/calibration and observed robot outcomes. |
| 6 | All1,152 BF16 bindings and the actual checkpoint are prepared. Nine CUDA modules compile/load on sm_121. Text residency uses69.47GB explicit payload; combined vision/text uses71.01GB before driver/module overhead. Request owners handle chunked prefill, positions, stops, cancellation and cleanup; diagnostic logit readbacks stay outside production execution. Four real text requests match upstream greedy output across34 sampled steps, with maximum measured logit difference1.53125. Real vision, text reuse, JSON/SSE chat and two-host text/image planning to the NPU shadow actor pass. Independent tokenizer/template/canvas/processor and earlier583/583 native/protocol evidence retain their recorded scopes. | Investigate finite-precision differences; broaden visual/planner quality and sustained serving/resource validation. Physical robot acceptance is separate. |
| 7 | Local synchronous tick owns history/previous actions, deadlines, completion and stop. Shared `e1_actor_shadow` replay/task service imports no trainer or simulator; old training commands are compatibility wrappers. The standalone deployment service completes actual portable-actor tasks through real HTTP. Raw SDK3.1 transport, joint/IMU conversion and saved-contract99-feature preparation are composed with the actor, mapped24-slot commands and explicit publication/stop callbacks. Conservative receipt timestamps include capture/feature work; actual-header fake-SDK native checks pass. | Actual motor/IMU calibration, qualified gains/limits and reference alignment, physical publication/authority/stop/watchdog integration, target scheduling/timing and exact-SDK hardware qualification. |
| 8 | [Two-host runbook](../deploy/lunakine/README.md), examples and software commands exist. Atlas driver26.1.1, firmware9.0.0.9.220, CANN9.1.0/310P ops and real actor inference pass after reboot. Spark native text/vision, sampled upstream comparison, JSON/SSE serving and two-host text/image planning to recorded NPU shadow execution pass. | Broader numerical/visual/planner quality, sustained deployment behavior and physical E1 acceptance after robot preparation. |

The ABI fixture deliberately reverses model input order and counts every native
resource. It exercises the real loader/execute/cleanup code through a software
test library. It is not a model implementation or evidence of NPU support.

Reports from the real actor comparison are in
`output/lunakine-software-20261117/comparison.json` and
`output/lunakine-software-20261117/onnx-comparison.json`. The original actor is
`output/e1-arm-finetune-20261115/train/evaluation-100/actor`; this validates
conversion behavior, not the policy's physical quality.

Hardware access, NPU measurements, Spark model execution, and physical robot
trials are deferred until hardware is supplied; software work continues.

Phase 6 vision preparation now has its own LunaFlux package for decoded RGB8:
thumbnail/detail slicing, visual framing, canvas grids, PIL-profile resize,
normalization and BF16 NaViT packing. The focused processor/position/tokenizer
suite passes 18/18, including the actual flagship tokenizer. A separate offline
Pillow12 C resize oracle matches 12,305,664 BF16 pixel words across five image
cases. This adds no Python production dependency and does not change the actor
loop. Native vision execution, embedding insertion and combined residency
are implemented below. Real GPU execution, media serving and full upstream
processor/position comparison remain pending; see the
[LunaFlux processor guide](../../lunaflux/model/minicpm_v47_processor/README.mbt.md).

The next phase6 increment prepares the complete vision encoder AOT program:
318 stages/25 entrypoints, with all459 vision tensors joined to actual headers.
It includes crop-isolated head72 attention, early window compression and the
final MLP projector. Focused tests pass115/115; existing primitive reuse tests
pass10/10. A CPU-only probe of generated source passes ASan/UBSan; it is not
NVCC or GPU evidence. v16 preparation now contains eight source modules/63
entrypoints while preserving all seven text source files. Native vision
weight/frame ownership and independent execution are now implemented: the
scripted driver uploads exactly1,105,972,064 sparse-zero bytes into459 final
allocations, exercises318-stage16x/305-stage4x frames and balances resources.
Queue replay allocates no heap/native resources; input submission uses13/10
copies and no readback. Failure/reuse, cancellation, partial startup and active
close pass. Generated-C/four-stub ASan also passes with prebuilt runtime/mimalloc
retained and leaks disabled. v17 records the new owners with all eight CUDA
sources unchanged. Media serving remains pending; the native feature/prompt
bridge and combined image-capable residency are implemented below. See the
[vision program guide](../../lunaflux/integration/minicpm_v47_vision/README.mbt.md).

The feature/prompt bridge now connects vision output to the full decoder:
typed image/native-token prompts, multiple-image NaViT packing, canvas positions
and causal feature mapping feed one BF16 insertion after token embedding.
Prefill has925 launches; decode remains924. Two mapping uploads per request
leave feature rows on device and add no request-step transfers. The50-test
affected suite, scripted native chunk/decode/cancel/reuse checks and ASan smoke
pass (prebuilt runtime/mimalloc retained, leaks disabled). A separate generated
source ASan/UBSan CPU probe checks raw word copying; no GPU arithmetic is
qualified. v18 prepares nine source modules/64 entrypoints with the prior eight
unchanged. Combined model residency and local media execution are implemented
below; actual upstream/device numerical/quality checks remain pending; see the
[bridge guide](../../lunaflux/integration/minicpm_v47_multimodal/README.mbt.md).

The combined LunaFlux image runtime now composes both weight loaders, native
vision, feature insertion and the full decoder request driver. It loads nine
AOT modules and shares the decoder module owner with the text runtime.
Asynchronous vision completion precedes feature binding and decoder submission;
image storage cannot be reused while its decoder request is pending. Text reuse,
cancel/failure recovery and active close are covered. Startup prepares both
branches from one config/tokenizer/header inspection and reuses bounded upload
scratch. The complete planned allocation payload is 71,008,215,248 bytes at
16,384 raw patches, before driver/module/queue overhead. The affected suite
passes 63/63 with actual tokenizer assets; native scripted and generated-C ASan
checks pass, retaining prebuilt runtime/mimalloc with leaks disabled and balanced
native resource counters. These are software ownership/ordering checks, not
model arithmetic or a full checkpoint upload. v19 records combined residency
with all nine v18 CUDA sources unchanged and a nine-command AOT dry run.
Local PNG/JPEG media and buffered HTTP images are now implemented below;
actual Spark/NVCC/upstream numerical/quality acceptance remains pending. See the
[image runtime guide](../../lunaflux/integration/minicpm_v47_image_runtime/README.mbt.md).

LunaFlux now accepts local PNG/JPEG queues through `inspect-media`/`run-media`.
The RGB8 boundary also accepts direct camera frames; one model-owned preparer
derives image plans, prompt, crop layout and packed pixels together. No-GPU
inspection passes with actual config/tokenizer/headers and labelled sparse-zero
shards. The example prepares two images into 2,080 raw patches/130 feature rows
and a 180-token prompt, then a text request. The affected suite passes 45/45;
native scripted and generated-C ASan checks continue through decoder EOS and
text reuse with zero-allocation token steps. A separate decoder ASan/UBSan probe
covers known PNG/JPEG conversions and truncated prefixes with balanced codec
allocation counters. Leak detection remains disabled; the prebuilt MoonBit
runtime/mimalloc is retained in the full native fixture. No GPU model arithmetic,
full checkpoint upload or visual grounding is qualified. Metadata transform
parity, video/E1 camera SDK adapters and actual Spark acceptance remain
pending. See the [media executable](../../lunaflux/cmd/minicpm_v47_generate/README.md).

Buffered inline image chat is now wired through LunaFlux `serve-media`. PNG/JPEG
data URIs normalize into the same typed media preparer and native placeholders;
the canonical admission parser still validates generation controls while
retaining the authenticated source HTTP lease. Text/image replies share UTF-8,
stops and usage, with a 16 MiB full-body ceiling. The affected suite passes
98/98 with actual tokenizer assets. Native loopback and generated-C/five-object
ASan check image replies/usage, no-system text reuse, 401/400/429, enqueue
failure/recovery and timeout/disconnect during pending vision. Native resources
balance; prebuilt runtime/mimalloc is retained and leak detection disabled.
The allocation-driver regression and release CLI build pass. Actual model
arithmetic, full checkpoint upload, Spark serving and visual quality remain
unverified. E1 camera/video SDK ingress and metadata-transform parity remain
follow-ups. Training and robot control stay in MoonRobo; the actor tick remains
independent of LLM/media work.

MoonRobo's planner now accepts labeled immutable PNG/JPEG snapshots and exposes
`plan-images`. It sends ordered inline image parts to `serve-media` without a
LunaFlux runtime or camera/actor SDK dependency. Text-only callers keep their
existing request shape. Exact UTF-8 framing, header preservation, completed
proposal validation, context recheck and post-planning execution TTL are retained.
The planner/task/skills/runner suite passes 11/11 with warnings denied; the
release CLI builds. Camera capture timing/calibration and live grounding remain
hardware follow-ups.

The cross-repository MoonBit smoke runs the real MoonRobo image planner/client,
the real LunaFlux HTTP/media/request plumbing with a scripted sampled-token
sequence, and the real standalone task supervisor. Two PNG/JPEG observations
produced an accepted `fixture` proposal for reference `probe-frames`. The model
fixture exited successfully with all native resources closed. Reports are in
`output/lunakine-visual-planner-smoke-v2/report.json` and `accepted.json`.
LunaFlux's generated-C/five-native-object ASan and original driver allocation
regression also pass for the bounded multi-token test hook, with prebuilt
runtime/mimalloc retained and leak detection disabled. This proves the software
boundary crossing and cleanup; no model arithmetic, GPU, actor writer or
physical robot execution is involved.

Reproduce from MoonRobo:

```sh
moon run scripts/test_lunakine_visual_planner.mbtx /absolute/moonrobo /absolute/lunaflux ACTUAL_MINICPM_ASSETS NEW_OUTPUT
```

## Reproduction commands

From MoonRobo, with the existing native tensor plugin and an exported E1 actor:

```sh
moon run cmd/e1_train --target native -- export-lunakine --actor SOURCE_ACTOR --tensor-library LIBTORCH_PLUGIN --output NEW_BUNDLE
moon run cmd/e1_train --target native -- compare-lunakine --actor SOURCE_ACTOR --tensor-library LIBTORCH_PLUGIN --bundle NEW_BUNDLE --output NEW_COMPARISON.json
moon run cmd/e1_train --target native -- evaluate-portable --bundle NEW_BUNDLE --dataset MATCHING_DATASET --library MUJOCO_LIBRARY --output NEW_REPORT.json
moon run cmd/e1_train --target native -- evaluate-lunakine --bundle NEW_BUNDLE --ascend-library LIBASCENDCL --model COMPILED_ACTOR.om --dataset MATCHING_DATASET --library MUJOCO_LIBRARY --output NEW_REPORT.json
```

The native command currently links the existing physics adapter; use the
matching MuJoCo include directory through `CPATH` when building. Portable
reference evaluation is an explicit offline choice, never a fallback for a
missing NPU. LibTorch is loaded only by source-actor conversion/comparison and
the existing LibTorch evaluation path.

From LunaKine, independent ONNX verification uses the third-party Polygraphy
CLI and ONNX Runtime; automation and data preparation are MoonBit:

```sh
moon run scripts/verify_onnx.mbtx prepare COMPARISON.json NEW_INPUTS.json
polygraphy run BUNDLE/actor.onnx --onnxrt --load-inputs NEW_INPUTS.json --save-outputs NEW_OUTPUTS.json
moon run scripts/verify_onnx.mbtx check COMPARISON.json NEW_OUTPUTS.json NEW_ONNX_REPORT.json
moon run scripts/test_ascend_abi.mbtx /absolute/path/lunakine
moon run scripts/test_ascend_asan.mbtx /absolute/path/lunakine
```

Local verification used ONNX `1.23.2`, ONNX Runtime `1.32.0`, and Polygraphy
`0.53.6` in LunaKine's ignored `target/validation-py312` environment. These are
offline validation tools, not production dependencies.

Update this ledger with actual commands and results as phases advance. Keep
the full objective open until both software and required hardware acceptance
have evidence. Passing a local fixture does not close a hardware phase.

## Completion audit and remaining gates

The selected model's complete canvas sequences now have independent CPU
comparison against unchanged Transformers 5.18.0 methods. All 154 unpadded
batch-one cases match 751,830 prompt coordinates, 1,848 decode coordinates, every
rope delta and 32-row prompt staging across adjacent/separate mixed image/video
frames, detail slices, six processor-derived image geometries and 4x/16x modes.
The report is `lunaflux/target/minicpm-v47-canvas-upstream-v2/comparison/report.json`
in the sibling repository. The reference is an offline C++/CPython adapter using
Torch 2.9.1; method extraction/corpus/comparison remain MoonBit and no production
dependency is added. Crop grids are shared inputs: independent processor geometry/
pixel parity, batched padding, physical GPU execution and model quality remain open.

The local runner now owns one injected, nondecreasing clock and exposes
`tick()` without a separate timestamp argument. It rechecks execution ownership,
deadline and telemetry after reference preparation and prediction, before the
sink. A pre-fix regression reproduced publication after cancellation; the 20
focused planner/task/skills/runner tests now pass with warnings denied, including
deadline boundaries, stale results, replacement ownership and original-failure
preservation during cleanup. Deterministic replay advances its local clock;
the shadow task service shares its live host clock with the runner.

The real trained LibTorch/portable actor replay and frozen-contract tests pass
2/2 with existing training dependency warnings. That run exposed an earlier
wording edit to the versioned native archive contract: its `runtime` text must
remain frozen for v1/v2 artifact compatibility. The field is restored, without
changing saved actors or weakening identity/archive checks; the separate portable/
ONNX exporter stays documented outside that historical tag. The test's temporary
export is now removed on exit.

The real portable actor also completes recorded frames through the task HTTP
service with the live clock at `output/lunakine-actor-clock-v2/report.json`,
with `published=false`. The CLI build passes with baseline warnings. These
checks suppress late publication after a call returns; they do not interrupt
blocked native calls or qualify an independent device watchdog, actual sensor
freshness, NPU timing or physical stop behavior.

Phase7 now has a separate [SDK 3.1 low-control transport](../src/sdk_e1_low/README.mbt.md):
coherent raw status, SDK joint-name lookup and complete 24-slot motor frames,
with private native handles and reusable capture/command buffers. It imports no
training/model/LunaKine package and does not infer the actor's 23/29-channel
mapping, gains, IMU convention or stop command. The C++ API fixture and real
MoonBit dynamic-loader/buffer path pass with actual SDK headers and fake
controller methods. Both C++ and generated MoonBit C/loader/fake-plugin paths
pass ASan/UBSan (prebuilt Moon runtime/mimalloc retained, leak detection disabled
for that run). The report is `target/sdk-e1-low-validation-v1/report.json`.
High/low adapters now share a private SDK-status codec with separate state;
the high-level ASan/UBSan regression also passes at
`target/sdk-e1-v31-validation-v2/report.json`. No vendor library was loaded,
DDS connection opened or live motor CLI added. Target plugin linking, calibrated
actor composition, timing, watchdog and stop/takeover acceptance remain open.

Deployment inference is now extracted into
[`src/e1_actor`](../src/e1_actor/README.mbt.md), with no training, LibTorch,
CUDA, simulator or SDK imports. The training/evaluation loaders delegate
numerical execution to it while preserving their existing public APIs and
archive/bundle formats. Its standalone `cmd/e1_actor` inspects or explicitly
executes the portable reference/Ascend backend, producing actions and nominal
positions with `published=false`. The actual trained bundle passes the CLI smoke
at `output/e1-actor-deployment-v2/report.json`; its recorded source dependency
closures prove that actor and mapping paths import no trainer. The existing
three-input LibTorch/reference and three-frame runner comparison also passes
after delegation (`target/e1-actor-extraction-trained-comparison.log`), with
baseline training dependency warnings retained. The subsequent shared shadow
extraction below also removes training/simulator imports from task-driven replay.

[`src/e1_actor_shadow`](../src/e1_actor_shadow/README.mbt.md) now owns recorded
replay and task HTTP execution. Its borrowed policy view accepts the selected
deployment actor or the offline LibTorch comparison, without importing training
code. Existing training APIs and `ActorReplay`/`ActorReplayFrame` construction/
JSON methods remain available through compatibility wrappers/reexports; the
external alias test passes. `cmd/e1_actor` now provides reference/Ascend recorded
replay and task-service modes. The focused runner/task/skills/shadow suite passes
17/17, and the actual trained LibTorch/reference plus three-frame replay still
passes (`target/e1-shadow-extraction-trained-comparison.log`, existing dependency
warnings retained). The standalone deployment CLI's source graph passes at
`output/e1-actor-deployment-v3/report.json`; the real task HTTP service completes
the actual portable actor at `output/e1-actor-shadow-service-v1/report.json`.
Recorded-feature completion is shadow-only (`published=false`), not live sensor
freshness,50Hz hardware timing or robot task success. Physical reference/control
composition and target execution remain open.

[`src/sdk_e1_policy`](../src/sdk_e1_policy/README.mbt.md) now binds actor joint
names to resolved SDK slots using explicit expected status IDs, signs, zeros and
gains. Every actor axis and all24 SDK slots must be covered; extra physical
motors require full explicit commands. It converts raw status to actor-order
q/qd and nominal actor positions to complete SDK position-PD frames, without
initializing or publishing to a controller. Pure23/24-axis and rejection tests
pass. The real MoonBit loader/borrowed-buffer path plus actual-header fake SDK
passes ASan/UBSan for reversed slots, signs/zeros/gains, explicit extra motors,
full-frame publication, wrong-ID/error rejection and recovery:
`target/sdk-e1-policy-validation-v1/report.json`. The fixture calibration is
synthetic; no vendor SDK, DDS, accelerator or robot was accessed. Physical
calibration, IMU/reference construction, authority/limits/watchdog/stop and
deployment control-loop composition remain open.

The sensor-to-actor feature path is now implemented in the same deployment-only
packages. `Bundle::smc_observation()` prepares the saved feature contract once;
the actual deployed actor declares joint-velocity scale0.1 and body-gyro
scale0.25, so current profile defaults must not replace its trained inputs.
Missing metadata does not select guessed scales. `sdk_e1_policy.Imu` requires
explicit quaternion order/direction, gyro frame/units, mounting rotation and
world alignment. `Observer` composes raw coherent SDK status, calibrated joint/
attitude conversion and all99 unnormalized SMC features. It initializes no SDK
and stamps no freshness/physical-success claim.

All27 affected actor/SDK/shadow/runner/task tests pass with warnings denied
(`target/e1-sensor-adapter-focused-test.log`). Twelve analytic noncommuting IMU
cases cover both quaternion orders/directions and all three gyro frames. The
independent training-geometry/profile comparison matches3,168 feature values
across32 poses/profiles/legacy-current cases within1e-12
(`target/e1-observation-training-parity.log`, existing training dependency
warnings retained). The actual-header fake-SDK/real MoonBit loader path passes
ASan/UBSan through raw motors/quaternion/gyro -> calibrated99-feature observation
(`target/sdk-e1-sensor-validation-v1/report.json` and `.log`, prebuilt runtime/
mimalloc retained and leak detection disabled for the MoonBit run). Calibration
is synthetic; real IMU/joint conventions, references, capture-age integration,
control authority/limits/watchdog and physical/NPU timing remain unqualified.

[`src/e1_actor_control`](../src/e1_actor_control/README.mbt.md) now composes
the existing runner with a borrowed actor, prepared sensor/observer, reference
provider and joint mapping. It adds no execution engine or training dependency.
The caller supplies publication and stop callbacks. Command projection runs
before the runner's final ownership/deadline/freshness check. Completion still
requires a fresh capture; the next task resets history and previous actions.

SDK age is floor-rounded time since a local callback, not sensor acquisition.
The sensor adapter uses `capture_start - receipt_age - 1ms`, so capture/feature
cost and rounding cannot make old input appear fresh. One shared clock guard
covers runner and capture reads. Four new tests include delayed capture at the
exact freshness boundary, errors/rollback, completion and profile mismatch.
All31 affected tests pass with warnings denied
(`target/e1-control-composition-focused-test.log`). The composed actual-header
fake-SDK fixture passes C++ and generated MoonBit C/loader ASan/UBSan at
`target/sdk-e1-control-validation-v1/report.json`; prebuilt runtime/mimalloc is
retained and leak detection disabled for that MoonBit run. Its actor performs
real reference arithmetic with synthetic weights and calibration; publication
targets only the fake SDK and stop is a counted callback. The actual trained
actor's separate deployment smoke records the control source dependency closure
at `output/e1-actor-deployment-v5/report.json`. This proves software composition,
not trained-policy quality, physical stop,50Hz timing or target SDK/NPU execution.
Qualified reference construction, hardware limits/authority/watchdog and physical
publication remain host integration work.

Prepared references now cross an explicit artifact boundary through
[`src/e1_actor_reference`](../src/e1_actor_reference/README.mbt.md).
`export-lunakine-reference` uses the existing training `MotionLibrary::goal`
encoder, rather than duplicating preview geometry in deployment. The artifact
contains raw73-per-future-frame goals, current reference body rotation, exact
profile/joint order and20ms cadence. The deployment-only reader validates once,
selects the accepted reference ID, rejects unsupported parameters, and reports
completion at the terminal state (N states -> N-1 action ticks). It does not
transform alignment, speed or amplitude or qualify a physical skill.

The independent deployment reader round trip preserves25,696 training goal
values within1e-12 across23/24-axis profiles, both existing heading encodings,
1/10-frame previews and two different clip lengths. File export/selection and
overwrite refusal also pass on synthetic dataset/asset identity fixtures:
`target/e1-prepared-reference-training-parity-v2.log` (2 tests, existing training
dependency warnings retained). The focused deployment suite passes34/34 with
warnings denied (`target/e1-prepared-reference-focused-test.log`). The updated
actual-header fake-SDK fixture uses the prepared reader in its numerical actor/
command path and passes ASan/UBSan at
`target/sdk-e1-reference-validation-v1/report.json` (same prebuilt runtime and
leak-detection scope). The standalone actual trained-actor smoke and synthetic
reference inspection pass at `output/e1-actor-deployment-v6/report.json`; source
closures exclude training/simulation packages. No real dataset motion was
exported or robot motion accepted by these synthetic fixtures. Complete matching
assets, qualified references/world alignment, target scheduling and physical
control acceptance remain open.

The shared [`src/policy_host`](../src/policy_host/README.mbt.md) now owns the
existing HTTP task service and control cadence for shadow and composed E1
runners. Its preparation factory receives one supervisor/clock pair, preserving
the local admission/capture/deadline time domain. This extraction also fixes a
shadow scheduling gap: the old overrun branch yielded into an immediate second
tick; the shared cadence discards missed slots and waits a full period after
slow synchronous work. No catch-up burst is issued. `Runner::interrupt` retires
only the owned execution, preserves a newer replacement and calls the supplied
stop callback once. Host cooperative cancellation/error uses that cleanup while
preserving original callback errors.

All40 deployment/host/runner/task/reference/SDK conversion tests pass with
warnings denied (`target/e1-shared-host-deployment-tests.log`). Deterministic
cadence tests cover normal slots, exact-boundary/long overruns and invalid time.
Actual HTTP tests complete after the submitter disconnects, continue ticks
through an incomplete request body, and check state, cancellation and original
inference-error cleanup. The E1 HTTP integration adds prepared references,
synthetic features, numerical actor execution and complete mapped24-slot command
callbacks. The actual trained portable actor's shadow HTTP smoke passes at
`output/e1-shared-host-shadow-v1/report.json`, and the deployment CLI/source
closure smoke at `output/e1-actor-deployment-v7/report.json`. This is software
host/lifecycle evidence; it does not prove50Hz target timing, physical stopping
or real SDK/NPU execution. A synchronous vendor call still blocks the event loop
and requires separate watchdog/stop integration. No physical sink was added.

The deployment now also has an explicit
[`src/e1_actor_sdk_shadow`](../src/e1_actor_sdk_shadow/README.mbt.md) preparation
owner and separate `cmd/e1_sdk_shadow` executable. A session selects the typed
catalog, full joint/IMU calibration, prepared references and receipt-age budget.
The CLI reads configuration/references before explicitly opening the selected
SDK/DDS, then uses actual SDK captures through calibrated99 features, the
selected numerical actor and complete mapped command records. Its callback
records JSON only; no `Controller::publish` call or physical stop is installed.
The original actor CLI remains SDK-free. The explicit Ascend command retains
normal CANN/model selection and no fallback; only the portable reference was
executed in this software validation.

The focused SDK-shadow file/HTTP tests pass2/2 with warnings denied and the
actual-header fake SDK (`target/e1-sdk-shadow-test-v2.log`). They verify complete
mapped records, completion and recording-failure cleanup while the native
publication counter remains unchanged. The standalone CLI also completes the
actual trained portable actor through the fake SDK and real task HTTP, recording
two frames and one software stop notification:
`output/e1-sdk-shadow-service-v1/report.json`. Calibration/references and the
fixture-only status injection are synthetic; no vendor SDK, accelerator or robot
was accessed. This prepares sensor qualification software, not physical control,
calibration, learned-policy quality or real NPU/timing acceptance.

All42 focused deployment tests pass with warnings denied and the fake-SDK
environment enabled (`target/e1-sdk-shadow-deployment-tests.log`; the older
optional bundle-only test hooks remain unset, while the standalone trained-actor
smoke above runs the real bundle). The source boundary smoke at
`output/e1-actor-deployment-v8/report.json` checks both CLI closures: neither
imports training/simulation, and the original actor CLI additionally rejects
SDK/control imports. The separate SDK-shadow closure deliberately includes the
SDK sensor/control adapters.

An SDK source audit found and fixed a control-bridge compatibility gap: the local
`../sdk` checkout at `3055bdc644f61caf948d935ee274c5c48703c24f` declares SDK 3.1.0,
namespace `noetix`, callback-based status and prebuilt `noetix_e1_sdk` libraries.
The original adapter uses the older `legged` getter/source-library layout. A
separate `sdk_adapter_v31.cpp`, explicitly selected by
`MOONROBO_E1_SDK_API=3.1`, now preserves the existing MoonRobo C ABI while using
the callback API. It copies coherent status, reports local callback receipt age,
and maps bridge DEFAULT code12 to the SDK's DEFAULT enum14 instead of TAIJI12.
The actual-header/fake-SDK fixture passes ASan/UBSan and warning-denied C++
compilation; its report is `target/sdk-e1-v31-validation-v1/report.json`.
Both existing MoonBit bridge tests pass with baseline warnings; a strict run
still rejects existing core deprecations/ambiguous-brace warnings. CMake target
configuration succeeds against actual Arm64 SDK library paths and installed
Eigen headers, but uses AppleClang/static probes and proves no Linux link.
No real SDK library was loaded and the SDK checkout remains unchanged. The
legacy adapter remains available. This is the high-level bridge; the actor's
low-level joint/calibration/authority mapping remains separate work.

The selected checkpoint's Jinja template now has an independent offline
comparison for the supported optional-system/user profile. It reproduced a
Unicode/control-whitespace mismatch, now fixed by a model-owned trim rule shared
by native prompts and both HTTP services. All 128 cases pass (24,870 compared
bytes), including absent/empty system messages and string/text-list content.
The report is `lunaflux/target/minicpm-v47-chat-template-final/report.json`.
The 70 affected tests and native ASan fixture pass, including actual-tokenizer
HTTP usage for Unicode-trimmed strings/lists and no-system requests. The fixture
still scripts model tokens; ASan retains the prebuilt runtime/mimalloc with
leak detection disabled and explicit native resources balanced. Jinja/Python are
offline test dependencies only. Actual model/device execution remains open.

The independent flagship tokenizer check now passes 1,797 distinct input strings
and 28,043 token IDs against Hugging Face tokenizers 0.23.2, with decoded text also
matching. It uses the actual selected tokenizer assets and includes multilingual
instructions, NFC/combining marks, digits, whitespace, model markers, skill JSON
and rendered text/image prompts. The report is
`lunaflux/target/minicpm-v47-tokenizer-upstream-v2/report.json` in the sibling
repository. The upstream library is used only by an isolated offline reference;
production LunaFlux remains MoonBit-native. The separate Jinja comparison above
covers the initial chat profile; actual model logits remain unverified.

The next software numerical audit found and fixed a canvas-position defect in
the selected MiniCPM path: exact rational rounding can differ from upstream's
FP32 linspace rounding. The separate native ATen 2.9.1 CPU oracle reproduced the
old mismatch, then matched 533,500 coordinates across 8,196 cases through the
public prompt-position API on both spatial axes after the fix. The report is
`lunaflux/target/minicpm-v47-positions-aten-final/report.json` in the
sibling repository. The affected suite passes 23/23 with the pinned tokenizer
assets and existing warning policy. LibTorch remains an offline test dependency
only. The separate full-canvas comparison above covers unpadded grouping;
batched padding and CUDA/Spark execution remain open. The separate full PIL
pipeline comparison below now covers sampled processor geometry/pixels.

The selected PIL image profile now has an independent full upstream pipeline
comparison in addition to its existing Pillow resize-kernel reference. It
executes unchanged Transformers5.18.0 processor geometry, `_preprocess`, backend
and transform methods with Pillow12/NumPy, then casts the reference pixels with
CPU Torch. Twelve cases match all22,682,688 BF16 words, slice grids, target
sizes, crop counts and output shapes. Cases include the448-area slicing
boundary, portrait/landscape layouts, a ten-crop input and slice limits1/2/7/9.
The report is
`lunaflux/target/minicpm-v47-pil-pipeline-v2/comparison/report.json` in the
sibling repository. Reference extraction, corpus and comparison are MoonBit;
Python/Torch remain offline dependencies. No production change was required.
This does not establish torchvision-profile or codec parity, video handling,
actual CUDA execution, full-model logits or visual grounding.

Phase6 now implements HTTP token streaming for both text and inline PNG/JPEG
requests through the existing JSON/SSE renderer. Model-owned admission selects
delivery once before emitting canonical events; the shared transport retains
request credit, deadline/disconnect cancellation and bounded awaited writes.
The transport test receives UTF-8 token content while completion is held by the
client, then checks terminal tails/usage, stop/length/error, post-header timeout,
disconnect and later JSON reuse. All67 affected tests pass:
`lunaflux/target/minicpm-v47-streaming-focused-test.log`. The actual-tokenizer
native fixture passes AddressSanitizer for both delivery modes, including
disconnect after Accepted while vision is pending:
`lunaflux/target/minicpm-v47-streaming-native-asan-v2.log`. That run instruments
generated MoonBit C, codec and fake-driver objects, retains the prebuilt
runtime/mimalloc and disables leak detection; explicit native resources balance.
The driver still scripts sampled IDs and computes no model arithmetic.
MoonRobo's planner keeps buffered complete proposals; interactive SSE deltas
never become actor commands. Continuous batching, real checkpoint serving and
Spark numerical/quality/performance acceptance remain open.

The requested end state is **not yet proven**. The following audit distinguishes
working software paths from acceptance still requiring target tools, assets or
the supplied devices; the full objective remains open.

| Requirement | Current authoritative evidence | Still unverified or missing |
| --- | --- | --- |
| Separate runtime/product boundaries | LunaKine has its own Git/module root and imports neither MoonRobo nor LunaFlux. Its generated Ascend interface now exposes only Runtime/Session, with both native handle types private. | Installed target component/version matrix. |
| Preserve LibTorch/CUDA training | `src/learning_e1_training/train.mbt` still opens the tensor backend and selects explicit CUDA precision controls. Native training-package typecheck and trained replay pass with existing dependency warnings. The v1/v2 archive contract stays frozen; separate portable/ONNX export is documented outside that compatibility tag. | This audit did not run CUDA training. The strict warning gate still rejects existing dependency deprecations; no module-wide warning policy was changed. |
| Portable actor and static ONNX | Actual actor/LibTorch and independent ONNX Runtime CPU reports pass on three input sets; exact reports are listed above. | Full matching simulator trajectories, target precision and physical policy quality. |
| Ascend actor execution | Current actor tests pass 3/3 and explicit software AscendCL ABI tests pass 3/3 after the visibility fix. Public run-into/close APIs remain unchanged. | Exact 300V SoC/CANN, ATC output, real NPU numerics, timing and sustained execution. |
| Spark selected-model implementation | Exact selected config/tokenizer/tensor headers, native decoder/vision/media/request owners and real protocol plumbing exist. Nine CUDA modules/64 entrypoints compile and load. The full checkpoint is acquired and its native text resident produces `ready` and `4` for the first two requests. Scripted native and sanitizer checks are documented above. | Upstream numerical parity, visual grounding, real HTTP serving and performance. |
| Planner/skills integration | Twenty focused tests and the real cross-repository software smoke accept the expected bounded reference. Runner clock/ownership checks also pass real portable-actor task HTTP shadow execution. The LLM side still supplies explicitly scripted sampled tokens. | Real model proposal quality and calibrated/evaluated references; the planner smoke proves no learned reasoning. |
| Local E1 execution | Deployment-only actor runner and recorded task-driven shadow paths exist. The local control composition connects timed coherent capture, calibrated saved-contract99 features, numerical actor, complete24-slot mapping and explicit publication/stop callbacks. Unit and actual-header fake-SDK ASan/UBSan checks pass; analytic/training feature comparisons remain valid. | Actual target SDK plugin linking/execution, qualified references and physical motor/IMU calibration, authority/limits/stop/watchdog integration,50Hz target timing and supervised acceptance. Fake publication/stop callbacks do not qualify hardware behavior. |
| Two-host deployment | Export, runtime, serving, visual planner and shadow runbook commands are present. | Actual Spark/Atlas installation, NIC/SDK binding, full simulator/robot acceptance and device resource/latency measurements. |

The AOT build helper had a software bookkeeping defect: aggregate
`cuda_compiled` required exactly seven modules even when eight or nine were
requested. It now compares against the requested module count. The focused
receipt regression covers seven/eight/nine modules, dry runs and failed compiler
execution using the existing explicit fake compiler. Its report is
`lunaflux/target/minicpm-v47-aot-receipt-test-v2/report.json` in the sibling repo
and explicitly records **no actual CUDA compilation**. Dummy fixture artifacts
must not be deployed.

Offline compilation was investigated without connecting to Spark, Atlas or E1.
The host is Darwin/ARM64 and has no native NVCC. CUDA 13.0.2 compiler components
were downloaded from NVIDIA's official redistributable manifest, whose compiler
[documents `sm_121` support](https://docs.nvidia.com/cuda/archive/13.0.2/cuda-compiler-driver-nvcc/index.html#gpu-feature-list).
The available local Linux VM stopped; creating an isolated compiler VM then
failed when the host disk filled. The incomplete VM/profile was removed and
local free space recovered to about 1.4 GiB. No CUDA source was compiled and no
GPU/NPU/robot was accessed. A working Linux CUDA toolchain with sufficient disk,
or the supplied Spark, is required for that remaining gate.
