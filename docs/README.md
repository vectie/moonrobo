# MoonRobo Documentation

Start with the [product contract](PRODUCT_CONTRACT.md). It supersedes the
retired MoonClaw-hosted robot-routine path still preserved in historical
implementation notes.

This directory is the current design source for MoonRobo and MoonData. Keep
the docs aligned around one boundary: MoonRobo owns safe robot operation,
RoboBook owns robot-domain evidence and memory projection, and MoonData owns
durable robot data artifacts.

## Reading Map

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
