# Moonrobo

Moonrobo is the physical-world interface layer for the Moon agent suite.

It should bring robots into the same operating model as Moondesk, Moontown,
MoonBook, MoonClaw, and Moonstat, while keeping the physical execution boundary
explicit and auditable.

Moonrobo is built around:

- MoonBit for the core contracts, command model, safety model, and local
  services
- Rabbita for the web operator interface
- Lepus for the desktop shell
- MoonBook for the durable book/workspace, accepted evidence, memory packs,
  datasets, and review queues
- RoboBook as the robot-domain decorator on MoonBook: robot identity, models,
  calibration, safety policy, bridge configuration, runs, and evidence
- bridge sidecars for simulator, SDK, and ROS-style hardware integration

The first hardware reference target is the local Noetix E1 SDK in `../sdk`.
The first interface reference is the sibling robot canvas work in `../olu`.

## Product Boundary

Moonrobo is not the scheduler, model runtime, durable knowledge store, or proxy
gateway.

- Moontown owns standing goals, schedules, routing, resident robot agents, and
  mayor supervision.
- MoonClaw owns bounded agent execution, planning, diagnostics, and tool use.
- MoonBook owns durable robot books, pages, attachments, accepted evidence,
  datasets, review queues, and memory.
- Moonstat owns observability, suite status, usage, and runtime metrics.
- Moonrobo owns robot-facing interfaces: robot profiles, digital twins,
  command intents, telemetry, safety gates, bridge protocols, teleoperation,
  replay, RoboBook decorators, and operator controls.

## Documents

- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [RoboBook](docs/ROBOBOOK.md)
- [Safety](docs/SAFETY.md)
- [Bridge Protocol](docs/BRIDGE_PROTOCOL.md)
- [Interface Plan](docs/INTERFACE_PLAN.md)
- [Agent Integration](docs/AGENT_INTEGRATION.md)
- [Runtime Slice](docs/RUNTIME.md)
- [Desktop Host](docs/DESKTOP_HOST.md)
- [Desktop Bundle](docs/DESKTOP_BUNDLE.md)
- [Rabbita Cockpit](ui/rabbita-cockpit/README.md)

## Initial Shape

```text
Moonrobo
  MoonBit core contracts
  Rabbita web cockpit
  Lepus desktop shell
  MoonBook workspace
  RoboBook decorator
  safety gate
  robot bridge sidecars
  simulator and replay surfaces
```

The first milestone started read-only and now reaches the first gated physical
handoff: one MoonBook-backed RoboBook maps to one supervised SDK runtime,
telemetry is persisted as evidence, reviewed user task messages can dispatch
allowlisted, profile-limited high-control envelopes, and a dedicated SDK writer
owns the final vendor-control call. Rabbita also exposes the dedicated
emergency stop route for the active runtime bridge, with timestamped receipt
and dispatch evidence. Arbitrary motion, low-control APIs, learned-policy
actuation, and autonomous physical loops remain outside the boundary.
