# Vectie T1 repository and resource audit

Audit date: 2026-10-29. Scope: the user's named repositories, selected upstream
dependencies, saved MoonRobo results and primary resource documentation.
See [specification](SPECIFICATION_V0.md) and [development plan](DEVELOPMENT_PLAN.md).

## 1. Evidence and revision register

These are the local revisions inspected. Several local remotes are `vectie` forks;
their names alone do not establish upstream identity. The E1 lab, SDK and RP1 HEADs
matched their named upstream revisions when checked during this investigation.
The SuperMimic fork is behind its inspected upstream. Working trees were not updated.

| Resource | Local path relative to Workspace | Inspected local HEAD | Evidence level |
| --- | --- | --- | --- |
| Noetix E1 lab | `lab` | `5a1d62d57d26499f10fc840df7b9f9d0331f5c72` | README, models, actuator/task and sim2sim configurations |
| Noetix E1 SDK | `sdk` | `3055bdc644f61caf948d935ee274c5c48703c24f` | SDK 3.1.0 headers, example/config/build layout; vendor binaries not audited internally |
| RP1 | `rp1` | `6e75dcc0bdb769867e554dd07782374b536013d3` | Umbrella repository and selected linked resources below |
| SuperMimic reproduction | `smc` | `a1508d42c9d1699a52e8233ab16d08c488441ab9` | Learning/evaluation code, configuration, data references and upstream changes |
| RKNN GO-1 | `RKNN-GO-1` | `8a4fd94ed235903b4929f8af164c0e1a555c506e` | Conversion wrappers, vendored model, example configuration, requirements and tracked-file inventory |
| MoonRobo | `moonrobo` | `22ef620cf6724abf03e5a5e58dc213ba2a124dd8` **plus extensive local changes** | Native learning, SDK adapter, contracts, UI/data paths and saved results through 2026-10-28 |

MoonRobo HEAD is not a sufficient reproduction identifier. Preserve the worktree
patch, untracked source manifest and artifact hashes when freezing a baseline.
Do not discard unrelated local work to obtain a clean revision.

Public pages and unpinned subproject READMEs below describe what was available on
the audit date. Pin their commit/release and archive source/license records before
adopting them. Selected files were inspected; no complete CAD, PCB, firmware or
security audit is claimed.

## 2. E1, RP1 and G1 comparison

| Dimension | Noetix E1 | Roboparty RP1 | Unitree G1 |
| --- | --- | --- | --- |
| Body configuration actually relevant here | Lab has 12- and 24-DoF models; 24 = legs12 + arms10 + waist2 | Published 24- and 28-body-joint variants; 28 adds seven-axis arms | SMC uses a 29-body-joint G1 model; commercial G1 configurations vary |
| Most valuable contribution | Hardware integration, AMP/mimic examples, ONNX metadata and sim2sim structure | Mechanical/electrical/harness resources, actuator references, deployment mappings and test fixtures | Established benchmark embodiment and vendor SDK/deployment examples |
| Hardware openness inspected | Robot description assets; no complete manufacturing package established in the named repos | CAD/drawings, PCB fabrication indexes, harness drawings and BOM resources published | Vendor product, SDK and robot assets; not a complete open manufacturing package in this audit |
| Controller caveat | MoonRobo adapter is incompatible with current SDK 3.1.0 | Explicit motor order, signs, offsets, IMU transform and coupled ankles must be requalified | A model/checkpoint must match the exact EDU/body/hand/firmware configuration |
| Product role proposed | Integration and validation reference; optional comparison platform | Starting architecture for our owned body | Benchmark/comparison platform; optional reference unit if justified |
| What it does not give us | An already qualified custom-body controller | A manufactured/calibrated/validated MoonRobo unit | A transferable controller for E1/RP1/our morphology |

The official G1 page lists 1.32 m standing height and about 35 kg with battery for
the base robot, with configuration-dependent EDU options. Its commercial joint
counts include options and should not be equated to the 29-body-joint simulation
model. Treat payload and runtime figures as vendor reports under their conditions,
not our acceptance evidence. [Unitree G1 specifications](https://www.unitree.com/g1/).

### E1 assets and policy interfaces

The [E1 lab](https://github.com/Noetix-Robotics/noetix_e1_lab) already contains useful
URDF/MJCF models and training/deployment examples. Relevant local files include:

- [24-DoF URDF](../../../lab/source/NoetixE1/NoetixE1/assets/robots/e1/urdf/e1_24dof.urdf)
  and [24-DoF MJCF](../../../lab/source/NoetixE1/NoetixE1/assets/robots/e1/mjcf/e1_24dof.xml).
- `e1.py` actuator configuration and `tasks/mimic/config/e1/flat_env_cfg.py` in
  the same `source/NoetixE1/NoetixE1` package.
- Walk/run uses a 12-action contract; inspected sim2sim inputs use 45 values ×5
  history. Mimic uses a distinct 24-action contract with 129 values ×5 history.
  Preserve the exported default pose, scales and gains as part of each model.

The lab's waist roll axis is x. MoonRobo's example
[E1 URDF](../../examples/noetix-e1/model/robot.urdf) uses a pitch axis for its second
waist joint and placeholder geometry. They are not interchangeable physics models.
The lab's assets are a better source to evaluate, but their applicability to a
particular physical serial/firmware still needs manufacturer confirmation and
measurement. README Isaac Lab version references are inconsistent; freeze a tested
dependency lock rather than choosing one from a badge.

### E1 SDK mismatch: a concrete integration blocker

The current [SDK common header](../../../sdk/include/common.h) declares namespace
`noetix`, version 3.1.0, `DANCE = 12`, and `DEFAULT = 14`. Hardware status is delivered
through a callback contract with 24 motor entries. The repository packages headers,
prebuilt libraries and DDS dependencies; the old controller source files expected
by MoonRobo are absent. [Upstream SDK](https://github.com/Noetix-Robotics/noetix_sdk_e1).

Current MoonRobo [adapter](../../src/sdk_e1_native/sdk_adapter.cpp) still uses
`legged::HighController` and old getter methods. Its
[CMake configuration](../../src/sdk_e1_native/CMakeLists.txt) expects
`src/highcontroller.cpp`. Its [high-control mapping](../../src/sdk_e1/high_control.mbt)
assigns `DEFAULT` the value 12. Passing that number to SDK 3.1.0 would identify DANCE.

Required work: a revision-specific adapter, symbolic command mapping, callback
snapshot validation, compile/device-stub tests, stale-state behavior and a separate
hardware qualification. Do not change a numeric constant and call the integration
fixed. Keep physical capability disabled until the whole contract is verified.

The older [E1 transfer note](../E1_SUPERMIMIC_TRANSFER.md) describes a 21-of-24 read
bug and repeated setpoints in an older source-based SDK. Those are historical
observations, not verified properties of the current prebuilt SDK. The disabled
low-control candidate is likewise not qualification for SDK 3.1.0.

## 3. RP1 resource map

The [RP1 umbrella](https://github.com/Roboparty/RP1) links the resources below; it
does not itself contain the complete robot. Features described as coming soon,
including certain world-model integrations, are not dependencies we can count as
already implemented.

| Resource | What was verified | How to use / remaining investigation |
| --- | --- | --- |
| [rp1_hardware mechanics](https://github.com/Roboparty/rp1_hardware/tree/main/01_Mechanic) | Index describes RP1.3.4 SolidWorks assembly, Parasolid, drawings, CNC/print/rubber BOMs and five-/seven-axis arm variants | Resolve the complete assembly, supplier parts, mass properties and drawing revision consistency; inspect all critical dimensions/load paths |
| [PCB resources](https://github.com/Roboparty/rp1_hardware/tree/main/02_PCB) | Index describes 14 board types with revisions, BOM/Gerber/CPL/fabrication requirements; includes RK3588S main board, power and peripheral boards | Choose the subset our architecture needs; audit power/stop schematics, firmware, assembly notes and test coverage before fabrication |
| [Harness resources](https://github.com/Roboparty/rp1_hardware/tree/main/03_Harness) | Index describes 42 harness types, 43 PDF drawings and manufacturing instructions | Recalculate current/drop/temperature and dynamic routing; reconcile pinouts across PCB/motor revisions; do not copy example wire gauge blindly |
| [rp1_description](https://github.com/Roboparty/rp1_description/tree/master) | `urdf/rp1_24dof.urdf` has 24 revolute joints; `urdf/rp1.urdf` has 28; hand variants are separate | Select one morphology and bind to physical assembly; review inertias, collision and joint ranges |
| [roboparty_deploy](https://github.com/Roboparty/roboparty_deploy) | Deployment is composed through submodules for inference, motors, IMU and cameras | Freeze every gitlink; deployment README still marks RP1 guide as coming soon; code presence does not replace bring-up instructions |
| [Pinned inference configuration](https://github.com/Roboparty/roboparty_inference/tree/027abe1307b8c1abfd2e419509bffe127eab1d69/robots) | 24/28 motor maps, CAN-FD buses, signs/offsets, IMU transform, coupled ankle indexes, ONNX policy configurations | Use as interface examples; never copy another unit's zero offsets or sensor calibration |
| [roboparty_train](https://github.com/Roboparty/roboparty_train) | README describes locomotion/mimic tasks and a newer Isaac Lab/RSL-RL stack | Pin separately from E1 and SMC; validate the selected model and checkpoint; no training performed here |
| [ROMOMO](https://github.com/Roboparty/ROMOMO) | Public actuator specifications, drawings, CAN-FD manual and test-report resources | Obtain actual motor/drive firmware and protocol revision separately; this repository explicitly does not contain software/firmware |
| [rp1_test](https://github.com/Roboparty/rp1_test) | Arm/torso/leg rig resources, dashboard/HMI/backend and 18 whole-body test-method topics | Adapt fixtures and methods; the test-case README labels parameters as drafts to freeze before use |
| [RP Hand](https://github.com/Roboparty/rp_dexhand) | Published five-finger hand: 11 mechanical DoF, six active axes, CAN-FD; linked C++/Python/ROS 2 SDK and models | Later dexterity option; separate axis count, protocol, force/thermal qualification and data collection; not the V0 gripper |

The pinned 28-motor robot configuration uses four CAN-FD buses with seven motors
each. The 24-motor variant uses 7/7/5/5. Inspected BeyondMimic/UFO configurations
use `dt: 0.002` and decimation 10: nominal 500 Hz /50 Hz. Other configurations may
differ. This does not prove bus timing or fault behavior on our hardware.

ROMOMO's table reports RMM10062-2E: 48 V, ratio22, rated80/peak130 rpm and
rated44/peak160 N·m; RMM6562-2E: 48 V, ratio19.5, rated60/peak200 rpm and
rated10/peak35 N·m. RMM8463-2E has a drawing entry without complete torque/speed
figures in that table. Obtain full operating curves and their test conditions.

RP1 test topics include endurance, loaded operation, environmental exposure,
thermal derating, power cycling and handling. Published rig demonstrations and
draft test severities are not a qualification report for our robot. Review fixture
load ratings and instrument calibration before adapting them.

## 4. SuperMimic and MoonRobo reproduction status

### Three evidence sets must remain distinct

| Evidence set | What it establishes | What it does not establish |
| --- | --- | --- |
| [Paper project site](https://supermimic.github.io/) | Authors report full-loop compute and coverage on 129,514 filtered BONES-SEED motions; real G1 demonstrations | Our reproduced results or performance on an owned body |
| [Independent implementation](https://github.com/zita-ch/supermimic_vibed), local `smc` | Implemented learning/evaluation path, using 40 retargeted LAFAN1 clips and a G1 model; README reports its own results | Official author code or full BONES benchmark reproduction |
| MoonRobo native implementation and saved outputs | Native execution, numerical comparisons, scoped timings, checkpoints and experiment evidence | A completed full-benchmark convergence run or hardware qualification |

The official site's 129,514-motion evaluation uses training motions; its reported
coverage is distinct from held-out generalization. Its 3 h result refers to the
full training loop, with checkpoint evaluation outside that timing. The 40-clip
LAFAN1 experiment and individual native updates must not be relabeled as that result.
[Benchmark definitions](https://supermimic.github.io/).

The inspected independent implementation uses 29 G1 body joints, 50 Hz control,
four 5 ms physics substeps, 10-frame history/preview and 32-step imagination.
It includes world-model learning, actor/critic and full-clip evaluation. Its
precision, observation width, collision and other choices differ from the paper
in places; retain explicit method-difference records.

### Current upstream delta

Local SMC is at `a1508d42`; inspected upstream reached
`8bfc1158bd968f729fcc65d5e897a05b05ea3d36`. Relevant newer changes include:

- [`2e8b623a`](https://github.com/zita-ch/supermimic_vibed/commit/2e8b623ad5371df8b576f1c328f0872e901e1fc9):
  clip-end synthetic preview holds pose but zeroes padded velocities; preserve the
  actual final sample's velocity.
- [`68031e2c`](https://github.com/zita-ch/supermimic_vibed/commit/68031e2ccb2db98761dabdce89593866a150fafe):
  replay refill on resume and averaging duplicate reset-bin returns before EMA.
- [`1bb539c8`](https://github.com/zita-ch/supermimic_vibed/commit/1bb539c86b1c75d79d49d187275b133b95ddd3d7):
  ground-asset cache before simulation startup.

MoonRobo already averages duplicate reset bins in
[sampling.mbt](../../src/learning_aligned/sampling.mbt); its
[motion padding](../../src/learning_aligned/motion.mbt) still warrants a targeted
comparison. Do not apply every upstream change blindly. Preserve the old comparison
source and create a newly named baseline for an upgrade.

### Latest inspected native measurement

The [2026-10-28 accepted summary](../../output/spark-runtime-20261024/coefficient-full-20261028/accepted-summary.json)
and [native alignment notes](../SMC_NATIVE_ALIGNMENT.md) give:

| Scoped update | Native baseline | SMC timing reference | Interpretation |
| --- | ---: | ---: | --- |
| One world-model update, 2048×8 | 63.063 ms | 56.271 ms | Native about 12.1% slower in this probe |
| Actor batch4096 =8×512, horizon32, 20 critic updates | 1430.863 ms | 1303.043 ms | Native about 9.8% slower in this probe |

The full coefficient-fusion candidate matched the native baseline bitwise but
did not improve timing and was not admitted. The batched encoder candidate was
not admitted after numerical mismatches. The SMC compiled reference still fails
the strict cross-language numerical gate and is a timing reference only. These
numbers are not a full training iteration or a convergence result. The saved probe
reported no OOM; that is not a memory guarantee for a larger complete run.

Next reproduction resources: frozen dataset access/split, compatible simulator
assets, controlled numerical fixtures, source/dependency manifest, full-loop timing,
checkpoint/evaluation capacity and hardware-specific actor export. Preserve failures
and changes in denominator. Current instructions authorize investigation/smoke,
not new training.

## 5. RKNN GO-1 status and missing resources

The local project describes RK3588 deployment, but inspected code currently shows
an incomplete conversion experiment. This finding is limited to this checkout;
separate untracked or external board work may exist.

| Finding | Evidence | Required correction |
| --- | --- | --- |
| Main conversion script does not parse | Earlier syntax-only check of `transfer.py` failed at line282; alternatives parsed | Establish one maintained, tested entry point |
| Action export is not the real GO-1 action model | `transfer2.py` wrapper uses state adaptor, random action features, mean and final layer | Export actual conditioned action transformer and complete sampling path |
| Missing visual/language/action coupling | Wrapper bypasses the VLM conditioning/caches and scheduler used by `go1/.../modeling_go1.py` | Define stage boundaries with complete intermediate state and compare end-to-end |
| Missing weights can silently continue | Conditional checkpoint loading allows initialized parameters when files are absent | Require exact checkpoint/hash and fail closed |
| Calibration is not representative | Random images/tokens and incomplete action calibration path | Collect licensed, representative synchronized inputs, hold out evaluation data |
| Dependency matrix conflicts | Vendored toolkit2.3.2; README ONNX1.12 versus requirements ≥1.16.1; opset19 export | Lock compatible converter/runtime/driver/operator/ONNX versions and test them |
| Deployment proof absent in tracked inventory | No tracked final RKNN/ONNX/weight artifacts, board runner or accuracy/latency report found | Add reproducible conversion manifests, complete board runtime and measured results |

The inspected example uses 16 state/action values, chunk length30, five inference
steps and latent planning. Those dimensions do not establish the joint semantics
for E1, G1, RP1 or our body. The published
[GO-1 reference and GO-1 Air](https://github.com/OpenDriveLab/AgiBot-World) offer a
baseline and an explicitly different model without the latent planner. Compare Air
as a named alternative if appropriate; silently removing components from GO-1 is
not equivalent inference.

Current [RKNN Toolkit2 documentation](https://github.com/airockchip/rknn-toolkit2)
lists v2.5.0 and distinguishes PC conversion, Lite2 Python/runtime C++ and the
kernel driver. [RKLLM](https://github.com/airockchip/rknn-llm) provides a separate
language-model runtime and multimodal examples. Those are candidate tools, not
proof that GO-1's custom action head and latent planner are supported. Upgrade only
as a measured compatibility change; keep the complete GPU reference available.

## 6. Resource inventory beyond the named repositories

| Need | Primary resource inspected | Acquisition/engineering gap |
| --- | --- | --- |
| G1 integration reference | [unitree_sdk2](https://github.com/unitreerobotics/unitree_sdk2), [unitree_rl_gym](https://github.com/unitreerobotics/unitree_rl_gym) READMEs | Exact development-capable robot variant, firmware, model and supported control mode; no hardware examples run |
| Manipulation planning | [MoveIt 2 concepts](https://moveit.picknik.ai/main/doc/concepts/concepts.html) | Own robot description, collision scene, IK and execution adapter; balance remains our integration work |
| Route planning | [Nav2](https://docs.nav2.org/rolling/) | Biped feasibility, state estimation, footprints, visibility, stops and recovery; pin a release rather than rolling docs |
| Onboard GPU | [NVIDIA Jetson Orin](https://www.nvidia.com/en-us/autonomous-machines/embedded-systems/jetson-orin/) | Exact module/carrier/power mode/JetPack, complete model memory/latency and thermal measurement; no quotation obtained |
| Depth sensing | [RealSense D435i](https://www.realsenseai.com/products/depth-camera-d435i/) | Selected camera/driver revision, close-range grasp quality, rigid mounting, synchronization and calibrated frames |
| Actuators | [ROMOMO](https://github.com/Roboparty/ROMOMO) | Joint allocation, actual curves, drive behavior/firmware, samples, quotes, lead times and alternates |
| End effectors | [RP Hand](https://github.com/Roboparty/rp_dexhand) for later dexterity; simple V0 gripper supplier open | Grasp width/force, feedback, mass, slip tests, replacement pads and interface |
| Simulation | Existing SMC/MoonRobo MuJoCo/Newton/Isaac paths and E1/RP1 configurations | Isolated dependency environments, verified meshes/inertias/contacts, identification dataset and matched controls |
| Data/storage | MoonData capture, artifact, lineage and replay paths in this repository | Capacity/retention plan, offsite backup, dataset permissions and per-unit calibration registry |
| Manufacturing | RP1 hardware resources and our released drawings | CNC/PCB/harness/battery suppliers, incoming inspection, quality agreement and service stock |
| Verification | RP1 rig/test resources and our T01–T13 plan | Qualified fixtures, calibrated instruments, operators and external environmental/EMC/transport labs |

No named repository supplies the complete state estimator, qualified whole-body
coordination, owned-body manipulation data and manufacturing release for us. These
are first-class deliverables, not glue assumed to exist.

### Data and licensing resources

This is a provenance inventory, not a legal determination. The release owner must
verify actual license files, versions, provenance and intended use per artifact.

| Resource | Inspected declaration | Engineering implication |
| --- | --- | --- |
| E1 lab/SDK | Local root LICENSE files: BSD-3-Clause | Preserve notices; separately inventory bundled binaries/dependencies and manufacturer access terms |
| Independent SMC code | MIT | Its dataset, robot assets and videos have separate rights |
| RP1 umbrella/deploy | GPL-3.0 declarations for their own code | Plan source/notice/distribution obligations at component boundaries; do not assume every linked repo has the same license |
| RP1 hardware | [License documentation](https://github.com/Roboparty/rp1_hardware): CERN-OHL-W-2.0 for owned hardware and CC BY-SA4.0 for documentation; third-party rights retained | Decide whether to adopt/modify the open design or use an independently designed architecture; record the actual obligations before release |
| ROMOMO documentation | CC BY4.0 documentation; firmware/software separate | Obtain the firmware/access terms independently |
| GO-1 model | [Official model card](https://huggingface.co/agibot-world/GO-1): CC BY-NC-SA4.0 | Commercial product use needs an appropriate permission/licensing route or a different model; code availability is insufficient |
| LAFAN1 | [Ubisoft dataset](https://github.com/ubisoft/ubisoft-laforge-animation-dataset): CC BY-NC-ND4.0 | Do not treat retargeted research clips as a commercially redistributable motion library; review use and derived artifacts explicitly |
| BONES-SEED | [Official dataset](https://huggingface.co/datasets/bones-studio/seed) and [custom license](https://bones.studio/info/seed-license) | Gated access and eligibility/use conditions; obtain access through the official owner and record the accepted version; do not assume a public mirror grants rights |
| Owned robot captures | Proposed new data collection | Contracts/consent, scene/object provenance, privacy, train/validation split and release rights must be defined at capture time |

The BONES license distinguishes academic users and qualifying startups, and defines
conditions for results and changes of status. Our company's eligibility was not
established here and no terms were accepted on its behalf. Prefer a product dataset
and model chain whose permissions remain valid for the intended business.

### Standards and release resources

Only public catalog/summary information was reviewed. Full texts, applicable editions,
market scope and test programs require a qualified engineering/compliance review.

| Reference | Resource purpose | Open work |
| --- | --- | --- |
| [ISO12100:2010](https://www.iso.org/standard/51528.html) | Machinery risk assessment/reduction framework | Hazard analysis and residual-risk record for our exact robot/use |
| [ISO13849-1:2023](https://www.iso.org/standard/73481.html) | Design of safety-related control systems | Determine required safety functions/performance levels; validate actual components and diagnostics |
| [IEC60204-1 and amendment](https://webstore.iec.ch/en/publication/26037) | Machinery electrical equipment | Electrical review including protection, bonding, stop circuits and documentation |
| [ISO13482:2014](https://www.iso.org/standard/53820.html) | Personal-care robot safety within its scope | Determine applicability; a lab humanoid is not automatically a certified personal-care robot |
| [UN Manual section38.3 test-summary resource](https://unece.org/fileadmin/DAM/trans/danger/publi/manual/Rev.6/ST-SG-AC10-11-Rev6-Amend1e.pdf) | Battery transport test documentation structure | This linked text is historical; obtain current applicable transport rules and the exact supplier pack's current test evidence from the lab/logistics specialist |
| Destination-specific requirements | Industrial robot rules if applicable, radio/EMC, battery/electrical, product marking and workplace operation | Choose intended market/use before a compliance claim or shipment |

## 7. Investigation limits and next evidence

Not yet completed: full CAD assembly resolution; per-part BOM and schematic review;
physical robot inventory/measurements; motor/drive characterization; manufacturer
confirmation; supplier quotations and lead times; gated dataset access/rights;
complete RK3588 inference; full SuperMimic training reproduction; physical walking
or manipulation qualification; environmental or compliance testing.

The [development plan](DEVELOPMENT_PLAN.md) assigns each missing resource to an
owner and gate. This audit supports architectural decisions and a concrete work
program; it does not certify a design ready to fabricate or operate.
