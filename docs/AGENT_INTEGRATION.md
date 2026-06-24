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
creating a second durable conversation store. `GET /api/moonrobo/session`
returns that same session projection as a read-only restore/context route,
including conversation, resident mapping, execution proof, latest turn artifact,
and current MoonBook memory. After a runtime or calibration blocker is resolved,
agents should call
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
requires the feedback artifact to echo the command capability, intent id, bridge
request id, receipt id, and persisted motion parameters, so plain body telemetry
remains observed rather than verified.
`POST /api/moonrobo/executions/feedback` is the bounded agent/runtime gateway
for closing that proof after dispatch. It accepts a telemetry frame for an
existing `snapshot_id`, persists it under RoboBook telemetry, validates
robot/bridge identity plus command echo evidence, rewrites the task execution
snapshot, and refreshes MoonBook memory. It cannot create a task execution or
bypass the receipt/dispatch gates.
The same proof state is now carried by the Moontown resident projection,
MoonBook memory pack, agent work queue, and MoonClaw context: an unverified
latest execution becomes `bind-execution-feedback` work against
`POST /api/moonrobo/executions/feedback` before the robot resident schedules
more physical-world processes. `/api/moonrobo/executions` remains the read-only
evidence projection for that work. The parallel immediate-safety path is
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
- run MoonClaw robot-routine and Moonrobo live-proof routes through the gateway
- propose command intents for safety evaluation

MoonClaw must not receive raw bridge authority, vendor SDK handles, or direct
low-level control loops. Any physical execution still has to pass through the
Moonrobo safety gate, bridge protocol, approval evidence, bridge dispatch
ledger, and receipt ledger.
Bridge sidecars expose `GET /contract` as the typed authority manifest for that
boundary. It tells agents which operations exist, which routes can move
hardware, which routes require an intent or session id, and which hardware
motion routes are disabled while the sidecar is read-only. Agents should reason
from that contract plus Moonrobo readiness instead of guessing bridge routes.
Runtime validation now probes the same live contract and blocks physical
dispatch unless it matches the selected RoboBook identity and enables the
required hardware-motion routes, so the agent-visible authority surface and the
dispatch gate use the same evidence. Moonrobo persists successful live contract
probes under RoboBook `runs/bridge-contracts/`, which gives MoonClaw and
MoonBook a durable artifact for the authority surface it reasoned about.
`GET /api/agent/next-action` now resolves method, route, body schema,
execution mode, and safety note metadata from the persisted
`GET /api/tools/registry` capability entries whenever a queued item maps to a
registered tool. This makes the registry the route-authority surface for
MoonClaw and Rabbita instead of leaving the robot routine lane as hidden
hardcoded knowledge.

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
context-before, live-proof, optional work-run recovery, optional recovered live
proof, context-after, whether memory changed, and the next safe route. If the
first live proof is not verified, the routine runs one bounded
`/api/moonclaw/work-run` and retries live proof once when safe work was
dispatched.
`POST /api/moonclaw/work-step` is the fourth lane for routine queue
consumption. It wraps exactly one safe `/api/agent/dispatch-next` call,
persists the dispatch outcome under `runs/moonclaw-work-steps/`, and remembers
the resulting MoonBook memory pack. Runtime validation is included in the safe
dispatch allowlist because it probes gateway readiness and authority evidence
without moving hardware.
`POST /api/moonclaw/work-run` is the bounded loop over that lane. It repeatedly
consumes safe work, persists each step, remembers one final MoonBook memory
pack, and writes `runs/moonclaw-work-runs/{run_id}.json`. The run halts on
empty queue, blocked/planning-only work, or its configured step limit, giving
MoonClaw an agentic loop without bypassing Moonrobo safety gates.
`POST /api/moonrobo/live-proof` is the agent-facing proof wrapper around that
routine. It accepts the same MoonClaw task-loop contract, persists the combined
task-loop, readiness, and execution-proof artifact under `runs/live-proof/`,
and tries to bind the latest unverified execution from current runtime
telemetry before projecting the proof. The response exposes
`auto_feedback_bound`, `auto_feedback_verified`, and `auto_feedback_message` so
MoonClaw can decide whether it has fresh physical-world evidence in the same
turn. It returns the next recovery or readiness route when the run is not yet
verified.
`GET /api/moonrobo/live-readiness` is the agent preflight route before another
live proof run. MoonClaw can read one object that joins the latest repeated
runtime validation session, session-derived calibration plan, proof-session
history, and loop-proof state. The response tells the routine whether to run
runtime validation, resolve calibration, collect a bounded proof session, or
submit the next task message after the loop is verified.
`GET /api/moonclaw/context` exposes that same live-readiness object and
proof-session ledger next to the MoonClaw planning result, keeping the agentic
routine, Moontown resident state, Rabbita cockpit, and MoonBook memory grounded
in the same current robot-loop evidence.
`GET /api/moonrobo/loop-proof` lets MoonClaw ask how far the closed robot lane
is from the desired state without re-deriving that answer from separate memory,
routine, live-proof, and execution ledgers. If the latest robot routine has a
recovered live proof, loop-proof uses that recovered proof as the effective
live-proof artifact.
`POST /api/moonrobo/prove-loop` lets MoonClaw advance that answer in one
bounded call while preserving the same safety gates and memory evidence. Each
run persists `runs/prove-loop/{proof_id}.json` with the effective live-proof
path and refreshes MoonBook memory with a `closed-loop-proof` card, so the next
planning turn can recall what changed without re-reading every routine artifact.
`POST /api/moonrobo/proof-session` is the repeated version of that contract. It
runs bounded prove-loop attempts, gives each attempt its own task/proof
artifact, stops when the loop is verified or when the same blocker repeats, and
persists `runs/proof-sessions/{session_id}.json`. MoonClaw and Moontown should
schedule this route for sustained physical proof collection instead of creating
another chat, scheduler, or memory lane. `GET /api/agent/work-queue` now emits
`run-proof-session` when the closed loop remains incomplete; `GET
/api/agent/next-action` resolves that item to a bounded
`PlatformProofSessionRequest` with `allow_dispatch: false`, so agent dispatch
can collect proof evidence without autonomous physical actuation. The latest
proof-session record is also projected into the resident robot and MoonBook
memory, so MoonClaw can plan from durable loop state instead of remembering a
single transient response. `GET /api/moonrobo/proof-sessions` and
`GET /api/moonrobo/proof-sessions/{session_id}` expose the persisted session
history for audit and recovery without scheduling another proof run.

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
MoonBook memory, tool registration, persisted bridge-contract authority,
runtime health, and task-execution evidence. The same response includes a
readiness plan, so agents can see the next bounded route to call without
receiving raw bridge or SDK authority.
`POST /api/moonrobo/ask` is the user-facing ingress for "ask Robo to do this."
It accepts the same MoonBook task-message request as
`/api/moontown/tasks/message`, persists the same RoboBook/MoonBook evidence,
refreshes memory through the existing path, and then returns
`GET /api/moonrobo/decision` in the same response. It is intentionally a thin
wrapper, not a separate chat platform; the durable conversation remains
MoonBook task messages.
`POST /api/moonrobo/loop` is the canonical product loop that agents and UI
surfaces should prefer when they want "take the user's request as far as the
safe current state allows." Its request can include one `RoboTurnRequest`; the
loop records that as a non-agent-running turn, then repeatedly advances only
MoonClaw-owned decisions through `POST /api/moonrobo/step` until the decision is
ready for another task, operator-owned, blocked, or the bounded step cap is
reached. The response includes the persisted turn, every step artifact, the
restored session, the final decision, and a compact status. Artifacts are stored
under `runs/robo-loops/`; `GET /api/moonrobo/loops` and
`GET /api/moonrobo/loops/{loop_id}` expose them without replaying work.
`POST /api/moonrobo/turn` is the bounded one-cycle product loop. It first runs
the same ask path, then only if the returned decision is `agent-work-ready`, it
calls MoonClaw work-run with the requested step cap and returns the after-run
decision. Each turn is persisted under `runs/robo-turns/`, giving Rabbita and
Moontown a replayable unit for "what the user asked, what MoonClaw did, and
what Robo decided next" while keeping operator-bound review and physical
dispatch gates intact. Rabbita's default "Ask Robo" action uses this route,
not the heavier proof routine; proof and dispatch controls stay explicit.
`POST /api/moonrobo/step` advances the already-restored session without adding
another MoonBook task message. It is the gateway action for "the current
decision says MoonClaw owns the next move": Moonrobo runs bounded work-run,
persists a Robo step artifact, refreshes MoonBook memory through that work-run,
and returns the before/after decisions. If the decision belongs to the operator
or the loop is waiting for a new task, the step is a recorded no-op rather than
a bypass around safety gates.
`GET /api/moonrobo/steps` and `GET /api/moonrobo/steps/{step_id}` expose the
same step artifacts as read-only history. They let Rabbita, Moontown, and
MoonClaw reconstruct which decisions were advanced after a user turn without
replaying agent work.
`GET /api/moonrobo/turns` and `GET /api/moonrobo/turns/{turn_id}` expose that
turn ledger back to Rabbita, Moontown, and MoonClaw. The list route returns the
persisted turn artifacts in RoboBook order; the detail route opens the exact
ask/work-run/decision artifact for audit or replay. Rabbita now loads the list
route as the visible Robo turn history, so the one-to-one task surface survives
reloads without inventing a second chat store.
`GET /api/moonrobo/session` is the canonical restore surface for that product
loop. It joins the MoonBook conversation, Moontown resident, digital/physical
mapping, execution proof, latest turn, turn count, MoonBook memory, and the
latest step, step count, and same current decision in one read-only response.
Rabbita should use this route
to restore "who is Robo, what did the user ask, what does Robo remember, and
who owns the next action"; `/api/moonrobo/decision` remains available for
callers that need only the compact control answer.
`GET /api/moonrobo/decision` is the compact control answer Rabbita, Moontown,
and MoonClaw should read first. It joins readiness, loop proof, the agent work
queue, and registered tool capabilities into one owner/route decision:
`needs-operator` for explicit review or runtime setup, `agent-work-ready` when
MoonClaw can safely continue through `/api/moonclaw/work-run`, and `ready` when
the loop is proven and the next useful input is another Moontown task message.
The decision carries both the caller route and the target gateway route, so the
UI does not have to infer whether it should ask the operator or let MoonClaw
collect bounded evidence.
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
Validation sessions expose mapping proof over observed robot and bridge ids, so
the agent loop can distinguish "runtime is healthy" from "runtime is healthy
for this RoboBook body."
The same work rail now treats missing live bridge-contract authority as a
validation blocker after the sidecar is launchable. A failed
`bridge-contract-ready` readiness check becomes `validate-runtime` work pointed
at `/api/runtime/validation/session`, which lets MoonClaw collect contract
evidence through the gateway and remember the result before user-message
execution resumes.
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
