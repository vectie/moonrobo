# Agent Integration Notes

These notes capture the early operating model for Moonrobo agents inside the
Moon suite.

## Platform Role

Moonrobo is not only a robot-control library. It is the physical-world robot
platform under the Moon suite. It gives Moontown resident agents a safe bridge
from digital tasks to physical bodies, simulators, and replayable evidence.

The first platform target is a one-to-one digital/physical mapping:

- one selected robot body or simulator
- one MoonBook workspace
- one RoboBook decorator for robot identity, policy, bridge, and evidence
- one resident robot projection in Moontown
- one operator cockpit in Rabbita
- one memory pack in MoonBook that preserves what the robot observed and what
  remains to do

This is enough for a user to send a task message such as "inspect this area" and
have it become a bounded task intent, safety-gated observation or action, and
durable evidence. A separate durable chat platform is not required for the first
slice; Rabbita or Moontown can expose the message surface while reusing the same
task and evidence APIs. The first concrete route is
`POST /api/moontown/tasks/message`, which classifies observation, command
review, and maintenance review messages. Observation messages start read-only
observation; command and maintenance messages persist a MoonBook task-message
plan with `physical_execution_allowed: false` and a next route into the gated
review APIs. Persisted review plans are exposed through
`GET /api/moonbook/task-messages` as a status-bearing task board with lifecycle
stage, next route, and gate flags, and exposed through
`GET /api/moonbook/conversation` as the durable user/Robo conversation
projection. The same records are then projected into
`GET /api/agent/work-queue` as operator-review work.
Rabbita opens that queued operator-review work through
`GET /api/moonbook/task-messages/{task_id}` and displays the classification,
next route, suggested capability, review flag, and no-physical-execution flag
before any later gated route can be used. The same persisted task board is also
the one-to-one Robo conversation surface in Rabbita: it renders persisted
user/Robo turns from MoonBook, focuses submitted tasks, opens review-classified
tasks immediately, and lets any actionable row continue after Rabbita reloads
the message/status evidence. `POST /api/moonrobo/task-loop` is the one-call
variant for agents that want to submit the message and immediately run the
bounded first-loop gates for the accepted task id; on the desktop host,
`allow_dispatch=false` prepares the task and stops before physical dispatch,
while `allow_dispatch=true` marks `dispatch_requested` in the response and uses
the supervised `/execute-sidecar` boundary only after the task reaches
`dispatch-ready`. The response carries the latest task-message status,
MoonBook conversation thread, Moontown resident projection, explicit
digital/physical mapping, compact execution proof, and a session projection
with the Robo session id, latest user/Robo turn, continuation route, dispatch
readiness, execution verification, and recovery pointer. Rabbita can render one
Robo chat/task surface plus the latest snapshot verification state without
creating a second durable conversation store. After a runtime or calibration
blocker is resolved, agents should call
`POST /api/moonrobo/task-loop/continue` with the existing task id instead of
submitting the same message again; the response is marked `continued: true`.
Command-review plans carry a bounded intent draft; when the operator continues
it, Rabbita calls
`POST /api/moonbook/task-messages/{task_id}/evaluate`, then `/dry-run`,
`/approve`, and `/execute-sidecar` as evidence is gathered. Every step reads the
same MoonBook task-message record, so the gates continue from the same
message-derived intent. Agents and UI surfaces can read
`GET /api/moonbook/task-messages/{task_id}/status` at any point to see the
current lifecycle stage and next route from persisted evidence. The execute step
is not complete until it writes both the bridge result receipt and the bridge
dispatch evidence under `runs/bridge-dispatches/`. It also writes
`runs/task-executions/{snapshot_id}.json`, so Moontown, MoonClaw, and Rabbita
can inspect one task-level artifact that links the message, receipt, dispatch,
MoonBook memory, runtime health, physical telemetry feedback, and supervisor
log. `GET
/api/moonrobo/executions` projects those snapshots as an execution-proof report
and marks a snapshot verified only when receipt, bridge dispatch, healthy
runtime proof, matched telemetry feedback, a persisted feedback artifact, and
command outcome evidence agree. For walk/run commands, checked outcome evidence
requires the feedback artifact to echo the command capability, intent id, and
persisted motion parameters, so plain body telemetry remains observed rather
than verified.
The same proof state is now carried by the Moontown resident projection,
MoonBook memory pack, agent work queue, and MoonClaw context: an unverified
latest execution becomes read-only `verify-execution` work before the robot
resident schedules more physical-world processes. The parallel immediate-safety path is
`POST /api/runtime/emergency-stop`: Rabbita can call it against the active
runtime bridge, and Moonrobo still writes timestamped receipt plus
bridge-dispatch evidence for the event.

## MoonClaw Tool Boundary

MoonClaw should be able to use Moonrobo as a tool, but not as an unrestricted
executor. The registration boundary should expose typed capabilities:

- read resident robot state
- read bridge health and telemetry
- read MoonBook memory
- request a next-action plan
- dispatch allowlisted evidence actions
- propose command intents for safety evaluation

MoonClaw must not receive raw bridge authority, vendor SDK handles, or direct
low-level control loops. Any physical execution still has to pass through the
Moonrobo safety gate, bridge protocol, approval evidence, bridge dispatch
ledger, and receipt ledger.

Moonrobo workers and suite tools used by MoonClaw should also register as
bounded capability providers. They can update project artifacts, run validation,
summarize evidence, or prepare plans when granted those capabilities, but they
must still use MoonBook memory and Moonrobo audit routes when their work changes
the robot agenda.

`GET /api/moonclaw/context` now carries the current MoonBook memory pack,
bounded tool registry, platform readiness report, and readiness plan inside the
planning result. MoonClaw can therefore see what the robot last observed, which
work item is remembered as highest priority, which Moonrobo routes are
registered tools, and whether calibration or validation must be remediated
before choosing the next process step.

## Closed Robot Routine

The robot routine is the third MoonClaw lane beside coding and general work. It
is not a new robot controller. It is the agentic planner that talks to the
Moonrobo gateway server and lets Moonrobo own physical authority:

```text
MoonClaw robot routine
  -> read /api/moonclaw/context and MoonBook memory
  -> choose a bounded next step
  -> call Moonrobo gateway routes only
  -> receive execution, recovery, or readiness evidence
  -> persist raw evidence in RoboBook runs/
  -> summarize what was seen, done, blocked, or learned into MoonBook memory
  -> read the updated context before the next step
```

The loop is closed only when memory is updated. If MoonClaw observes something,
chooses a plan, hits a blocker, triggers validation, asks for execution, or
learns from telemetry, Moonrobo must leave durable evidence and update MoonBook
memory. The next MoonClaw step must be based on that persisted context, not on
ephemeral chat state or direct bridge state.

`POST /api/moonclaw/run-next` implements the first routine boundary. Every run
persists a fresh MoonBook memory pack and stores its path on the MoonClaw run
record. When MoonClaw selects runtime revalidation, the routine calls
`POST /api/runtime/validation/session` through the Moonrobo gateway, writes the
validation session under `runs/runtime-validation/`, and exposes the gateway
route, status, evidence path, and message in the run detail response.
`POST /api/moonclaw/task-loop` implements the user-message routine boundary.
It submits the MoonBook task message through the existing task-loop, detects
runtime-validation recovery, calls the Moonrobo gateway remediation route, and
continues the same task id so the user/Robo conversation remains one MoonBook
thread.
`POST /api/moonclaw/robot-routine` is the closed third lane. It reads MoonClaw
context before acting, calls Moonrobo live proof with the user task message,
then reads MoonClaw context again after evidence and MoonBook memory have been
refreshed. The response and persisted
`runs/moonclaw-robot-routines/{routine_id}.json` record contain
context-before, live-proof, context-after, whether memory changed, and the next
safe route.
`POST /api/moonrobo/live-proof` is the agent-facing proof wrapper around that
routine. It accepts the same MoonClaw task-loop contract, persists the combined
task-loop, readiness, and execution-proof artifact under `runs/live-proof/`,
and returns the next recovery or readiness route when the run is not yet
verified.
`GET /api/moonrobo/loop-proof` lets MoonClaw ask how far the closed robot lane
is from the desired state without re-deriving that answer from separate memory,
routine, live-proof, and execution ledgers.
`POST /api/moonrobo/prove-loop` lets MoonClaw advance that answer in one
bounded call while preserving the same safety gates and memory evidence. Each
run persists `runs/prove-loop/{proof_id}.json` and refreshes MoonBook memory
with a `closed-loop-proof` card, so the next planning turn can recall what
changed without re-reading every routine artifact.

## Memory Rule

Useful observations must be remembered in MoonBook. Otherwise agents can plan
correctly once and then forget the state on the next run.

The intended loop is:

```text
observe, review, validate, block, or execute
  -> write RoboBook evidence
  -> project MoonBook memory from that evidence
  -> persist with /api/moonbook/remember
  -> expose memory, readiness, and registered Moonrobo tools to MoonClaw and Moontown
  -> plan the next safe robot routine step
```

RoboBook is the robot decorator over the MoonBook substrate. It can point to
robot evidence and provide robot-specific projection, but long-lived recall
belongs in MoonBook memory packs.

## User Message Path

The user-facing request path should be a task path, not a parallel chat memory:

```text
user message in Rabbita or Moontown
  -> task intent
  -> resident robot context
  -> MoonClaw context or next-action plan
  -> safety-gated Moonrobo route
  -> RoboBook evidence
  -> MoonBook memory
  -> Moontown status update
```

This keeps a plain user request connected to the same evidence and safety model
as scheduled Moontown work.

## Current Gaps

The project already has the first read-only path: resident projection, bounded
observation run, replay evidence, reviews, MoonBook memory projection, work
queue, next-action planning, safe evidence dispatch, persisted tool registry,
and task-message ingress with automatic MoonBook memory persistence plus
work-queue projection. It also has the first gated physical-control path:
reviewed task-message execution through the supervised SDK runtime, a
profile-limited high-control command writer, and a dedicated emergency stop
route exposed in Rabbita. Normal sidecar execution now requires the active
runtime health probe to report `healthy` telemetry whose robot and bridge IDs
match the selected RoboBook, so the first one-to-one digital/physical mapping is
enforced at dispatch time rather than only displayed in the cockpit.
`GET /api/moonrobo/readiness` now summarizes that whole first milestone as one
read-only report: RoboBook readiness, MoonBook task-message conversation,
MoonBook memory, tool registration, runtime health, and task-execution
evidence. The same response includes a readiness plan, so agents can see the
next bounded route to call without receiving raw bridge or SDK authority.
`GET /api/moonrobo/loop-proof` is the companion proof-status route for the
proposed closed loop. It scores digital/physical mapping, Robobook/MoonBook
memory, user-message persistence, MoonClaw robot-routine evidence, Moonrobo
live-proof evidence, and verified physical feedback, then returns the next
route while the loop is incomplete.
`POST /api/moonrobo/prove-loop` is the bounded action counterpart: it
bootstraps non-physical substrate, attempts the MoonClaw robot routine through
the normal live-proof/runtime gates, and returns before/after loop-proof
evidence. The route records what changed itself by writing a compact RoboBook
proof record and a MoonBook `closed-loop-proof` memory card.
`POST /api/moonrobo/bootstrap` is the allowed first-run preparation route for
that plan. It only writes non-physical substrate evidence: bounded tool
registration, a reviewed MoonBook task message, and MoonBook memory.
`POST /api/moonrobo/advance` is the companion bounded progress route: it moves
one reviewed task message through evaluation, dry-run, and approval, then
returns a runtime-required block until live runtime health is proven.
Repeated runtime validation now writes a calibration plan, the agent work queue
projects the first blocker, and `POST /api/agent/runtime-calibration/resolve`
persists resolution evidence. Until a newer validation session exists, the
queue promotes `validate-runtime` as the next item, keeping user-message
continuation blocked on proof rather than another manual calibration review.
When that newer session is ready, stale calibration work clears from the queue.
MoonClaw `run-next` can now create that newer validation session through the
gateway and remember the result in MoonBook before the next agent turn.
MoonClaw `robot-routine` can then turn the same user-message loop into one
durable artifact with context-before, Moonrobo live proof, context-after, and
memory-change evidence. That puts the user-message path and one-to-one
digital/physical mapping at the first software proof surface; the hard gap is
collecting green routine runs on real hardware.

The remaining gap to the first goal is live hardware hardening, not a separate
chat platform:

- validating the collector, high-control writer, and bridge sidecar together
  against live SDK hardware, including one shared snapshot path, one command
  outbox, and control-gated command feedback
- validating resolved calibration evidence against live hardware and tightening
  vendor-specific emergency semantics
