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
tasks immediately, and restores status after reload.
`POST /api/moonrobo/gateway/command` is the Moonrobo ingress for a
MoonClaw-authored robot command: MoonClaw decides the routine step, while
Moonrobo records the command as task ingress, refreshes MoonBook memory through
the task path, and returns the next safe route. The response carries the latest
task state, MoonBook conversation thread, Moontown resident projection, explicit
digital/physical mapping, compact execution proof, and current decision route.
Rabbita can render one Robo chat/task surface plus the latest snapshot
verification state without creating a second durable conversation store.
`GET /api/moonrobo/session` returns that same session projection as a read-only
restore/context route, including conversation, resident mapping, execution proof,
latest turn artifact, and current MoonBook memory. After a runtime or
calibration blocker is resolved, agents should submit the next MoonClaw-chosen
command through the gateway with the user’s current task intent; MoonBook keeps
the durable context.
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
- read work-queue evidence and registered tool capabilities
- call explicit Moonrobo tool routes selected by MoonClaw routine policy
- run MoonClaw gateway-command and Moonrobo proof-session routes through the gateway
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
`GET /api/agent/work-queue` and `GET /api/tools/registry` are the route
authority surfaces for MoonClaw and Rabbita. The queue says what pressure
exists and which target route is relevant; the registry says which bounded
capabilities Moonrobo exposes. MoonClaw combines those facts with its routine
policy and chooses the explicit route call.
When live readiness says the gateway is ready for routine work and the aggregate
closure is missing, the queued item is `run-live-exercise` with target route
`POST /api/moonrobo/live-exercise`. MoonClaw or an operator may call it
intentionally because the route itself performs validation, routine,
proof-session, and MoonBook memory gates.
The lower-level `submit-gateway-command` item now points at
`POST /api/moonrobo/gateway/command` with a `MoonroboGatewayCommandRequest`.
MoonClaw remains responsible for deciding the command; Moonrobo only accepts
the resulting gateway/task ingress and writes durable evidence.

Moonrobo workers and suite tools used by MoonClaw should also register as
bounded capability providers. They can update project artifacts, run validation,
summarize evidence, or prepare plans when granted those capabilities, but they
must still use MoonBook memory and Moonrobo audit routes when their work changes
the robot agenda.

`GET /api/moonrobo/status` is the product-level milestone answer for agents and
suite shells. It scores the first usable physical-agent loop across seven
capabilities: one RoboBook-to-resident mapping, user task message, MoonBook
memory, MoonClaw gateway command evidence, live-runtime readiness, verified
physical feedback, and live-exercise closure. Use it when the question is "how
far are we from the desired Moonrobo loop?" The status capabilities now include
the latest live-exercise closure as the aggregate
validation/routine/proof/feedback/memory gate, then agents can drill into
gateway, readiness, proof, or memory routes only for detail.

`GET /api/moonrobo/gateway-status` is the compact standalone gateway answer for
agents and product shells, backed by the package-level `src/gateway` projection
rather than ad hoc host-route stitching. It joins the current Robo session,
loop proof, and live-readiness state into one object with mapped status, memory
card count, loop percent, verified/live-readiness flags, latest evidence paths,
and the next safe route. MoonClaw and Rabbita should use this route when they
need to decide whether Moonrobo is verified, ready for a gateway command, or
blocked on evidence, then drill into `/api/moonrobo/session`,
`/api/moonrobo/loop-proof`, or `/api/moonrobo/live-readiness` only for detail.

`GET /api/moonclaw/context` now carries the current MoonBook memory pack,
embedded work queue, bounded tool registry, platform readiness report,
readiness plan, and compact Moonrobo gateway status inside an evidence-only
context pack. MoonClaw can therefore see what the robot last observed, which
work item is currently highest priority, which Moonrobo routes are registered
tools, whether calibration or validation must be remediated, and whether the
standalone physical gateway is verified, command-ready, or still missing
evidence before choosing the next process step in MoonClaw.

## Closed Robot Routine

The gateway command is the third MoonClaw lane beside coding and general work. It
is not a new robot controller. It is the agentic planner that talks to the
Moonrobo gateway server and lets Moonrobo own physical authority:

```text
MoonClaw gateway command
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

Moonrobo no longer exposes `POST /api/moonclaw/run-next` or a MoonClaw run
ledger. Those routes made Moonrobo host policy. MoonClaw should read
`GET /api/moonclaw/context`, use the embedded `work_queue`, MoonBook memory,
readiness plan, gateway status, and registered tool capabilities to select a
Moonrobo tool or gateway command, call that route directly, and then rely on
Moonrobo/MoonBook evidence for the next step.
`POST /api/moonrobo/gateway/command` is the Moonrobo-side ingress for that
lane. MoonClaw owns the gateway command policy: it reads context, chooses the
next bounded step, and submits the resulting command through the Moonrobo
gateway. Moonrobo accepts that command as durable task input, records the
gateway artifact under `runs/gateway-commands/{command_id}.json`, persists the
MoonBook task message, and returns the next safe route. This removes the old
boundary drift where Moonrobo appeared to host part of the MoonClaw routine
policy just to keep the early demo loop end-to-end. The remaining Moonrobo
logic is gateway/interface logic: validate the mapped RoboBook identity,
persist task ingress, expose registered capabilities, and leave evidence for
MoonClaw to remember and plan from.
Moonrobo used to carry a local `/api/moonclaw/work-step` and
`/api/moonclaw/work-run` proof harness. That code was intentionally removed
from the active surface because it placed part of the agent loop in Moonrobo.
Moonrobo now exposes context, registered tool capabilities, gateway command
ingress, and RoboBook evidence; MoonClaw owns the bounded routine and calls the
Moonrobo route it selected.
`POST /api/moonrobo/proof-session` is the agent-facing sustained proof surface
around that routine. It repeats bounded prove-loop attempts, persists the
session under `runs/proof-sessions/`, and projects the latest proof, readiness,
and next safe route so MoonClaw can decide whether it has enough
physical-world evidence in the same
turn. It returns the next recovery or readiness route when the run is not yet
verified.
`GET /api/moonrobo/live-readiness` is the agent preflight route before another
proof-session or gateway-command attempt. MoonClaw can read one object that joins the latest repeated
runtime validation session, session-derived calibration plan, proof-session
history, and loop-proof state. The response tells the routine whether to run
runtime validation, resolve calibration, collect a bounded proof session, or
submit the next task message after the loop is verified. It also carries the
latest proof-session automatic feedback counts/status/message so MoonClaw can
see whether sustained proof collection already closed the physical-feedback
gate without opening each prove-loop artifact.
`GET /api/moonclaw/context` exposes that same live-readiness object and
proof-session ledger inside the MoonClaw context pack, keeping the external
agentic routine, Moontown resident state, Rabbita cockpit, and MoonBook memory
grounded in the same current robot-loop evidence.
`GET /api/moonrobo/loop-proof` lets MoonClaw ask how far the closed robot lane
is from the desired state without re-deriving that answer from separate memory,
routine, Robo loop, and execution ledgers. If the latest gateway command has a
persisted `robo_loop`, loop-proof uses that loop artifact as the routine's
canonical evidence. Its physical-feedback check accepts either a verified task
execution snapshot or the latest durable proof-session artifact with successful
automatic feedback closure, so pruning the raw execution ledger does not split
the product answer from MoonBook's remembered proof state.
`POST /api/moonrobo/prove-loop` lets MoonClaw advance that answer in one
bounded call while preserving the same safety gates and memory evidence. Each
run attempts the MoonClaw gateway command, then binds execution feedback through
the explicit `/api/moonrobo/executions/feedback` route when latest runtime
telemetry can verify the executed snapshot. It persists
`runs/prove-loop/{proof_id}.json` with the effective Robo loop path and
refreshes MoonBook memory with a `closed-loop-proof` card, so the next planning
turn can recall what changed without re-reading every routine artifact.
`POST /api/moonrobo/proof-session` is the repeated version of that contract. It
runs bounded prove-loop attempts, gives each attempt its own task/proof
artifact, stops when the loop is verified or when the same blocker repeats, and
persists `runs/proof-sessions/{session_id}.json`. The session record rolls up
automatic feedback-bind attempts, successful feedback binds, and the latest
feedback status/message so sustained physical proof is visible without opening
every individual prove-loop artifact. MoonClaw and Moontown should schedule
this route for sustained physical proof collection instead of creating another
chat, scheduler, or memory lane. `GET /api/agent/work-queue` now emits
`run-proof-session` when the closed loop remains incomplete, with the bounded
proof-session route as its target. MoonClaw chooses when to call that route
instead of relying on Moonrobo to dispatch a generic agent action. The latest
proof-session record is also projected into the resident robot and MoonBook
memory with its feedback closure counts/status/message, so MoonClaw can plan
from durable loop state instead of remembering a single transient response.
That same durable feedback closure is accepted by loop-proof as physical
feedback evidence, keeping Rabbita, MoonClaw, Moontown, and MoonBook on one
closed-loop answer.
`GET /api/moonrobo/proof-sessions` and
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
  -> plan the next safe gateway command step
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
  -> MoonClaw context, work queue, and tool registry
  -> MoonClaw-selected safety-gated Moonrobo route
  -> RoboBook evidence
  -> MoonBook memory
  -> Moontown status update
```

This keeps a plain user request connected to the same evidence and safety model
as scheduled Moontown work.

## Current Gaps

The project already has the first read-only path: resident projection, bounded
observation run, replay evidence, reviews, MoonBook memory projection, work
queue, persisted tool registry, and task-message ingress with automatic
MoonBook memory persistence plus work-queue projection. It also has the first
gated physical-control path:
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
the MoonBook conversation thread, refreshed memory pack, loop proof, live
readiness, and `GET /api/moonrobo/decision` in the same response. It is
intentionally the user-facing wrapper over MoonBook task messages, not a
separate chat platform; the durable conversation remains MoonBook.
`POST /api/moonrobo/loop` is the canonical product loop that agents and UI
surfaces should prefer when they want "take the user's request as far as the
safe current state allows." Its request can include one `RoboTurnRequest`; the
loop records that as a non-agent-running turn, then returns the current owner
decision. Moonrobo does not run MoonClaw's policy loop locally. The response includes the persisted turn, every step artifact, the
restored session, the final decision, and a compact status. Artifacts are stored
under `runs/robo-loops/`; `GET /api/moonrobo/loops` and
`GET /api/moonrobo/loops/{loop_id}` expose them without replaying work.
`POST /api/moonrobo/turn` is the bounded one-cycle product loop. It first runs
the same ask path and returns the post-ask decision without running agent work.
Each turn is persisted under `runs/robo-turns/`, giving Rabbita and Moontown a
replayable unit for "what the user asked and who owns the next action" while
keeping operator-bound review and physical dispatch gates intact. Rabbita reads
this ledger as component history after the canonical loop runs; proof and
dispatch controls stay explicit.
`POST /api/moonrobo/step` advances the already-restored session without adding
another MoonBook task message. It is the gateway action for "the current
decision says MoonClaw owns the next move": Moonrobo records the pending
decision and target route, but MoonClaw must execute the selected routine/tool.
If the decision belongs to the operator or the loop is waiting for a new task,
the step is a recorded no-op rather than a bypass around safety gates.
`GET /api/moonrobo/steps` and `GET /api/moonrobo/steps/{step_id}` expose the
same step artifacts as read-only history. They let Rabbita, Moontown, and
MoonClaw reconstruct which decisions were advanced after a user turn without
replaying agent work.
`GET /api/moonrobo/turns` and `GET /api/moonrobo/turns/{turn_id}` expose that
turn ledger back to Rabbita, Moontown, and MoonClaw. The list route returns the
persisted turn artifacts in RoboBook order; the detail route opens the exact
ask/decision artifact for audit or replay. Rabbita now loads the list
route as the visible Robo turn history, so the one-to-one task surface survives
reloads without inventing a second chat store.
`GET /api/moonrobo/session` is the canonical restore surface for that product
loop. It joins the MoonBook conversation, Moontown resident, digital/physical
mapping, execution proof, latest loop summary, loop count, latest turn, turn
count, latest step, step count, MoonBook memory, and the same current decision
in one read-only response.
Rabbita should use this route
to restore "who is Robo, what did the user ask, what does Robo remember, and
who owns the next action"; `/api/moonrobo/decision` remains available for
callers that need only the compact control answer.
`GET /api/moonrobo/decision` is the compact control answer Rabbita, Moontown,
and MoonClaw should read first. It joins readiness, loop proof, the agent work
queue, and registered tool capabilities into one owner/route decision:
`needs-operator` for explicit review or runtime setup, `agent-work-ready` when
MoonClaw owns the next registered Moonrobo tool call, and `ready` when the loop
is proven and the next useful input is another Moontown task message.
The decision carries both the caller route and the target gateway route, so the
UI does not have to infer whether it should ask the operator or let MoonClaw
collect bounded evidence.
`GET /api/moonrobo/loop-proof` is the companion proof-status route for the
proposed closed loop. It scores digital/physical mapping, Robobook/MoonBook
memory, user-message persistence, MoonClaw gateway-command evidence, Moonrobo
Robo loop evidence, and verified physical feedback, then returns the next
route while the loop is incomplete.
`POST /api/moonrobo/prove-loop` is the bounded action counterpart: it
bootstraps non-physical substrate, attempts the MoonClaw gateway command through
the canonical Robo loop, and returns before/after loop-proof
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
The same work rail now treats missing runtime health before missing
bridge-contract authority. A cold root points first to
`/api/runtime/supervisor/start`; after the runtime can answer, a failed
`bridge-contract-ready` readiness check becomes `validate-runtime` work pointed
at `/api/runtime/validation/session`, which lets MoonClaw collect contract
evidence through the gateway and remember the result before user-message
execution resumes.
MoonClaw can create that newer validation session through the explicit
Moonrobo route selected from context and remember the result in MoonBook before
the next agent turn. MoonClaw can then turn the same user-message loop into a
gateway command and durable task artifact without moving the policy code into
Moonrobo. That puts the user-message path and one-to-one digital/physical
mapping at the first software proof surface; the hard gap is collecting green
command/proof runs on real hardware.
`POST /api/moonrobo/live-exercise` is the aggregate lane for that hardening
work: it persists runtime validation, gateway command, proof-session, and MoonBook
memory into one `runs/live-exercises/` artifact so MoonClaw can compare repeated
physical-world attempts instead of piecing together separate records. The
artifact's `closure` field is the agent-facing checklist: it reports whether
the loop is closed and names any missing validation, routine, proof, feedback,
or MoonBook memory gate.
`GET /api/moonrobo/live-closure` is the compact read side for the newest
closure only. MoonClaw should use it when it needs the next missing physical
gate without reopening or comparing every live-exercise artifact.
`GET /api/moonrobo/live-exercises` and
`GET /api/moonrobo/live-exercises/{exercise_id}` are the read side of that lane,
so MoonClaw and Rabbita can inspect repeated attempts without triggering another
gateway command or proof session.
`GET /api/moonclaw/context` embeds that same compact closure beside
live-readiness, proof-session history, and the live-exercise list, so MoonClaw
can choose the next robot
routine or aggregate hardening run from durable closure evidence instead of
transient chat context.

The remaining gap to the first goal is live hardware hardening, not a separate
chat platform:

- validating the collector, high-control writer, and bridge sidecar together
  against live SDK hardware, including one shared snapshot path, one command
  outbox, and control-gated command feedback
- validating resolved calibration evidence against live hardware and tightening
  vendor-specific emergency semantics
