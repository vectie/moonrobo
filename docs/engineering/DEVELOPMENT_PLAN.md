# Vectie T1 development, resources and release plan

Date: 2026-10-29. Planning proposal; no purchases, recruitment, training or physical
operations are authorized by this document. Requirements and tests are in the
[V0 specification](SPECIFICATION_V0.md); provenance is in the
[resource audit](RESOURCE_AUDIT.md).

## 1. Build sequence and gates

The critical path is model/load closure → actuator and leg evidence → qualified
walking → stationary manipulation → loaded walking → repeatable complete tasks.
Work on software stubs, data contracts and perception can proceed while hardware
is being prepared. Keep a conventional locomotion baseline so full-function delivery
does not depend on a research breakthrough or a particular NPU port.

Durations below are rough effort windows **after inputs and staffing are available**.
They are not a promised calendar schedule and are not additive where work overlaps.
Reforecast after supplier quotes, hiring and the first actuator measurements.

| Gate | Deliverable and exit evidence | Planning window | Accountable role |
| --- | --- | --- | --- |
| G0 Requirements | Freeze task/object/route envelope; resolve body/waist choice; approve hazard analysis plan and provenance strategy; open requirements traceability | 2–3 weeks | System lead |
| G1 Architecture and supply | Closed mass/power/load budgets; actuator shortlist; resolved CAD; robot package schema; RFQs and exact software baselines | 3–5 weeks | Mechanical + electrical leads |
| G2 Joint/leg rigs | Instruments/fixtures qualified; T02/T03 evidence; measured drive/watchdog behavior; updated simulation; no unresolved critical load/stop issues | 4–8 weeks | Controls + test leads |
| G3 Walking prototype | Full-body bring-up; T01–T06 evidence on the selected controller; complete logs, stop behavior and service procedure | 6–10 weeks | Locomotion lead |
| G4 Stationary manipulation | Arms/grippers/perception on a fixed rig, then balanced robot; T07 and complete inference tests; explicit whole-body ownership | 6–10 weeks, partly parallel | Manipulation lead |
| G5 Complete task | Payload-qualified walking and pick/carry/place integration; T08/T09, all failures counted; reviewed recovery cases | 6–10 weeks after prerequisites | System lead |
| G6 Three-unit pilot | Released build package, per-unit calibration/EOL, T12/T13, manufacturing/service feedback, repeatable acceptance | 8–12 weeks after design stability | Manufacturing/test lead |
| G7 Product release | Chosen-market compliance, reliability growth, supply agreements, support/spares, security/update process and field validation | Estimate after G5/G6 | Product + release owner |

Do not equate a three-unit engineering pilot with production readiness. A schedule
cannot be credibly fixed until the build-versus-buy decisions and supplier lead times
are known. Reserve explicit iteration capacity for thermal, harness, ankle and fall
damage findings.

## 2. Team proposal

Plan for approximately **12 full-time core roles**, plus specialist support. An
experienced person can cover two roles initially, but each acceptance gate still
needs a named accountable owner and an independent review of critical work.

| Role | FTE planning count | Main ownership |
| --- | ---: | --- |
| Systems/program lead | 1 | Requirements, architecture, interfaces, scope and releases |
| Mechanical/actuation engineers | 2 | CAD, loads, transmissions, actuator selection, assembly and service |
| Electrical/embedded engineers | 2 | Power/BMS integration, buses, firmware, timing and stop hardware |
| Locomotion/estimation engineers | 2 | System identification, state estimator, baseline/SuperMimic control and sim-to-real |
| Manipulation/perception engineers | 2 | Cameras, grasping, arm planning, teleoperation, learned policy and coordination |
| MoonRobo/data/platform engineer | 1 | Contracts, calibration registry, evidence, UI and reproducible deployment |
| Test/manufacturing engineers | 2 | Fixtures, verification, supplier quality, EOL and pilot builds |
| **Total** | **12** | |

Add part-time functional-safety/electrical review, battery and EMC laboratories,
licensing counsel, industrial design and manufacturing technicians as needed.
At early physical trials, provide trained operators and a separate stop observer
according to the approved procedure; do not assume one developer can safely fill
every role during a moving-robot test.

## 3. Procurement packages and quantities

Quantities below are planning quantities, not purchase orders. Price, availability,
lead time, warranty, country/market constraints and approved alternatives are open.
Purchase only against a released requirement and an authorized procurement decision.

| Package | Initial planning quantity | Specification required before selection |
| --- | --- | --- |
| Characterization actuators | At least one of each shortlisted motor/drive family, with a spare for critical tests | Torque/speed/thermal curves, firmware/protocol, encoders, regeneration, mass, harness and mounting |
| Prototype actuators | 28 body modules + one spare per selected family; separate two gripper assemblies | Per-joint allocation after inverse dynamics and rig qualification |
| Mechanical prototype | One resolved body; spare vulnerable feet/covers/linkage parts | Revisioned CAD/drawings, tolerances, material, finish, fasteners and inspection plan |
| Electrical prototype | One complete installed set plus bench controller/power set | Schematics, revisions, power/stop analysis, board test and connector compatibility |
| Battery system | Two interchangeable prototype packs and compatible charger; one bench supply/load setup | Cell/pack identity, usable energy, peak/continuous currents, BMS behavior, test and transport evidence |
| Sensors | One body IMU, one front RGB-D, two wrist cameras, two foot sensing assemblies; spare critical sensor | Timing, frames, noise, interfaces, mounting and calibration fixtures |
| Onboard compute | One reference development system, one deployment candidate | Complete inference benchmark before committing to a production module |
| Grasp test set | Five specified objects plus fixtures/placements; later separate held-out objects | Mass, size, surface, center of mass, grasp width and placement tolerances |
| Pilot units | Three complete released robot sets; shared spares by failure history | Allocate only after G5 design stability; each unit needs its own calibration/test traveler |
| Reference robot | Optional one exact E1 or development-capable G1 configuration | Clear experiment value, supported low-level access and manufacturer terms; not a prerequisite to fabricate our body |

RP1 hardware indexes are a source of design files, not a quote-ready BOM for our
28-joint robot. Reconcile the mechanical, PCB, harness and firmware revisions before
asking a supplier to manufacture them. Verify current hardware license obligations
at the same time.

### RFQ package contents

For every supplier request prepare: part/revision, drawings, material/finish,
quantity tiers (prototype/three-unit pilot), measurable acceptance criteria,
inspection/report requirements, firmware/support access, lead time, warranty,
repair/spares, permitted substitutes and shipping documentation. Request tooling/NRE
separately from unit price. No supplier messages were sent during this task.

Use a bottom-up cost model rather than an invented whole-robot price:

`program cost = people + prototype parts + rigs/instruments + compute/storage +`
`external testing/licensing + pilot builds + rework/spares + facilities`.

For each line track quantity, supplier, dated quote, tax/shipping, lead time and
contingency. Keep consumables, damaged prototype replacements and external test
repeats visible. User flexibility on budget is not evidence of available funds.

## 4. Facility, equipment and data resources

| Resource | Purpose | Initial acquisition route |
| --- | --- | --- |
| Joint dynamometer/load fixture | Measure torque-speed, efficiency, backlash, thermal duty and drive limits | Build a reviewed fixture; rent/buy calibrated torque/current instruments |
| Leg and torso/arm rigs | Validate linkage, loads, contacts and manipulation before free standing | Adapt RP1 rig concepts after load review; do not copy demonstration load ratings |
| Rated gantry/lifting/fall containment | Handling and early biped tests | Facility/mechanical design review; inspected lifting hardware and procedures |
| Electrical bench | Programmable supply/load, oscilloscope, isolated probes, CAN-FD analyzer, continuity/insulation checks | Shared lab where possible; competent electrical setup |
| Metrology | Mass, center of mass, dimensions, encoder/pose reference, force and camera calibration | Calibrated scales, fixtures and external optical tracking; outsource CMM where needed |
| Test area | Repeatable route, surfaces, workstations, barriers and monitored access | Reserve a measured indoor area; document floor/lighting/environment |
| Battery facilities | Charging, storage, fault response and pack testing | Qualified packs/charger and facility procedure; outsource destructive/transport tests |
| Fabrication | CNC, printed covers, harness assembly, PCB assembly, finishing | Specialist suppliers before buying a production workshop |
| Environmental/EMC lab | Temperature, vibration, electrical/radio and other applicable verification | External test provider once scope/design is stable |
| Data capture rig | Synchronized teleoperation, cameras, states, forces and outcomes | Own data pipeline; choose input devices after arm/gripper interfaces freeze |
| Training/evaluation worker | Frozen reference and native experiments | Inventory existing machines/access first; reserve capacity and dataset storage; no jobs launched here |
| Storage/backup | Raw captures, model artifacts, calibration, licenses and build receipts | Versioned object storage plus tested backup/restore and access controls |

Size storage from measured streams. For example, three compressed cameras at
10 Mbit/s each produce `30/8 ×3600 =13,500 MB`, about 13.5 GB per hour before
telemetry and container overhead. A 100 h collection is about 1.35 TB for those
streams; retaining raw, derivatives and an independent backup requires more.
These are sizing assumptions, not measured MoonRobo capture rates.

The official GO-1 reference reports roughly 7 GB for inference, 24 GB for an
action-expert fine-tuning example and 70 GB for its full fine-tuning example at
batch16. These are planning references with specific upstream conditions, not a
guarantee on our hardware. [Upstream requirements](https://github.com/OpenDriveLab/AgiBot-World#requirements).
Inventory existing GPU machines before selecting additional capacity. Keep any
future training budget separate from the currently authorized no-training work.

## 5. Software and data work packages

| Work package | Output | Acceptance / dependency |
| --- | --- | --- |
| WP01 Source baseline | Commit/gitlink list, dependency locks, worktree snapshot, license/source inventory | Rebuildable references; preserves old benchmark identity |
| WP02 Robot package | Versioned kinematics, dynamics, sensor frames, limits, motor mapping and calibration schema | T01; no implicit E1/G1/RP1 substitutions |
| WP03 E1 compatibility | SDK3.1-specific adapter and symbolic command map, or clearly retained older compatible SDK | Compile/stub tests and explicit unsupported-state behavior; no physical run implied |
| WP04 Device bridge | Exclusive ownership, timestamped commands/state, bounded queues, watchdog integration | T04/T05 in stubs/HIL before hardware |
| WP05 Digital robot | Identified actuator/contact/delay models and held-out rig validation | T02/T03; physics asset identity fixed |
| WP06 Walking baseline | Robot-specific estimator, locomotion control, payload profiles and reproducible evaluation | T06 before manipulation on a moving body |
| WP07 SuperMimic alignment | Selective upstream fixes, matched numerical fixtures, complete evaluation/compute accounting | Preserve negative results; future training only under a separately agreed run scope |
| WP08 Manipulation baseline | Perception, scene/IK/planning, grasp/release verification, arm rig and whole-body transition | T07 before carrying; task data tied to our embodiment |
| WP09 GO-1/RKNN feasibility | Real checkpoint loader, complete GPU baseline, complete export boundaries, board runner and benchmark | T10; stop NPU migration if correctness/latency fail; GPU route remains available |
| WP10 Evidence/UI | Same robot package across tabs, consistent language/theme, physical/sim/reference provenance, failure-aware results | T11; accessible controls and first-screen replay |
| WP11 Manufacturing | Released drawings/BOM/harness/firmware, calibration fixtures, EOL, service manual | T12/T13; three reproducible units |
| WP12 Product rights/release | Model/data/hardware permission chain, hazard disposition, destination-specific compliance plan | No external product claim beyond evidence |

Use separate environments for E1 lab, RP1 training, independent SMC and GO-1.
Their Python, simulator and model dependencies are not one interchangeable stack.
Our MoonBit-facing contracts can unify outputs without forcing all reference
implementations into one process. Agent-authored automation in this repository
follows the existing `.mbtx` convention.

### Owned data program

Start with calibration and identification, then a small controlled stationary
manipulation dataset, then payload/carry transitions. Record success, empty grasps,
slip, aborted attempts and recovery; do not train only from curated successes.
Preserve camera intrinsics/extrinsics, joint names, action cadence, contact/load and
operator actions. Separate capture sessions/operators/objects between training and
held-out evaluation to reduce leakage. Choose dataset size from learning curves and
coverage, not an arbitrary promise that a certain number of demonstrations is enough.

Keep LAFAN1 and BONES research work and GO-1 evaluations under their actual terms.
Do not make production depend on redistributing restricted retargets or weights.
Secure suitable permission or use an owned/licensed alternative before that gate.

## 6. Risk register

| Risk | Early signal | Mitigation / decision gate | Owner |
| --- | --- | --- | --- |
| Mass/torque/thermal mismatch | BOM exceeds allocation; sustained rig temperatures/torques exceed limits | Close budgets and T02 before body machining; revise actuator/geometry | Mechanical |
| Coupled ankle mapping errors | FK inconsistency, unexpected torque direction or singularity | Explicit linkage/Jacobian tests and measured rig identification | Controls |
| Stale or incompatible command | Wrong SDK enum, old state accepted, repeated command after restart | Versioned adapter, expiry/lease and fault injection | Embedded |
| Independent policies fight | Arm request destabilizes support or overrides joint ownership | One coordinator; stationary mode first; payload-qualified transition | Controls + manipulation |
| Simulation hides physical error | Rig trajectories disagree or policy depends on ideal contacts | System identification and held-out model checks before domain randomization | Locomotion |
| NPU port consumes schedule | Partial export passes while full actions differ or latency fails | Complete GPU baseline; stage gates and time-boxed feasibility | ML/embedded |
| Benchmark overclaim | Smoke/timing reported as convergence or public result as local | Immutable provenance, full denominator and explicit result category | Platform |
| Data/model rights block product | Missing license or noncommercial terms in product chain | Early inventory; permission or alternative; owned captures | Data/release |
| Manufacturing variability | Unit-specific tuning is hidden in code | Per-unit calibration, incoming inspection and three-unit repeatability | Manufacturing |
| Fall/power/thermal hazard | Inadequate containment or unknown stop behavior | Hazard-driven fixture/stop design and staged verification | Safety/test |
| Supply or revision drift | Substitute parts/firmware silently arrive | Approved alternatives, incoming revision check and compatibility matrix | Supply/embedded |

## 7. Immediate work queue

The next implementation cycle should remain non-actuating and use recorded data,
stubs and bounded smoke checks. It can deliver the following before hardware is ready:

1. Freeze the current source/artifact manifest and exact robot variants; resolve
   the E1 SDK3.1 interface mismatch in a device-stub build.
2. Create the owned 28+2 robot-package schema and model identity validation across
   experiments, results and replay. A schematic body is explicitly provisional.
3. Reconcile RP1 28-joint CAD, description, BOM, PCB and harness revision choices;
   produce the mass/load spreadsheet and RFQ packet, with unresolved items visible.
4. Add focused fixtures for SuperMimic clip-end padding and resume/replay behavior;
   preserve the old baseline and existing sampler fix. Do not launch training.
5. Replace the RKNN random-feature export experiment with a written complete
   graph/interface plan, strict checkpoint validation and recorded-input test plan;
   establish actual board/weights availability before claiming deployment.
6. Prepare the hazard log, bench/leg-rig drawings, test instrumentation list and
   T01–T05 procedures for engineering review.

Each work item should produce a reviewable artifact and a test/evidence receipt.
The first engineering decision is to freeze the V0 operating envelope and body
architecture; the first hardware investment should buy information about actuators
and loads, before committing to a complete batch of robots.
