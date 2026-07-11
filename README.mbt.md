# MoonRobo

MoonRobo is the physical-world interface layer for the Moon agent suite.

It should bring robots into the same operating model as MoonDesk, MoonTown,
MoonBook, MoonClaw, and MoonGate, while keeping the physical execution boundary
explicit and auditable.

MoonRobo is built around:

- MoonBit for the core contracts, command model, safety model, and local
  services
- Rabbita for the web operator interface
- Lepus for the desktop shell
- MoonBook for the durable `books/<book-id>` book, accepted evidence, memory
  packs, task messages, and review queues
- RoboBook as the robot-domain decorator on MoonBook: robot identity, models,
  calibration, safety policy, bridge configuration, runs, data references, and
  accepted evidence summaries
- MoonData for the robot data plane: raw captures, canonical datasets, quality
  findings, cleaning lineage, replay artifacts, annotations, and exports
- bridge sidecars for simulator, SDK, and ROS-style hardware integration

The first hardware reference target is the local Noetix E1 SDK in `../sdk`.
The first interface reference is the sibling robot canvas work in `../olu`.

## Product Boundary

MoonRobo is not the scheduler, model runtime, durable knowledge store, or proxy
gateway.

- MoonTown owns standing goals, schedules, routing, resident robot agents, and
  mayor supervision.
- MoonClaw owns bounded agent execution, planning, diagnostics, and tool use.
- MoonBook owns durable robot books, pages, attachments, accepted evidence,
  review queues, and memory.
- MoonData owns raw and derived robot data: captures, datasets, episodes,
  frames, quality reports, annotations, lineage, and export manifests.
- MoonGate owns observability, suite status, usage, and runtime metrics.
- MoonLib owns shared MoonSuite filesystem contracts; MoonRobo product-home and
  suite-temp helpers are thin adapters over `@moonsuite`.
- MoonRobo owns robot-facing interfaces: robot profiles, digital twins,
  command intents, telemetry, safety gates, bridge protocols, teleoperation,
  RoboBook decorators, MoonData registration, and operator controls.

## Closed Robot-Agent Loop

The intended agent loop is closed and evidence-backed:

```text
MoonClaw robot routine
  -> calls the MoonRobo gateway server through typed routes
  -> MoonRobo checks RoboBook identity, readiness, safety, and calibration
  -> MoonRobo executes or blocks only through bounded robot routes
  -> MoonRobo records control evidence in RoboBook and registers data in MoonData
  -> MoonRobo summarizes durable state into MoonBook memory
  -> MoonClaw reads MoonBook memory plus MoonRobo context before its next action
  -> repeat
```

MoonClaw owns the agentic reasoning and next-step choice. MoonRobo owns the
physical gateway, safety boundary, runtime validation, bridge dispatch, and
control evidence ledger. MoonData owns the raw and derived robot data ledger.
MoonBook owns durable memory and conversation. RoboBook is the thin
physical-world decorator around the selected MoonSuite `books/<book-id>`
MoonBook: robot identity, bridge config, safety policy, runtime/calibration
evidence, receipts, task-execution proof, and MoonData references. MoonClaw must
never call raw SDK or bridge control; it talks to MoonRobo as the gateway and
every observation, decision, blocker, execution, and lesson must be persisted as
evidence, registered with MoonData when it creates robot data, and summarized
into MoonBook memory before the next loop.

MoonClaw's gateway-hosted `POST /v1/robot/routine/run` is the executable
closed-loop routine. It reads MoonRobo's `/api/moonclaw/context`, plans the next
safe robot routine step, invokes only MoonClaw-owned non-physical MoonRobo
routes, and persists the run under MoonClaw's
`.moonsuite/products/moonclaw/robot-routine-runs/` ledger. Idle and blocked
routine attempts are persisted there too, so MoonRobo
does not expose a local MoonClaw runner just to remember failed progress.
`POST /api/moonrobo/proof-session` is the sustained proof surface for that
same path: it repeats bounded prove-loop attempts, persists the proof-session
artifact under `.moonsuite/products/moonrobo/proof-sessions/`, and returns the
next safe route when the closed loop is still blocked.
`GET /api/moonrobo/live-readiness` is the preflight answer for the same lane:
it joins the latest repeated runtime validation session, calibration plan,
proof-session history, and loop-proof projection, then points MoonClaw or
Rabbita at the next safe route before any proof-session or robot-routine
attempt.
`GET /api/moonclaw/context` carries that same live-readiness and proof-session
history beside the planning result, so MoonClaw, MoonTown, and Rabbita are
reading one shared closed-loop state instead of separate partial views.

## Documents

- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [RoboBook](docs/ROBOBOOK.md)
- [MoonData](docs/MOONDATA.md)
- [Safety](docs/SAFETY.md)
- [Bridge Protocol](docs/BRIDGE_PROTOCOL.md)
- [Interface Plan](docs/INTERFACE_PLAN.md)
- [Agent Integration](docs/AGENT_INTEGRATION.md)
- [Runtime Slice](docs/RUNTIME.md)
- [Desktop Host](docs/DESKTOP_HOST.md)
- [Desktop Bundle](docs/DESKTOP_BUNDLE.md)
- [Replay And Simulation Plan](docs/REPLAY_SIMULATION_PLAN.md)
- [Rabbita Cockpit](ui/rabbita-cockpit/README.md)

## Initial Shape

```text
MoonRobo
  MoonBit core contracts
  Rabbita web cockpit
  Lepus desktop shell
  MoonSuite books/<book-id> MoonBook
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
as far as the current RoboBook root can prove without making a policy decision:
it bootstraps non-physical substrate, reconciles queued feedback evidence when
available, persists `.moonsuite/products/moonrobo/prove-loop/{proof_id}.json`,
writes the refreshed MoonBook memory pack, and returns before/after loop-proof
evidence. If the next
missing item is a robot routine command, it stops at
`POST /api/moonrobo/gateway/command`; MoonClaw must choose and submit that
command. The plan turns every failing readiness check into a safe next route,
such as tool-registry bootstrap, MoonBook memory persistence, runtime
supervision, MoonClaw command ingress, or platform-queue review.
`POST /api/moonrobo/bootstrap` applies the non-physical
substrate steps for a fresh root: bounded tool registry, MoonBook memory, and a
first reviewed task message. `POST /api/moonrobo/advance` then moves that
reviewed message through one safety gate at a time, stopping at live-runtime
validation before any physical dispatch. Those lower-level routes remain
explicit repair tools. The user-message product lane starts in MoonRobo with
the task message and hands off to MoonClaw's `POST /v1/robot/routine/run` when
agent policy is needed. Rabbita does not need a separate chat platform: the
user-visible message remains a MoonBook task message, and the MoonClaw routine
run is the durable agent-side execution record.
`GET /api/moonrobo/session` exposes that same session as a read-only product
surface: Rabbita, MoonTown, and MoonClaw can read the current Robo session,
conversation, resident mapping, execution proof, latest loop summary, latest
turn/step evidence, memory pack, and current owner/route decision without
creating a second chat store or starting a new task.
Rabbita now loads this route directly in the task surface, so the cockpit shows
the canonical one-to-one Robo session before the lower-level task ledger and
conversation details, while also restoring who owns the next safe action.
`POST /api/moonrobo/loop` is now the preferred MoonRobo product loop. One
request may carry a user task message, persists a canonical loop artifact under
`.moonsuite/products/moonrobo/robo-loops/`, and stops at the current owner
handoff. When that owner is MoonClaw, MoonClaw's gateway performs the policy
step from MoonRobo context.
`GET /api/moonrobo/loops` and `GET /api/moonrobo/loops/{loop_id}` expose that
history for replay and audit. The lower-level `ask`, `turn`, and `step` routes
remain the concise components used by the loop and by focused debugging tools,
not a separate chat platform.
The default Rabbita "Ask Robo" action now posts to `POST /api/moonrobo/loop`,
then reloads loop, turn, step, session, memory, readiness, and proof evidence.
The task surface shows the canonical loop artifact first, with durable turn and
step history still available for replay and debugging.
MoonRobo does not expose a follow-up step runner for MoonClaw-owned decisions.
`GET /api/moonrobo/steps` and `GET /api/moonrobo/steps/{step_id}` remain history
surfaces for existing Robo step artifacts; new routine decisions are persisted
by MoonClaw's robot routine run ledger so the next MoonClaw step is grounded in
MoonBook memory and MoonRobo evidence rather than ephemeral chat.
When a command-enabled sidecar returns command feedback telemetry, MoonRobo
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
MoonTown resident,
MoonBook memory, MoonClaw context, and
`/api/moonrobo/platform-queue`, where an unverified latest execution becomes
`bind-execution-feedback` work against `/api/moonrobo/executions/feedback`
before more robot work is scheduled.
`POST /api/moonrobo/runtime-proof` is the next bridge between software
readiness and physical readiness: it accepts a telemetry frame from the active
supervised runtime, verifies that the frame matches the selected RoboBook robot
and bridge ids, persists the full frame under `runs/telemetry/runtime-proof/`,
and records that artifact path in runtime-health proof evidence.
MoonClaw's `POST /v1/robot/routine/run` now turns the user-message path into one
durable closed robot routine: MoonClaw captures MoonRobo context, chooses the
next explicit route, invokes the safe step, and writes the routine artifact under
`.moonsuite/products/moonclaw/robot-routine-runs/`; if it is idle,
operator-owned, or blocked by physical safety, the stopped run is still written
before MoonClaw returns the conflict response. Until those routine runs are green on a live
RoboBook root, the remaining first-goal work is real hardware runtime evidence,
calibrated stability, and sustained MoonTown scheduling over the same proof
surface, not a separate chat platform. Rabbita and the desktop host can now run repeated
validation through
`POST /api/runtime/validation/session`, which persists every sample report, the
latest aggregate validation session, and a session-derived calibration plan.
`GET /api/moonclaw/runtime-calibration/latest` projects that plan as MoonClaw work,
and `POST /api/moonclaw/runtime-calibration/resolve` persists the operator or
MoonClaw resolution under
`.moonsuite/products/moonrobo/runtime-calibration/resolutions/`. Until a newer
validation session exists, `/api/moonrobo/platform-queue` raises a
higher-priority `validate-runtime` item that points back to
`POST /api/runtime/validation/session`, so the same evidence loop proves the
fix before another robot-routine attempt. Readiness now projects that
same state as dispatch blockers: unresolved calibration points to
`/api/moonclaw/runtime-calibration/latest`, and a resolved calibration action blocks
physical dispatch until a newer validation session is persisted through
`POST /api/runtime/validation/session`. A newer ready validation session clears
stale calibration pressure even if an older plan remains on disk.
That puts the project at the first software proof surface for the user-visible
physical milestone: one digital Robo identity can accept a user message, pass
through MoonClaw/MoonRobo recovery, persist one combined proof artifact, and
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
sessions for Rabbita, MoonTown, and MoonClaw to reopen sustained proof history
without launching another robot or MoonClaw routine loop.
The remaining gap is running those sessions repeatedly on live hardware with
calibrated runtime stability and sustained MoonTown work scheduling over the
same evidence.
