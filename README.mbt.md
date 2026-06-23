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
physical dispatch. `POST /api/moonrobo/first-loop` composes those safe steps:
it bootstraps what is missing, advances reviewed task-message gates, and stops
with a step ledger when runtime proof or explicit dispatch approval is required.
On the native desktop host, an explicit first-loop dispatch request
(`allow_dispatch=true`) first reaches that same `dispatch-ready` boundary and
then uses the supervised `/execute-sidecar` task route, so the platform-level
operator action records the same bridge receipt, dispatch evidence, execution
snapshot, and MoonBook memory as the task-message `Execute` control.
`POST /api/moonrobo/task-loop` is the one-call user-message path for the same
slice: it accepts a task message, stores the MoonBook conversation/evidence, and
immediately runs the first-loop gates for that task id. The desktop host uses
the same explicit `allow_dispatch=true` contract for live sidecar dispatch, and
the task-loop response reports `dispatch_requested` so Rabbita can distinguish a
prepared task from an explicitly dispatched one. When dispatch completes through
the host execution route, Moonrobo writes the task-execution snapshot in the
same RoboBook ledger as the native sidecar path, giving the user-message loop a
durable proof handle without a separate chat platform.
`GET /api/moonrobo/executions` projects persisted task-execution snapshots into
a proof report with the latest task, bridge status, runtime status, and verified
count after post-dispatch runtime health is captured. That same proof state now
feeds the Moontown resident, MoonBook memory, MoonClaw context, and
`/api/agent/work-queue`, where an unverified latest execution becomes
read-only `verify-execution` work before more robot work is scheduled.
`POST /api/moonrobo/runtime-proof` is the next bridge between software
readiness and physical readiness: it accepts a telemetry frame from the active
supervised runtime, verifies that the frame matches the selected RoboBook robot
and bridge ids, and persists runtime-health proof evidence. Until the readiness
report is green on a live RoboBook root, the remaining first-goal work is
runtime proof, live hardware validation, and calibration, not a separate chat
platform.
