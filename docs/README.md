# Moonrobo Documentation

This directory is the current design source for Moonrobo and MoonData. Keep
the docs aligned around one boundary: Moonrobo owns safe robot operation,
RoboBook owns robot-domain evidence and memory projection, and MoonData owns
durable robot data artifacts.

## Reading Map

- [Architecture](ARCHITECTURE.md): suite boundary, package map, and data flow.
- [MoonData](MOONDATA.md): standalone robot data plane, storage model,
  package surface, validation, repair, handoff, and phase plan.
- [RoboBook](ROBOBOOK.md): robot-domain decorator over a MoonSuite
  `books/<book-id>` MoonBook, with runtime state in the Moonrobo product home.
- [Runtime](RUNTIME.md): native command surface, runtime proof, readiness, and
  supervised bridge operation.
- [Bridge Protocol](BRIDGE_PROTOCOL.md): sidecar contract for simulators,
  SDKs, and hardware bridges.
- [Safety](SAFETY.md): physical execution gate and command classes.
- [Agent Integration](AGENT_INTEGRATION.md): MoonClaw, Moontown, task-message,
  and evidence handoff boundaries.
- [Interface Plan](INTERFACE_PLAN.md): Rabbita cockpit and Lepus desktop shape.
- [Desktop Host](DESKTOP_HOST.md): local HTTP host and app boundary.
- [Desktop Bundle](DESKTOP_BUNDLE.md): release bundle and Lepus launch plan.
- [URDF Editor](URDF_EDITOR.md): source-preserving model-editing lane.
- [Roadmap](ROADMAP.md): current phase direction and near-term priorities.

## Design Rules

- MoonData ids and `moondata://` refs are the canonical handles for robot data.
- URDF, mesh/material assets, raw captures, cleaned datasets, replay products,
  repair evidence, and exports live in MoonData.
- RoboBook stores robot identity, policy, runtime evidence, receipts, accepted
  summaries, and MoonData refs only.
- MoonClaw receives bounded refs, context, and explicit tool routes, not raw
  robot data blobs or bridge handles.
- Physical dispatch goes through Moonrobo safety, readiness, bridge dispatch,
  and receipt evidence.

## Maintenance

When a feature lands, update the owning design doc in the same change. Avoid
duplicating long command inventories across docs; point to the owning doc
instead. New data-plane behavior belongs in [MoonData](MOONDATA.md) first, then
other docs should cite the resulting boundary rather than restating storage
rules.
