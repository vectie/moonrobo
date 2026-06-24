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
physical dispatch. That validation now checks the supervised graph as one
physical path: collector snapshot, writer command outbox, and control-gated
bridge feedback must all be wired to the same runtime. `POST
/api/moonrobo/first-loop` composes those safe steps:
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
the task-loop response reports `dispatch_requested`, current task status,
MoonBook conversation, Moontown resident state, and the explicit
digital/physical mapping plus a compact execution-proof summary so Rabbita can
distinguish a prepared task from an explicitly dispatched one without opening a
separate chat platform. The same response now carries a `session` projection:
one Robo session id, the MoonBook thread id, resident and mapping ids, the
latest user/Robo turn, the continuation route, dispatch readiness, execution
verification, and any recovery pointer. When dispatch completes through the
host execution route, Moonrobo writes the task-execution snapshot in the same
RoboBook ledger as the native sidecar path and returns the latest snapshot id,
proof path, verification state, and command outcome in the same task-loop
response. Blocked live dispatch also returns a compact recovery object that
points Rabbita at the runtime supervisor, runtime-health evidence, or
runtime-calibration plan that must be resolved before the same message can be
dispatched again. That recovery route is now sourced from the readiness plan, so
resolved-but-not-revalidated calibration points the same task-loop session at
`POST /api/runtime/validation/session` instead of marking the task as
dispatch-ready. `POST /api/moonrobo/task-loop/continue` is the retry path for
that same session: it accepts the existing `task_id`, reruns the bounded gates,
and can request dispatch without creating another MoonBook task message.
When a command-enabled sidecar returns command feedback telemetry, Moonrobo
persists that frame and a matching runtime-health record directly into the same
execution snapshot.
The final MoonBook memory pack for that task is written after the snapshot, so
Robo remembers the completed execution immediately.
`GET /api/moonrobo/executions` projects persisted task-execution snapshots into
a proof report with the latest task, bridge status, runtime status, physical
feedback status, and verified count after matched telemetry is captured from
the selected runtime. A snapshot is fully verified only when the executed
receipt, accepted bridge dispatch, healthy runtime, and fresh telemetry frame
agree, and the command outcome is classified for the executed capability
(`motion-feedback-observed`, `stop-feedback-observed`, or another explicit
outcome state). The executions report reads the linked feedback artifact and can
upgrade motion outcomes to `motion-feedback-checked` only when fresh error-free
body telemetry also echoes the submitted command capability and any persisted
walk/run parameters. That same proof state now feeds the Moontown resident,
MoonBook memory, MoonClaw context, and
`/api/agent/work-queue`, where an unverified latest execution becomes
read-only `verify-execution` work before more robot work is scheduled.
`POST /api/moonrobo/runtime-proof` is the next bridge between software
readiness and physical readiness: it accepts a telemetry frame from the active
supervised runtime, verifies that the frame matches the selected RoboBook robot
and bridge ids, persists the full frame under `runs/telemetry/runtime-proof/`,
and records that artifact path in runtime-health proof evidence. Until the
readiness report is green on a live RoboBook root, the remaining first-goal work
is runtime proof, live hardware validation, and calibration, not a separate chat
platform. Rabbita and the desktop host can now run repeated validation through
`POST /api/runtime/validation/session`, which persists every sample report, the
latest aggregate validation session, and a session-derived calibration plan.
`GET /api/agent/runtime-calibration/latest` projects that plan as agent work,
and `POST /api/agent/runtime-calibration/resolve` persists the operator or
agent resolution under `runs/runtime-calibration/resolutions/`. Until a newer
validation session exists, `/api/agent/work-queue` raises a higher-priority
`validate-runtime` item that points back to
`POST /api/runtime/validation/session`, so the same evidence loop proves the
fix before task-loop continuation retries dispatch. Readiness now projects that
same state as dispatch blockers: unresolved calibration points to
`/api/agent/runtime-calibration/latest`, and a resolved calibration action blocks
physical dispatch until a newer validation session is persisted through
`POST /api/runtime/validation/session`. A newer ready validation session clears
stale calibration pressure even if an older plan remains on disk.
That puts the project around the first
user-visible physical milestone: one digital Robo identity can accept a user
message and reach a gated physical dispatch path, while the remaining gap is
live-hardware proof, calibrated runtime stability, and sustained Moontown work
scheduling over the same evidence.
