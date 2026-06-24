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

## Closed Robot-Agent Loop

The intended agent loop is closed and evidence-backed:

```text
MoonClaw robot routine
  -> calls the Moonrobo gateway server through typed routes
  -> Moonrobo checks RoboBook identity, readiness, safety, and calibration
  -> Moonrobo executes or blocks only through bounded robot routes
  -> Moonrobo records raw evidence in the RoboBook decorator under runs/
  -> Moonrobo summarizes durable state into MoonBook memory
  -> MoonClaw reads MoonBook memory plus Moonrobo context before its next action
  -> repeat
```

MoonClaw owns the agentic reasoning and next-step choice. Moonrobo owns the
physical gateway, safety boundary, runtime validation, bridge dispatch, and
evidence ledger. MoonBook owns durable memory and conversation. RoboBook is the
thin physical-world decorator around that MoonBook workspace: robot identity,
bridge config, safety policy, runtime/calibration evidence, receipts, telemetry,
and task-execution proof. MoonClaw must never call raw SDK or bridge control;
it talks to Moonrobo as the gateway and every observation, decision, blocker,
execution, and lesson must be persisted as evidence and summarized into
MoonBook memory before the next loop.

`POST /api/moonclaw/run-next` is the first executable closed-loop routine. It
plans from MoonBook memory and platform readiness, runs bounded observations
when clear, calls safe Moonrobo gateway remediation such as
`POST /api/runtime/validation/session` when runtime proof is stale, and records
the gateway result plus the refreshed MoonBook memory path in the MoonClaw run
ledger.
`POST /api/moonclaw/task-loop` is the user-task routine: it submits the
MoonBook-backed task message, runs the task-loop gates, calls safe gateway
recovery when runtime validation is the blocker, then continues the same task id
without creating a second conversation store.
`POST /api/moonclaw/robot-routine` is the closed robot lane: it captures
MoonClaw context before the task, calls Moonrobo live proof, captures context
after memory and evidence refresh, and persists the combined routine record
under `runs/moonclaw-robot-routines/`.
`POST /api/moonrobo/live-proof` is the proof-grade wrapper for that same path:
it runs the MoonClaw task-loop request, computes the post-run readiness and
execution-proof reports, persists the combined artifact under
`runs/live-proof/`, and returns the next safe route when the proof is blocked.
`GET /api/moonrobo/live-readiness` is the preflight answer for the same lane:
it joins the latest repeated runtime validation session, calibration plan,
proof-session history, and loop-proof projection, then points MoonClaw or
Rabbita at the next safe route before any live proof attempt.
`GET /api/moonclaw/context` carries that same live-readiness and proof-session
history beside the planning result, so MoonClaw, Moontown, and Rabbita are
reading one shared closed-loop state instead of separate partial views.

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

Current distance to the first goal is measurable through two read-only routes.
`GET /api/moonrobo/readiness` reports missing substrate and an ordered
remediation plan. The report is `ready` only when the selected RoboBook root has
one-to-one profile readiness, MoonBook task messages, persisted MoonBook
memory, bounded tool registration, healthy runtime evidence, and at least one
task-execution snapshot. `GET /api/moonrobo/loop-proof` answers the product
question directly: it scores the proposed closed loop across digital/physical
mapping, Robobook/MoonBook memory, user-message ledger, MoonClaw robot-routine
artifact, Moonrobo live-proof artifact, and verified physical feedback. The
bounded `POST /api/moonrobo/prove-loop` route then takes the same product goal
as far as the current RoboBook root safely allows: it bootstraps non-physical
substrate, attempts the MoonClaw robot routine through existing runtime gates,
persists `runs/prove-loop/{proof_id}.json`, writes the refreshed MoonBook
memory pack, and returns before/after loop-proof evidence. The plan turns every
failing readiness check into a safe next route, such as
tool-registry bootstrap, MoonBook memory persistence, runtime supervision, or
work-queue review. `POST
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
`GET /api/moonrobo/session` exposes that same session as a read-only product
surface: Rabbita, Moontown, and MoonClaw can read the current Robo session,
conversation, resident mapping, execution proof, latest turn, and memory pack
without creating a second chat store or starting a new task.
Rabbita now loads this route directly in the task surface, so the cockpit shows
the canonical one-to-one Robo session before the lower-level task ledger and
conversation details.
The default Rabbita "Ask Robo" action posts to `POST /api/moonrobo/turn`, which
persists one replayable turn and runs at most one bounded agent cycle when the
current decision is safe for MoonClaw; explicit dispatch remains on the
separate proof/dispatch controls.
MoonClaw wraps those same routes through `POST /api/moonclaw/task-loop`: when
the first attempt is blocked by stale runtime validation, MoonClaw calls
`POST /api/runtime/validation/session` through Moonrobo, then retries the same
task id and returns both the initial and final task-loop evidence.
`POST /api/moonclaw/robot-routine` wraps that task-loop proof as the actual
agent lane, adding context-before/context-after and a persisted routine record
so the next MoonClaw step is grounded in MoonBook memory rather than ephemeral
chat.
When a command-enabled sidecar returns command feedback telemetry, Moonrobo
persists that frame and a matching runtime-health record directly into the same
execution snapshot.
`POST /api/moonrobo/executions/feedback` is the explicit gateway-server
version of that same binding: given an existing execution snapshot and a
telemetry frame, it persists the frame, checks robot/bridge identity and command
echo evidence, rewrites the snapshot, refreshes MoonBook memory, and updates
the execution proof report.
The final MoonBook memory pack for that task is written after the snapshot, so
Robo remembers the completed execution immediately.
`GET /api/moonrobo/executions` projects persisted task-execution snapshots into
a proof report with the latest task, bridge status, runtime status, physical
feedback status, and verified count after matched telemetry is captured from
the selected runtime. A snapshot is fully verified only when the executed
receipt, accepted bridge dispatch, healthy runtime, and fresh telemetry frame
agree, and the command outcome is classified for the executed capability
(`motion-feedback-checked`, `stop-feedback-checked`, or another explicit
outcome state). A matched telemetry frame is only `*-observed` until the
feedback artifact also echoes the submitted command capability, intent id, and
any persisted walk/run parameters. That same checked proof state now feeds the
Moontown resident,
MoonBook memory, MoonClaw context, and
`/api/agent/work-queue`, where an unverified latest execution becomes
`bind-execution-feedback` work against `/api/moonrobo/executions/feedback`
before more robot work is scheduled.
`POST /api/moonrobo/runtime-proof` is the next bridge between software
readiness and physical readiness: it accepts a telemetry frame from the active
supervised runtime, verifies that the frame matches the selected RoboBook robot
and bridge ids, persists the full frame under `runs/telemetry/runtime-proof/`,
and records that artifact path in runtime-health proof evidence.
`POST /api/moonclaw/robot-routine` now turns the user-message path into one
durable closed robot routine: MoonClaw captures context before the task,
Moonrobo performs bounded recovery and dispatch gating through live proof, the
effective task-loop response is recorded with readiness and execution proof,
context is captured again after MoonBook memory refresh, and the routine
artifact is written under `runs/moonclaw-robot-routines/`. Until those routine
runs are green on a live RoboBook root, the remaining first-goal work is real
hardware runtime evidence, calibrated stability, and sustained Moontown
scheduling over the same proof surface, not a separate chat platform. Rabbita
and the desktop host can now run repeated
validation through
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
That puts the project at the first software proof surface for the user-visible
physical milestone: one digital Robo identity can accept a user message, pass
through MoonClaw/Moonrobo recovery, persist one combined proof artifact, and
report whether the live execution is verified. `GET /api/moonrobo/loop-proof`
and `moon run cmd/main -- loop-proof [robobook-root]` now summarize that state
as complete, operational-unproven, or incomplete; `moon run cmd/main --
prove-loop [robobook-root] [message] [allow-dispatch] [now-ms]` runs the
bounded first proof attempt and records the latest `closed-loop-proof` memory
card. `POST /api/moonrobo/proof-session` and `moon run cmd/main --
proof-session [robobook-root] [message] [allow-dispatch] [now-ms]
[iterations]` now repeat that proof attempt as one persisted session, stopping
when the loop is complete or when the same blocker repeats without progress.
`GET /api/moonrobo/live-readiness` and `moon run cmd/main -- live-readiness
[robobook-root]` sit before that proof loop: they report whether the latest
runtime validation and calibration state is clear enough to collect live proof,
or whether MoonClaw should first call the validation or calibration route.
`GET /api/moonrobo/proof-sessions` and
`GET /api/moonrobo/proof-sessions/{session_id}` expose those persisted proof
sessions for Rabbita, Moontown, and MoonClaw to reopen sustained proof history
without launching another robot or agent loop.
The remaining gap is running those sessions repeatedly on live hardware with
calibrated runtime stability and sustained Moontown work scheduling over the
same evidence.
