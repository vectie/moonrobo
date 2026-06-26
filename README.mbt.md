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
`POST /api/moonclaw/robot-routine` is the closed robot lane: it captures
MoonClaw context before the task, runs the canonical Moonrobo loop, captures
context after loop and memory refresh, and persists the routine record under
`runs/moonclaw-robot-routines/` with the nested `robo_loop` artifact.
`POST /api/moonrobo/proof-session` is the sustained proof surface for that
same path: it repeats bounded prove-loop attempts, persists the proof-session
artifact under `runs/proof-sessions/`, and returns the next safe route when the
closed loop is still blocked.
`GET /api/moonrobo/live-readiness` is the preflight answer for the same lane:
it joins the latest repeated runtime validation session, calibration plan,
proof-session history, and loop-proof projection, then points MoonClaw or
Rabbita at the next safe route before any proof-session or robot-routine
attempt.
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
artifact, canonical Robo loop artifact, and verified physical feedback. The
bounded `POST /api/moonrobo/prove-loop` route then takes the same product goal
as far as the current RoboBook root safely allows: it bootstraps non-physical
substrate, attempts the MoonClaw robot routine through existing runtime gates,
persists `runs/prove-loop/{proof_id}.json`, writes the refreshed MoonBook
memory pack, and returns before/after loop-proof evidence. The plan turns every
failing readiness check into a safe next route, such as
tool-registry bootstrap, MoonBook memory persistence, runtime supervision, or
work-queue review. `POST /api/moonrobo/bootstrap` applies the non-physical
substrate steps for a fresh root: bounded tool registry, MoonBook memory, and a
first reviewed task message. `POST /api/moonrobo/advance` then moves that
reviewed message through one safety gate at a time, stopping at live-runtime
validation before any physical dispatch. Those lower-level routes remain
explicit repair tools. The user-message product lane is
`POST /api/moonclaw/robot-routine`: it accepts one user task, stores MoonBook
conversation/evidence, captures MoonClaw context before and after the task, runs
the canonical Moonrobo loop, refreshes MoonBook memory, and persists one durable
routine artifact. Rabbita uses the same route for `Run Routine`, so no separate
chat platform or compatibility task-loop route is needed.
`GET /api/moonrobo/session` exposes that same session as a read-only product
surface: Rabbita, Moontown, and MoonClaw can read the current Robo session,
conversation, resident mapping, execution proof, latest loop summary, latest
turn/step evidence, memory pack, and current owner/route decision without
creating a second chat store or starting a new task.
Rabbita now loads this route directly in the task surface, so the cockpit shows
the canonical one-to-one Robo session before the lower-level task ledger and
conversation details, while also restoring who owns the next safe action.
`POST /api/moonrobo/loop` is now the preferred product loop. One request may
carry a user task message, advances only MoonClaw-owned work through the
Moonrobo gateway up to a bounded step cap, persists a canonical loop artifact
under `runs/robo-loops/`, and returns the restored session plus final decision.
`GET /api/moonrobo/loops` and `GET /api/moonrobo/loops/{loop_id}` expose that
history for replay and audit. The lower-level `ask`, `turn`, and `step` routes
remain the concise components used by the loop and by focused debugging tools,
not a separate chat platform.
The default Rabbita "Ask Robo" action now posts to `POST /api/moonrobo/loop`,
then reloads loop, turn, step, session, memory, readiness, and proof evidence.
The task surface shows the canonical loop artifact first, with durable turn and
step history still available for replay and debugging.
`POST /api/moonrobo/step` is the follow-up action when the restored session says
MoonClaw owns the next decision. It does not create a new user message; it
advances only the current MoonClaw-owned gateway work and persists a Robo step
artifact with the before decision, optional MoonClaw work-run, and after
decision. `GET /api/moonrobo/steps` and
`GET /api/moonrobo/steps/{step_id}` expose those persisted step artifacts, and
the session response includes loop, turn, and step counts plus the latest loop
summary so reloads recover the canonical loop state first.
`POST /api/moonclaw/robot-routine` is the MoonClaw-facing agent lane for that
same loop, adding context-before/context-after and a persisted routine record
around the canonical `robo_loop` so the next MoonClaw step is grounded in
MoonBook memory rather than ephemeral chat.
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
`/api/moonclaw/work-queue`, where an unverified latest execution becomes
`bind-execution-feedback` work against `/api/moonrobo/executions/feedback`
before more robot work is scheduled.
`POST /api/moonrobo/runtime-proof` is the next bridge between software
readiness and physical readiness: it accepts a telemetry frame from the active
supervised runtime, verifies that the frame matches the selected RoboBook robot
and bridge ids, persists the full frame under `runs/telemetry/runtime-proof/`,
and records that artifact path in runtime-health proof evidence.
`POST /api/moonclaw/robot-routine` now turns the user-message path into one
durable closed robot routine: MoonClaw captures context before the task,
Moonrobo accepts the task through the canonical Robo loop, advances bounded
MoonClaw-owned gateway work, records the `robo_loop`, refreshes MoonBook
memory, captures context again, and writes the routine artifact under
`runs/moonclaw-robot-routines/`. Until those routine runs are green on a live
RoboBook root, the remaining first-goal work is real hardware runtime evidence,
calibrated stability, and sustained Moontown scheduling over the same proof
surface, not a separate chat platform. Rabbita and the desktop host can now run repeated
validation through
`POST /api/runtime/validation/session`, which persists every sample report, the
latest aggregate validation session, and a session-derived calibration plan.
`GET /api/agent/runtime-calibration/latest` projects that plan as agent work,
and `POST /api/agent/runtime-calibration/resolve` persists the operator or
agent resolution under `runs/runtime-calibration/resolutions/`. Until a newer
validation session exists, `/api/moonclaw/work-queue` raises a higher-priority
`validate-runtime` item that points back to
`POST /api/runtime/validation/session`, so the same evidence loop proves the
fix before another robot-routine attempt. Readiness now projects that
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
prove-loop [robobook-root] [message] [now-ms]` runs the
bounded first proof attempt and records the latest `closed-loop-proof` memory
card. `POST /api/moonrobo/proof-session` and `moon run cmd/main --
proof-session [robobook-root] [message] [now-ms]
[iterations]` now repeat that proof attempt as one persisted session, stopping
when the loop is complete or when the same blocker repeats without progress.
`GET /api/moonrobo/live-readiness` and `moon run cmd/main -- live-readiness
[robobook-root]` sit before that proof loop: they report whether the latest
runtime validation and calibration state is clear enough to run proof sessions,
or whether MoonClaw should first call the validation or calibration route. In
that live-ready proof state, `can_run_robot_routine` means the bounded routine
lane can collect proof; `physical_execution_allowed` remains false until loop
proof is verified.
`GET /api/moonrobo/proof-sessions` and
`GET /api/moonrobo/proof-sessions/{session_id}` expose those persisted proof
sessions for Rabbita, Moontown, and MoonClaw to reopen sustained proof history
without launching another robot or MoonClaw routine loop.
The remaining gap is running those sessions repeatedly on live hardware with
calibrated runtime stability and sustained Moontown work scheduling over the
same evidence.
