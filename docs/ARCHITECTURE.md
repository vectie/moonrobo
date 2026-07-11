# MoonRobo Architecture

MoonRobo extends the Moon suite from desktop and document work into the
physical world. Its job is to make robots visible, controllable, reviewable,
and safe as agent participants without hiding hardware risk behind a generic
agent abstraction.

MoonRobo should be understood as the physical interface layer:

```text
MoonSuite books/<book-id> MoonBook with RoboBook decorator
  -> MoonRobo robot profile, twin, safety gate, bridge protocol
  -> MoonClaw bounded planning / diagnosis / simulation workers
  -> MoonTown schedules, resident robot agents, mayor supervision
  -> Robot bridge sidecar
  -> simulator or physical robot
  -> receipt and control evidence back into RoboBook/MoonBook
  -> raw captures, canonical episodes, replay, quality, and exports in MoonData
  -> RoboBook projections for robot-specific inspection and MoonData refs
```

## Stack

- **MoonBit**: core contracts, protocol DTOs, safety policy, CLI/service logic,
  bridge adapters, deterministic tests, and generated interfaces.
- **Rabbita**: browser-based robot cockpit for operators, town surfaces,
  telemetry, replay, digital twin, and review.
- **Lepus**: desktop shell for packaged local operation, supervised sidecars,
  scoped workspace access, and native app distribution.
- **MoonBook**: durable `books/<book-id>` substrate: pages, attachments,
  evidence ledgers, review queues, and memory packs.
- **RoboBook**: robot-domain decorator on a MoonBook: robot profile, model
  links, bridge configuration, safety policy, receipts, MoonData references,
  and robot-specific memory cards.
- **MoonData**: robot data plane for raw captures, canonical datasets,
  robot model artifacts, episodes, frame refs, quality findings, cleaning
  lineage, replay artifacts, annotations, validation-backed repair evidence,
  curated versions, and export manifests.
- **MoonClaw**: bounded agent execution for planning, inspection, diagnosis,
  simulation review, and report generation.
- **MoonTown**: scheduling, resident robot agents, standing goals, routing,
  escalation, and operator-visible civic/physical-world state.
- **MoonGate**: observability, suite status, local health, usage, and metrics.

## Boundary

MoonRobo must stay narrow enough to reason about. It owns robot-facing product
and protocol surfaces, not the entire robotics stack.

MoonRobo owns:

- robot profiles and capability schemas
- digital twin and telemetry projections
- command-intent and run-receipt contracts
- safety gate policy and approval flows
- bridge protocol for simulator, SDK, and ROS-style hardware sidecars
- teleoperation surfaces
- control evidence capture and MoonData registration for raw/derived data
- RoboBook decorator schema and validation
- MoonBook memory projection from robot evidence and next work

MoonRobo does not own:

- raw robot data storage, dataset cleaning, dataset quality authority, or
  training/evaluation exports
- long-running town scheduling
- general-purpose durable knowledge outside robot memory packs
- generic agent runtime internals
- model proxying, provider routing, or accounting
- vendor SDK internals
- direct low-level control loops inside UI code

## Package Map

MoonRobo is now split into explicit MoonBit packages instead of one growing
facade:

```text
src/core                 robot profile, capability, intent, telemetry, receipt
src/runtime              RoboBook loading, safety gate, sessions, evidence
src/bridge_*             bridge protocol, sidecar manifest, client, execution
src/host_api             local API projection over runtime and evidence
src/desktop_host         Rabbita/Lepus HTTP boundary
src/cockpit              operator and agent cockpit projection
src/urdf                 URDF parsing
src/urdf_viewport        digital-twin projection from URDF + telemetry
src/urdf_editor          source-preserving robot-model editing
src/moondata_*           standalone robot data plane
cmd/main                 MoonRobo CLI and desktop host entrypoint
cmd/moondata             MoonData CLI and data-plane entrypoint
cmd/sdk_e1_bridge        SDK E1 bridge sidecar
```

The root package should stay thin. Product behavior belongs in named packages
with generated interfaces that make ownership visible through `.mbti` diffs.

The current URDF viewport boundary is split deliberately:

- `src/urdf` parses robot model artifacts into links, joints, origins, axes,
  and limits.
- `src/urdf_viewport` turns a parsed URDF plus a telemetry frame into a
  reusable simulation projection: root link, accumulated link poses, transform
  annotations, limit helpers, and normalized joint positions.
- `src/cockpit` wraps that shared simulation with RoboBook readiness,
  telemetry/model mapping diagnostics, safety state, receipts, and
  operator-facing status.
- `src/desktop_host` serves the projection plus scoped read-only model assets
  for browser rendering. It does not expose arbitrary filesystem access.
- `ui/rabbita-cockpit` renders the cockpit projection and hosts the Three.js
  URDF/STL scene. It should not own URDF parsing, transform calculation, safety
  policy, or bridge execution.

The planned URDF editor keeps that boundary and adds a source-preserving model
editing layer. The editor lane is documented in
[`URDF_EDITOR.md`](URDF_EDITOR.md). It should parse URDF into stable editable
nodes, apply typed patch commands, validate the result, persist source changes
as MoonData robot-model artifacts, write model-edit receipts under RoboBook,
and then refresh the existing viewport projection. It should not let browser UI
code write files directly, and it should not share responsibilities with the
physical execution loop.

## Data Flow

The live execution path must be explicit:

```text
operator or MoonTown request
  -> CommandIntent
  -> RobotProfile capability check
  -> SafetyGate
  -> dry-run / simulator receipt
  -> human or policy approval
  -> bridge execute
  -> TelemetryFrame stream
  -> RunReceipt
  -> RoboBook control evidence
  -> MoonData capture/episode/frame registration
  -> MoonBook accepted summary
  -> MoonTown status
```

No UI control should call a vendor SDK directly. No agent should send raw motor
commands to a robot. All physical execution goes through the same safety-gated
bridge protocol.

The data path is deliberately separate:

```text
MoonRobo observation or execution
  -> raw frames, signals, media, and command feedback
  -> MoonData capture session
  -> MoonData canonical dataset / episode / frame refs
  -> MoonData quality, cleaning, annotation, replay, and export artifacts
  -> RoboBook stores MoonData refs plus accepted robot-domain summaries
  -> MoonBook memory stores compact lessons and next work
```

MoonData is the unique source of robot data truth. URDF packages, mesh/material
assets, raw payloads, cleaned datasets, replay products, repair evidence, and
exports live there as artifact manifests plus `moondata://` payload refs.
RoboBook may reference a MoonData robot model, dataset, episode, quality report,
replay artifact, or export manifest, but it should not become the URDF, mesh,
raw-data, replay, repair, or cleaned-dataset store. Runtime and UI surfaces may
cache projections for speed, but the recoverable artifact identity stays in
MoonData. Status, context, and handoff projections expose validation coverage
plus repair work pressure, and readiness is true only when the latest durable
validation report covers the current catalog and open, applied-unvalidated,
failed, and pending repair work are clear. Suite consumers can decide whether
to run, review, clean, or block without scanning data folders. See
[`MOONDATA.md`](MOONDATA.md).

## First Hardware Reference

The local `../sdk` repository is the first concrete hardware reference. It
provides:

- Noetix E1 SDK
- CycloneDDS transport
- high-control and low-control APIs
- Python bindings through pybind
- C++ examples
- 24 motor states and commands
- IMU and joystick data
- high-level commands such as walk, run, switch, teach, and play-teach
- robot configuration and policy files

MoonRobo should wrap this as a sidecar bridge, not copy its logic into the
MoonBit core.

## Interface Reference

The sibling `../olu` work is a useful reference for robot canvas, model loading,
hardware configuration, file IO, and inspection workflows. MoonRobo should use
that learning without inheriting product ownership or naming. The MoonRobo UI
should be its own Rabbita application and should keep the product story centered
on physical-world agent operation.

## Resident Robot Agents

In MoonTown, a robot should appear as a resident physical agent with:

- identity
- embodiment
- current mode
- location or workspace
- capability list
- safety status
- bridge health
- recent receipts
- maintenance state
- standing goals

The resident agent is not the robot body. It is the town-facing control and
memory identity for that body.

MoonRobo is the platform layer that lets this resident agent map to one
physical body or simulator. The first milestone is one-to-one mapping: one
MoonSuite `books/<book-id>` MoonBook, one RoboBook decorator, one bridge, one
resident projection, and one cockpit surface. Fleet routing can come later.

## Closed MoonClaw-MoonRobo Loop

MoonClaw should run robot work as a gateway command lane, not as raw physical
control. The loop is:

```text
MoonClaw gateway command
  -> MoonRobo gateway server
  -> RoboBook identity, safety, readiness, calibration, and bridge gates
  -> bounded execution or explicit recovery blocker
  -> RoboBook control evidence and MoonData data refs
  -> MoonBook durable memory and conversation
  -> MoonClaw context plus MoonTown resident state
  -> next gateway command step
```

This keeps the agentic part and the physical gateway separate. MoonClaw plans,
diagnoses, and chooses the next bounded route. MoonRobo validates the selected
RoboBook identity, enforces safety and readiness, owns runtime validation and
bridge dispatch, and records evidence. MoonBook stores durable memory and
conversation. RoboBook remains the small physical decorator over the selected
MoonSuite `books/<book-id>` MoonBook, adding robot identity, bridge config,
safety policy, runs, telemetry, calibration, and execution proof. A gateway
command is not complete until the evidence is summarized back into MoonBook so
the next action can be based on durable memory.

The first user-facing request surface does not need to be a separate chat
platform. A message like "ask the robot to inspect the desk" should enter
MoonTown or Rabbita as a task intent, then be normalized into MoonRobo
contracts. MoonTown owns conversation, scheduling, and resident routing;
MoonRobo owns the physical boundary, safety gate, bridge protocol, and evidence
record. For accepted non-review tasks, Rabbita hands the refreshed MoonRobo
context to MoonClaw's robot routine gateway so MoonClaw owns policy and route
selection. A separate chat product is useful only if it shares the same task
intent and evidence APIs instead of bypassing them.
`POST /api/moontown/tasks/message` now classifies task messages into
observation, command-review, and maintenance-review plans. Observation messages
start the existing read-only observation flow. Review-classified messages are
persisted under `moonbook/task-messages/` with
`physical_execution_allowed: false` and a next route into the gated review or
intent APIs, so user language never bypasses the robot safety boundary.
Command-review records include an intent draft, which Rabbita can evaluate
through `POST /api/moonbook/task-messages/{task_id}/evaluate`, the shared
task-message safety route backed by the same evaluator used for manual command
proposals. The same route family owns dry-run, approval, and execute steps, so
the message-derived intent remains tied to the persisted MoonBook record through
the full safety chain.
Those persisted plans are projected into `GET /api/moonrobo/platform-queue`, making a
user's physical-world request visible as operator review work instead of hidden
conversation state.

The first resident projection is implemented in `src/resident` and exposed at
`GET /api/moontown/resident`. It is intentionally read-only: it aggregates the
RoboBook profile, bridge sidecar status, active observation session, latest
receipt, capability count, and review count so MoonTown can see the robot
without owning execution.
`GET /api/moonrobo/readiness` is the cross-cutting milestone check for this
first one-to-one mapping. It does not grant new capability. It reports whether
the selected RoboBook root has required profile files, MoonBook task messages,
persisted MoonBook memory, bounded tool registration, healthy runtime evidence,
and task-execution snapshots, then returns a remediation plan for any remaining
blockers. A live deployment is not considered at the first goal until this
report is `ready` for that root.
`POST /api/moonrobo/bootstrap` is the companion preparation route. It moves a
fresh RoboBook from configured to MoonClaw-ready substrate by persisting the tool
registry, MoonBook memory, and first reviewed task message while leaving
physical execution blocked.
Task-message progress now uses only explicit
`/api/moonbook/task-messages/{task_id}/{gate}` routes selected from the
MoonRobo platform queue and tool registry. MoonRobo no longer hosts an
aggregate `/api/moonrobo/advance` selector. Evaluation, dry-run, and approval
remain operator-visible gates; the explicit execute gate requires healthy live
runtime evidence before dispatching to the sidecar.

The first task ingress is implemented in `src/task` and exposed at
`POST /api/moontown/tasks/observe`. A town standing goal submits an observation
task; MoonRobo compiles it into the existing read-only observation session flow,
runs the safety gate, writes RoboBook evidence, and returns the updated
resident projection. MoonTown owns scheduling, while MoonRobo owns robot
execution boundaries and receipts.
Observation evidence includes a MoonData frame reference, so town and review
surfaces can link to concrete replay data without reaching into bridge
internals or treating RoboBook as the raw data store.
The first replay projection is implemented in `src/replay` and exposed at
`GET /api/replays/{session_id}`. It summarizes RoboBook observation sessions
and MoonData episode/frame/replay refs into the shape Rabbita and MoonTown need
for timeline inspection while keeping durable data identity in MoonData and
control evidence in RoboBook.
Replay annotations are implemented in `src/annotation` and persisted by
`src/runtime` under `runs/annotations/{session_id}/`. Host routes under
`/api/replays/{session_id}/annotations` make curation explicit evidence that can
feed MoonData dataset quality and policy evaluation later.
The reusable process engine lives in `src/pipeline`: it starts task-backed
observations, ingests frames, stops sessions, builds replay timelines, and
returns typed process results without depending on HTTP. `src/review` produces
deterministic diagnosis records from replay and receipt state, and
`src/routine_context` turns resident state plus review evidence into a bounded
context pack.
`src/runtime` persists reviews under `runs/reviews/`. `src/host_api`
is the thin route facade for these engines. The first process-level route is
`POST /api/moontown/tasks/observe-run`; it calls the pipeline engine and returns
resident state for MoonTown. `GET /api/reviews` exposes the durable review
queue, and `GET /api/moonclaw/context` exposes the agent-facing context and
gateway next-route hint. MoonClaw owns routine selection outside MoonRobo. This
is the initial agentic robot process pipeline surface; the deterministic frame
source is the replaceable part when the
supervised bridge polls live hardware.
MoonClaw owns robot routine analysis and selection. MoonRobo projects the
RoboBook, resident, review, and platform ledgers into `GET
/api/moonstat/status`. That endpoint is intentionally read-only: it lets
MoonGate and other suite surfaces track readiness, bridge degradation, review
pressure, evidence counts, latest replay, and latest process run without
receiving any execution authority.
`src/platform_queue` is the first MoonTown-ready MoonRobo platform queue. It is a pure
projection over resident state, task-message plans, process reviews, MoonData
quality reports, runtime readiness, and proof evidence. `GET /api/moonrobo/platform-queue`
exposes work-pressure items such as bridge connection, task-message review,
evidence review, replay annotation, MoonData quality repair, and proof
progress. This keeps scheduling inputs visible without making the queue the
routine selector or giving it direct bridge/file-write authority.
`src/moonbook` distills resident state, latest observation/review evidence, and
the next queued work item into MoonBook memory cards. This is the memory path
that prevents MoonClaw, MoonTown, and tool agents from forgetting robot
observations between runs. `GET /api/moonbook/memory` returns the current memory
pack; `POST /api/moonbook/remember` persists it under
`moonbook/memory/{pack_id}.json` so MoonClaw and MoonTown can recall what the
robot observed and what remains to do. RoboBook is the robot view over this
MoonBook substrate, not a competing memory store.
`GET /api/moonrobo/platform-queue` exposes the top evidence pressure item, target
route, target id, priority, and supporting artifacts. `GET /api/tools/registry`
exposes the bounded MoonRobo capabilities available to MoonClaw. MoonRobo does
not run MoonClaw's routine policy; MoonClaw owns routine selection and calls
explicit MoonRobo routes through the gateway/tool boundary.
`GET /api/tools/registry` and `POST /api/tools/register` persist the matching
bounded provider registry under RoboBook. The registry advertises MoonRobo host,
MoonClaw process, and Rabbita cockpit capabilities as typed routes, including
MoonBook memory, conversation, task-message ledger, and task-message status
projections. It refuses physical execution authority in provider metadata.

MoonClaw may use MoonRobo through this tool boundary, but it should register and
call typed capabilities instead of receiving raw bridge access. MoonRobo workers
and suite tools are treated as bounded capability providers, with explicit
permissions for artifact updates, validation, planning, and status work. They
are not robot bodies and should still write durable observations through
MoonBook when their work changes the robot agenda. `GET /api/moonclaw/context`
embeds the current MoonBook memory pack, platform queue, tool registry,
live-readiness preflight, proof-session history, and live-exercise closure
history in the context pack, so MoonClaw process selection is grounded in
durable recall, registered capabilities, work-pressure evidence, and repeated
physical-world hardening evidence. See
`docs/AGENT_INTEGRATION.md` for the full agent memory and registration model.

## Failure Philosophy

Physical execution needs fail-fast behavior:

- missing robot profile blocks execution
- missing bridge blocks execution
- stale telemetry blocks execution
- unknown capability blocks execution
- unsafe verdict blocks execution
- low-control access requires explicit developer gate
- bridge errors are preserved in receipts
- silent fallback is not allowed on actuation paths

The system can degrade to read-only observation or simulation, but it must make
that state visible.
