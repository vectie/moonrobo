# MoonRobo Documentation

Start with the [product contract](PRODUCT_CONTRACT.md). It supersedes the
retired MoonClaw-hosted robot-routine path still preserved in historical
implementation notes.

This directory is the current design source for MoonRobo and MoonData. Keep
the docs aligned around one boundary: MoonRobo owns safe robot operation,
RoboBook owns robot-domain evidence and memory projection, and MoonData owns
durable robot data artifacts.

## Reading Map

- [External E1 neck control](E1_NECK_CONTROL.md): the stale-target incident,
  MoonBit controller, command invariants, regression tests, native ELF build,
  audit log and recovery procedure.

- [Native test setup and precision profiles](NATIVE_TESTING.md): explicit
  dependencies, matching qualified E1 runtime and independent Float64 validation.
- [Native test corrections and execution evidence](NATIVE_TEST_FIXES_20261119.md):
  all 49 prior failures addressed, 1,890 framework passes and unchanged optional skips.

- [Complete workspace integration](WORKSPACE_INTEGRATION_20261119.md): grouped
  commits for training, native physics, actor/SDK integration, UI and workflows;
  validation results, deferred gates and retained artifacts.

- [E1 commissioning findings](E1_COMMISSIONING_FINDINGS.md): hardware preparation,
  January SDK/decoder fixes, ankle diagnostics, failed attempts, successful
  suspended elbow trials, live website and remaining handback limitations.
- [E1 deployment tools](../deploy/e1/README.md): read-only telemetry, portable
  controller, explicit stage launcher and loopback-only regression tests.
- [LunaKine deployment plan](LUNAKINE_DEPLOYMENT_PLAN.md) and
  [implementation history](LUNAKINE_IMPLEMENTATION_PLAN.md): LibTorch/CUDA
  training, DGX Spark LunaFlux/MiniCPM and separate Ascend actor inference.
- [Deferred Ascend training](ASCEND_BACKEND_PLAN.md) and
  [deferred LunaFlux training](LUNAFLUX_TRAINING_BACKEND_PLAN.md): alternatives
  outside the selected actor-inference split.
- [Vectie T1 engineering proposal](engineering/README.md): V0 requirements,
  E1/RP1/G1 and SuperMimic/GO-1 resource audit, hardware/software architecture,
  acceptance tests, staffing, procurement and staged manufacturing plan.

- [Experiment 3D replay](EXPERIMENT_3D_REPLAY.md): recorded physics and reference
  motion playback in the cockpit, with a reusable world-pose channel.
- [Native cooking, contacts and solver translation](APIC_FULL_NATIVE_TRANSLATION.md):
  fixed-source coverage, MoonBit/C entry points and deferred runtime validation.
- [Python dependency boundaries](PYTHON_DEPENDENCIES.md): runtime, build and
  preserved reference paths, including concurrent source identity changes.

- [Compare measurements by recorded mode](offline-state-conditioned-distribution.md):
  contrast same-row load/current distributions across repeated state codes, inspect
  undeclared codes, and export one explicit group for observation reanalysis.

- [Recorded-state duration inspection](offline-recorded-state-duration.md): compare
  declared-code observations and bounded left-hold durations, inspect changes and
  excluded gaps, and export source-anchored state runs.

- [Recorded channel-lag exploration](offline-telemetry-lag.md): inspect signed
  offsets and explicitly export real observation pairs for downstream analysis.

- [Rotated telemetry captures](offline-telemetry-stitch.md): reassemble same-clock
  recording fragments with explicit overlap accounting and segment CSV exports.

- [Recorded planar laser scans](offline-ros2-laser-scan.md): select ROS 2 LaserScan
  observations and export sensor-frame XY points with explicit missing returns.

- [Recorded ROS 2 IMU attitude](offline-ros2-imu.md): import quaternion attitude,
  angular velocity and acceleration, then unwrap and plot recorded headings.

- [Time-window telemetry smoothing](offline-telemetry-smoothing.md): inspect noisy
  irregular recordings using complete gap-aware means, lineage and CSV exports.

- [Periodic joint unwrapping](offline-periodic-unwrapping.md): correct recorded
  wrap discontinuities in gap-separated segments before motion analysis.

- [Offline joint motion](offline-joint-motion.md): derive recorded joint rates and
  nonuniform-time acceleration estimates with source stencils and explicit gaps.
- [Pack Adapter](PACK_ADAPTER.md): manifest-derived operations, MoonFlow
  adapter v2, attempt evidence and unknown-outcome reconciliation.
- [Architecture](ARCHITECTURE.md): suite boundary, package map, and data flow.
- [SuperMimic Integration](SUPERMIMIC_INTEGRATION.md): proposed motion-skill
  learning architecture, verified platform gaps, artifact contracts, and research
  limits.
- [SuperMimic Phase Plan](SUPERMIMIC_PHASE_PLAN.md): staged delivery from usable
  inputs and simulation evaluation through E1 qualification and feedback.
- [SuperMimic Method-Aligned Baseline](G1_SUPERMIMIC_ALIGNED_BASELINE.md): real
  40-motion LAFAN1 data, paper reward/action/termination, imagined GAE critic,
  restartable training and full-clip evaluation; separates smoke from trained quality.
- [Aligned GPU Backend](G1_ALIGNED_GPU.md): optional Isaac/Newton/MuJoCo-Warp
  worker, matched-asset requirements and explicitly unverified GPU execution.
- [LunaKine actor deployment and LunaFlux LLM integration](LUNAKINE_DEPLOYMENT_PLAN.md):
  selected architecture with a separate `lunakine` Ascend actor runtime repo,
  LunaFlux/MiniCPM on DGX Spark, and LunaKine plus E1 control on a separate
  dual-Ethernet Atlas 300V host; MoonRobo retains LibTorch/CUDA training.
- [LunaKine implementation phases](LUNAKINE_IMPLEMENTATION_PLAN.md): software
  deliverables, current test evidence, and hardware acceptance deferred until
  the Spark/300V/E1 setup is available.
- [LunaKine two-host runbook](../deploy/lunakine/README.md): export, replay,
  task-driven shadow services and the selected MiniCPM-V 4.7 35B-A3B workstream.
- [E1 deployment-only actor](../src/e1_actor/README.mbt.md): LunaKine/reference
  loading and standalone inference without training or LibTorch imports.
- [E1 deployment-only shadow execution](../src/e1_actor_shadow/README.mbt.md):
  shared recorded replay and task HTTP service without simulator dependencies.
- [E1 local control composition](../src/e1_actor_control/README.mbt.md): timed
  SDK capture, calibrated actor features, reference/inference and mapped command
  frames through the existing runner, with explicit publication/stop callbacks.
- [Prepared E1 references](../src/e1_actor_reference/README.mbt.md): existing
  training preview export and deployment-only frame selection, with explicit
  clip identity, joint order, cadence and completion semantics.
- [Local actor task host](../src/policy_host/README.mbt.md): shared HTTP task
  service, control cadence and cooperative shutdown for shadow/E1 runners.
- [SDK-input E1 shadow service](../src/e1_actor_sdk_shadow/README.mbt.md): explicit
  SDK observations, calibrated features and actor/task execution with command
  recording and no SDK publication callback.
- [Explicit E1 SDK mapping](../src/sdk_e1_policy/README.mbt.md): supplied joint
  names, signs, zeros, IDs/gains, IMU frames, saved-contract observations and
  complete24-slot commands; physical
  calibration and control authority remain unqualified.
- [Deferred LunaFlux based GPU training backend](LUNAFLUX_TRAINING_BACKEND_PLAN.md):
  optional shared infrastructure and LibTorch replacement research, outside
  the selected LunaKine deployment scope.
- [Deferred Ascend training backend](ASCEND_BACKEND_PLAN.md): optional
  LibTorch/TorchNPU training research, independent of LunaKine actor inference.
- [Strict SuperMimic Reference Audit](G1_STRICT_REFERENCE_AUDIT.md): corrected
  physics and profiles, actual upstream differential checks, CPU warm-up evidence
  and DGX Spark deployment limits.
- [SuperMimic Learning Parity](G1_SUPERMIMIC_LEARNING_PARITY.md): executed
  upstream model, actor/GAE critic and replay comparisons with explicit scope.
- [Motion Learning Data](MOTION_LEARNING_DATA.md): implemented numeric dataset
  reader and training windows, with a runnable synthetic example.
- [G1 CPU Physics](G1_CPU_PHYSICS.md): actual MuJoCo collection, controller
  scoring, replay traces, and integration with the numeric window reader.
- [G1 Dynamics Fit](G1_DYNAMICS.md): exploratory collection, train-only
  normalization, differentiable prediction, held-out metrics and input gradients.
- [G1 Policy Learning](G1_POLICY_LEARNING.md): actor/critic updates, independent
  physics selection, failed-control evidence, recollection and model refitting.
- [G1 PPO Baseline](G1_PPO_BASELINE.md): simulator-trained PPO, terminal-aware
  advantages, standing diagnostics and a shared-suite checkpoint comparison.
- [G1 Goal Coverage](G1_GOAL_COVERAGE.md): independent pose goals, fresh data,
  model refinement, a bounded two-second pass and longer-trial failures.
- [G1 Ten-Second Study](G1_LONG_DURATION_STUDY.md): longer PPO, sparse tail
  recollection, time-stratified dynamics and retained failed refinements.
- [G1 Diagnostic Ablations](G1_DIAGNOSTIC_ABLATIONS.md): failure-tail physical
  gradients, horizon/critic comparisons and horizontal-translation encoding.
- [G1 Counterfactual Study](G1_COUNTERFACTUAL_STUDY.md): restored physical
  action branches, critic origin sensitivity and a paired replay/encoding study.
- [G1 Physics Critic](G1_PHYSICS_CRITIC.md): critic calibration from actual
  physics returns, independent value scores and unchanged failed control trials.
- [G1 Actor Updates](G1_ACTOR_UPDATE_STUDY.md): actual parameter directions in
  restored physics, step-size comparison and early checkpoint selection.
- [G1 Short Cycles](G1_SHORT_CYCLE_STUDY.md): five-update physical recollection,
  online world-model correction and paired actor/model selection.
- [G1 Paired Gradients](G1_PAIRED_GRADIENT_STUDY.md): restored full physical
  returns versus model/critic directions, followed by fixed-tail training.
- [G1 Teacher Initialization](G1_TEACHER_INITIALIZATION.md): sustained physics
  collection, supervised cloning and student-state teacher labeling.
- [G1 Sustained Models](G1_SUSTAINED_MODEL_STUDY.md): complete replay shards,
  common-scale prediction and matched-policy-replay model comparison.
- [G1 Temporal Inputs](G1_TEMPORAL_INPUT_STUDY.md): causal histories, planned
  goal previews and changing-reference world-model updates with failed trials.
- [G1 Dynamic-State Gradients](G1_TEMPORAL_GRADIENT_STUDY.md): restored temporal
  policy directions, short/full physics returns and dynamic prediction errors.
- [G1 Dynamic Refit](G1_DYNAMIC_REFIT_STUDY.md): actual-action stream replay,
  controlled model refitting and paired physical direction comparisons.
- [G1 Temporal Value](G1_TEMPORAL_VALUE_STUDY.md): finite-task value calibration,
  matched tail/no-tail training and independent physical direction checks.
- [G1 Replay Distribution](G1_REPLAY_DISTRIBUTION_STUDY.md): frozen replay
  directions, exact first-step reconstruction and teacher-only repeated updates.
- [G1 Temporal PPO](G1_TEMPORAL_PPO_STUDY.md): actual finite-task PPO, same-condition
  model-policy scores and training-only exploration calibration with failed trials.
- [G1 Disturbance Initialization](G1_DISTURBANCE_INITIALIZATION.md): clean/noisy
  student-state teacher supervision, broader fixed selection and independent noise audits.
- [G1 Balance Interventions](G1_BALANCE_INTERVENTION.md): frozen-actor joint
  substitutions, teacher-memory windows and same-state balance errors.
- [G1 Observation Balance Features](G1_OBSERVATION_BALANCE_FEATURES.md): portable
  differentiable geometry, causal frame transport and fixed-feedback physics checks.
- [G1 Learned Balance Feedback](G1_LEARNED_BALANCE_FEEDBACK.md): train-only ankle
  fitting, H10/full causal observers and paired physical control results.
- [G1 Balance Platform And Duration](G1_BALANCE_PLATFORM_AND_DURATION.md): shared
  labeled-data registration and longer trials exposing post-ten-second wave falls.
- [G1 Long Balance Diagnosis](G1_LONG_BALANCE_DIAGNOSIS.md): oracle-channel
  comparisons and training-only teacher refitting for sustained control targets.
- [G1 Sustained Balance Distillation](G1_SUSTAINED_BALANCE_DISTILLATION.md): fresh
  train-only fits, range/representation controls and thirty-second learned control.
- [G1 Full-Body Reference Clips](G1_FULL_BODY_REFERENCE.md): feasible physical
  motion targets, exact control reapplication and a shared reference-tracking gate.
- [G1 Reference Initialization](G1_REFERENCE_INITIALIZATION.md): full-body goal
  encoder, relative feedback and fixed-budget failed/passing control initializers.
- [G1 Reference Platform](G1_REFERENCE_PLATFORM.md): complete reference/physics
  payload registration, origin-aware pairing and planned-reference overlays.
- [G1 Reference Learning Platform](G1_REFERENCE_LEARNING_PLATFORM.md): reset/state
  learning comparison, full paired evidence and individual/full-policy quality.
- [G1 Reference Training Duration](G1_REFERENCE_EXTENDED_TRAINING.md): exact
  three-cycle weight reconstruction and six-cycle outcomes across three seeds.
- [G1 Reference Replay Retention](G1_REFERENCE_REPLAY_ANCHOR.md): fixed-capacity
  initial-data retention, qualified thirty-second pose trials and remaining failures.
- [G1 Reference Replay Platform](G1_REFERENCE_REPLAY_PLATFORM.md): six-cycle
  trained-policy comparison, complete paired data and live cockpit quality evidence.
- [G1 Reference Last-Cycle Alignment](G1_REFERENCE_LAST_CYCLE.md): frozen saved
  update comparison of imagined returns, actual physics and own-policy predictions.
- [G1 Reference Action Response](G1_REFERENCE_ACTION_RESPONSE.md): full solver
  snapshots, first-control perturbations and local H8/H32 physical direction checks.
- [G1 Reference Feedback Response](G1_REFERENCE_FEEDBACK_RESPONSE.md): crossed
  whole-tape/feedback directions, physical amplification and unresolved local derivatives.
- [G1 Reference Gradient Route](G1_REFERENCE_GRADIENT_ROUTE.md): equal-forward
  parameter directions, stopped policy-input backpropagation and full-episode probes.
- [G1 Reference Learning Comparison](G1_REFERENCE_LEARNING_COMPARISON.md):
  matched-prior world-model/PPO loops, startup coverage and failed quality results.
- [G1 Reference Root Integration](G1_REFERENCE_ROOT_INTEGRATION.md): paired
  structured-model fits, physical parameter directions and critic-tail diagnosis.
- [G1 Reference Tail Directions](G1_REFERENCE_TAIL_DIRECTIONS.md): frozen-model
  physical comparison of critic-tail and prefix-only policy directions.
- [G1 Reference Tail Training](G1_REFERENCE_TAIL_TRAINING.md): actual paired
  training with mixed reset phases and bounded steps, retaining failed outcomes.
- [G1 Reference Actor-State Origins](G1_REFERENCE_STATE_ORIGINS.md): reuse of the
  reset baseline, causal trajectory-state training and partial per-trial gains.
- [G1 Model Diagnostics](G1_MODEL_DIAGNOSTICS.md): restored physical rollouts,
  long-horizon prediction and action-sensitivity comparison.
- [Learning Experiment Registry](LEARNING_EXPERIMENT_REGISTRY.md): immutable
  MoonData payloads, per-seed outcomes, CLI and read-only platform API.
- [MoonData](MOONDATA.md): standalone robot data plane, storage model,
  package surface, validation, repair, handoff, and phase plan.
- [MoonData Production Pipeline](MOONDATA_PIPELINE.md): operational pipeline
  architecture, durable-run contract, product workflows, and delivery phases.
- [RoboBook](ROBOBOOK.md): robot-domain decorator over a MoonSuite
  `books/<book-id>` MoonBook, with runtime state in the MoonRobo product home.
- [Runtime](RUNTIME.md): native command surface, runtime proof, readiness, and
  supervised bridge operation.
- [Bridge Protocol](BRIDGE_PROTOCOL.md): sidecar contract for simulators,
  SDKs, and hardware bridges.
- [Safety](SAFETY.md): physical execution gate and command classes.
- [Agent Integration](AGENT_INTEGRATION.md): MoonClaw, MoonTown, task-message,
  and evidence handoff boundaries.
- [Interface Plan](INTERFACE_PLAN.md): Rabbita cockpit and Lepus desktop shape.
- [Cockpit Audit](COCKPIT_AUDIT.md): measured usability findings, the focused
  shell upgrade, validation evidence, and remaining gaps.
- [Desktop Host](DESKTOP_HOST.md): local HTTP host and app boundary.
- [Desktop Bundle](DESKTOP_BUNDLE.md): release bundle and Lepus launch plan.
- [URDF Editor](URDF_EDITOR.md): source-preserving model-editing lane.
- [Roadmap](ROADMAP.md): current phase direction and near-term priorities.

## Scope And Boundary

MoonRobo owns the physical-world gateway for MoonSuite. It should make robot
identity, readiness, safety, bridge dispatch, runtime evidence, and MoonData
registration inspectable without becoming a general scheduler, model runtime,
or raw data lake.

## Implementation Map

Implementation ownership is split deliberately:

- MoonRobo packages own robot profiles, command intents, safety gates, runtime
  validation, bridge contracts, gateway APIs, and cockpit projections.
- RoboBook files under `books/<book-id>` own robot identity, policy, bridge
  config, receipts, accepted summaries, and MoonData refs.
- `.moonsuite/products/moonrobo` owns runtime ledgers, readiness reports,
  bridge dispatches, proof sessions, and supervised sidecar state.
- `.tmp/products/moonrobo` owns disposable SDK snapshots and command outboxes.
- MoonData owns raw captures, cleaned datasets, replay, quality, lineage, and
  exported robot data artifacts.

## Testing Guidance

Testing should cover deterministic package contracts first, then live gateway
or sidecar smokes only when a change crosses the hardware/simulator boundary.

```sh
moon check
moon test
moon info
moon fmt
```

For bridge or runtime changes, add tests around readiness, calibration,
dispatch blocking, receipt paths, proof sessions, and product-home layout.
Never let a UI route bypass safety or readiness just because a simulator path
is convenient.

## Design Rules

- MoonData ids and `moondata://` refs are the canonical handles for robot data.
- URDF, mesh/material assets, raw captures, cleaned datasets, replay products,
  repair evidence, and exports live in MoonData.
- RoboBook stores robot identity, policy, runtime evidence, receipts, accepted
  summaries, and MoonData refs only.
- MoonClaw receives bounded refs, context, and explicit tool routes, not raw
  robot data blobs or bridge handles.
- Physical dispatch goes through MoonRobo safety, readiness, bridge dispatch,
  and receipt evidence.
- Agent integrations receive bounded context and explicit routes. They must not
  receive raw SDK handles, bridge write access, or hidden operator approvals.

## Maintenance

When a feature lands, update the owning design doc in the same change. Avoid
duplicating long command inventories across docs; point to the owning doc
instead. New data-plane behavior belongs in [MoonData](MOONDATA.md) first, then
other docs should cite the resulting boundary rather than restating storage
rules.

## Future Plan

- Deliver the durable MoonData pipeline engine before adding more artifact
  vocabulary: resumable runs, stage checkpoints, cancellation, retry, and
  failure evidence.
- Prove the closed MoonClaw-MoonRobo loop over repeated readiness, dispatch,
  receipt, and recovery cycles.
- Keep RoboBook as a thin book decorator and move raw/derived robot data into
  MoonData.
- Add stronger Rabbita cockpit and Lepus desktop smoke coverage before any
  hardware-facing release.
- Keep simulator and SDK sidecars supervised through explicit runtime records.

- [Offline telemetry resampling](offline-telemetry-resampling.md): fixed-cadence
  reconstruction with source lineage, explicit gaps and segment CSV output.

- [Event-aligned offline run comparison](offline-event-comparison.md): register
  selected observed threshold episodes, inspect signed pre/post-event windows,
  and export paired values with original clocks and anchor lineage.
