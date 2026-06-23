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
allowlisted, profile-limited high-control envelopes only after the active
runtime telemetry confirms the selected robot and bridge identity, and a
dedicated SDK writer owns the final vendor-control call. Rabbita also exposes
the dedicated emergency stop route for the active runtime bridge, with
timestamped receipt and dispatch evidence. Arbitrary motion, low-control APIs,
learned-policy actuation, and autonomous physical loops remain outside the
boundary.

Current distance to the first goal is now measurable through
`GET /api/moonrobo/readiness`. That response includes both a readiness report
and an ordered remediation plan. The report is `ready` only when the selected
RoboBook root has one-to-one profile readiness, MoonBook task messages,
persisted MoonBook memory, bounded tool registration, healthy runtime evidence,
and at least one task-execution snapshot. The plan turns every failing check
into a safe next route, such as tool-registry bootstrap, MoonBook memory
persistence, runtime supervision, or work-queue review. `POST
/api/moonrobo/bootstrap` applies the non-physical substrate steps for a fresh
root: bounded tool registry, MoonBook memory, and a first reviewed task
message. `POST /api/moonrobo/advance` then moves that reviewed message through
one safety gate at a time, stopping at live-runtime validation before any
physical dispatch. `POST /api/moonrobo/runtime-proof` is the next bridge
between software readiness and physical readiness: it accepts a telemetry frame
from the active supervised runtime, verifies that the frame matches the selected
RoboBook robot and bridge ids, and persists runtime-health proof evidence.
Until the readiness report is green on a live RoboBook root, the
remaining first-goal work is runtime proof, live hardware validation, and
calibration, not a separate chat platform.
