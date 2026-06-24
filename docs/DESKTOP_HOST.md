# Moonrobo Desktop Host

`src/desktop_host` is the native boundary between the Rabbita cockpit and the
Lepus desktop shell. It keeps the desktop surface thin:

- static Rabbita assets are served from one UI root
- `/__moonrobo_health` reports host readiness
- `/api/health`, `/api/cockpit/snapshot`, `/api/moontown/resident`,
  `/api/moontown/tasks/*`, `/api/sessions/*`, `/api/replays/*`,
  `/api/datasets/episodes/*`, `/api/policies/*`, `/api/moonbook/*`,
  `/api/moonrobo/readiness`, `/api/moonrobo/bootstrap`,
  `/api/moonrobo/advance`, `/api/moonrobo/runtime-proof`,
  `/api/moonrobo/live-proof`, `/api/agent/*`, `/api/tools/*`, and
  `/api/intents/*` delegate to `src/host_api`
- `/api/bridge/sidecar`, `/api/runtime/supervisor`, and
  `/api/runtime/supervisor/script` use the desktop bridge host and port so the
  cockpit, supervisor plan, launch script, native execution route, and
  emergency stop route describe the same physical bridge endpoint
- `/api/runtime/validation` persists the current physical-readiness report
  that joins supervisor, telemetry, identity, and runtime-log evidence
- `/api/runtime/validation/session` repeats that validation, persists an
  aggregate session, and updates the calibration plan used by Rabbita and the
  agent work queue
- project metadata is emitted as Lepus JSON

## Commands

```text
moon run cmd/main --target native -- serve [robobook-root] [ui-root] [host] [port] [bridge-host] [bridge-port]
moon run cmd/main --target native -- host-manifest [robobook-root] [ui-root] [host] [port] [bridge-host] [bridge-port]
moon run cmd/main --target native -- desktop-project [robobook-root] [ui-root] [host] [port] [sidecar-path] [bridge-host] [bridge-port]
moon run cmd/main --target native -- desktop-bundle [robobook-root] [ui-root] [host] [port] [sidecar-path] [bundle-root] [bridge-host] [bridge-port]
moon run cmd/main --target native -- bridge-sidecar [robobook-root]
moon run cmd/main --target native -- runtime-supervisor [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-script [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-launch [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-status [robobook-root]
moon run cmd/main --target native -- runtime-health [robobook-root] [bridge-host] [bridge-port]
moon run cmd/main --target native -- runtime-validation [robobook-root] [bridge-host] [bridge-port]
moon run cmd/main --target native -- runtime-validation-session [robobook-root] [bridge-host] [bridge-port] [sample-count]
moon run cmd/main --target native -- readiness [robobook-root]
moon run cmd/main --target native -- bootstrap [robobook-root]
moon run cmd/main --target native -- advance [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-start [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-stop [robobook-root]
moon run cmd/main --target native -- task-status [robobook-root] [task-id]
```

Defaults:

```text
robobook-root: examples/noetix-e1
ui-root: ui/rabbita-cockpit
host: 127.0.0.1
port: 5290
sidecar-path: moonrobo-sidecar
bundle-root: _build/moonrobo-desktop
bridge-host: 127.0.0.1
bridge-port: 5391
```

## Boundary

The desktop host does not parse RoboBooks, evaluate safety, or talk directly to
hardware SDKs. It serves local HTTP and Lepus metadata only. Robot logic stays in
`src/core`, `src/runtime`, `src/pipeline`, `src/host_api`, and bridge packages.
`/api/bridge/sidecar` exposes the bridge process manifest owned by
`src/bridge_sidecar`: command, protocol version, health route, telemetry route,
execution route, environment, supervision policy, launchability status, and the
physical runtime process graph for the SDK collector, high-control writer, and
bridge sidecar. In the desktop host, this manifest is bound to the configured
`bridge-host` and `bridge-port` rather than the generic host API defaults.
`/api/runtime/supervisor` converts that graph into the concrete lifecycle plan:
manifest validation, collector start, snapshot wait, high-control writer start,
bridge start, health probe, and reverse stop order.
`/api/runtime/supervisor/script` returns the executable POSIX runner for the
same configured plan as `text/plain`.
`POST /api/runtime/supervisor/launch` writes that configured runner under
`runs/runtime-supervisor/{launch_id}.sh`, writes a matching JSON receipt, and
returns the exact `["sh", script_path]` command for Lepus or an outer process
manager to run. The route prepares an auditable launch artifact; it does not
silently start bridge processes inside the HTTP handler.
`GET /api/runtime/supervisor/run` reads `runs/runtime-supervisor/active.json`
and refreshes the recorded PID state.
`GET /api/runtime/health` combines that active supervisor receipt with a live
bridge telemetry probe when the process is running. Its status vocabulary is
`not-running`, `process-stopped`, `running-unprobed`, `healthy`, and
`bridge-unhealthy`, so agents and Rabbita can distinguish a missing runtime
from a live process whose robot-facing endpoint is not reachable. Each response
persists `runs/runtime-health/{health_id}.json` and updates
`runs/runtime-health/latest.json`, giving MoonBook memory and Moontown agents a
durable physical-state recall point.
`GET /api/runtime/validation` builds the operator-facing live SDK readiness
report from the same supervisor graph, runtime health snapshot, robot/bridge
identity match, and active supervisor log path. It persists
`runs/runtime-validation/{report_id}.json` and updates
`runs/runtime-validation/latest.json`; it also writes
`runs/runtime-calibration/{plan_id}.json` and
`runs/runtime-calibration/latest.json` from the same report so the task rail can
show the next calibration blocker immediately. A report is `ready` only when all
required processes are available, the collector writes the snapshot consumed by
the bridge, the writer watches the same command outbox exposed by the
control-gated bridge, the collector snapshot exists, the runtime is active,
telemetry is healthy, telemetry identity matches the selected RoboBook, and a
runtime log exists.
`POST /api/runtime/validation/session` accepts a bounded `sample_count`, runs
the same validation repeatedly, persists each sample report, writes
`runs/runtime-validation/latest-session.json`, and writes a session-derived
`runs/runtime-calibration/latest.json`. This gives the first physical milestone
evidence that the runtime is stable across repeated probes rather than only one
fresh report.
`POST /api/runtime/supervisor/start` prepares the same launch artifact, starts
it through the native process backend, and persists the active PID receipt.
`POST /api/runtime/supervisor/stop` sends the recorded supervisor PID a stop
signal and updates the active receipt. The supervisor shell trap still owns
collector, writer, and bridge cleanup.
`POST /api/runtime/emergency-stop` requires an active runtime supervisor whose
bridge endpoint matches the desktop host, posts the dedicated emergency stop
request to the bridge, writes the returned receipt, persists bridge-dispatch
evidence, and refreshes runtime health evidence. By default the desktop host
stamps the event with wall-clock milliseconds and derives
`request-emergency-stop-{now_ms}` so repeated emergency actions do not overwrite
ledger entries. Tests and scripts may submit explicit `now_ms` or `request_id`
values when deterministic evidence IDs are required. This route bypasses the
normal task-message approval chain because it is an immediate physical safety
action, but it still leaves RoboBook ledger evidence for Moontown, Rabbita, and
MoonBook memory.
`/api/moontown/resident` exposes the selected RoboBook as a read-only resident
robot projection for town surfaces.
`GET /api/moonrobo/readiness` reports the first-milestone status for that same
selected root. It joins RoboBook required-path readiness, MoonBook
task-message conversation evidence, persisted MoonBook memory, bounded tool
registration, latest runtime health, and task-execution snapshots. The response
also carries a remediation plan that maps each failing check to the next safe
route and explicitly keeps `physical_execution_allowed: false` for readiness
work. This is the operator and agent answer to "how far are we" for the
one-to-one digital/physical mapping; the route does not bypass the runtime
validation gate used by execution.
The Rabbita cockpit polls this route and renders the pass/fail counts,
conversation turns, memory cards, registered tools, task-execution snapshots,
runtime status, failing checks, and next readiness actions in the Platform
Readiness panel. The same panel exposes the first-loop controls: bootstrap the
non-physical substrate, run the bounded first-loop gate sequence, advance one
reviewed task-message gate, and ask the desktop host to fetch live bridge
telemetry as runtime proof.
`POST /api/moonrobo/bootstrap` applies the safe non-physical readiness actions
for a fresh root: it persists the bounded tool registry, writes a first reviewed
MoonBook task message, persists MoonBook memory, and returns before/after
readiness evidence. It does not start physical execution and every bootstrap
step reports `physical_execution_allowed: false`.
`POST /api/moonrobo/advance` moves one reviewed MoonBook task message through
the next safety gate: evaluation, dry-run, approval, or live-runtime dispatch.
If runtime health is missing or unhealthy, it returns `409 runtime-required`
instead of touching the sidecar.
`POST /api/moonrobo/first-loop` is the higher-level operator action for the
first milestone. It bootstraps the non-physical substrate when needed, advances
the reviewed task-message through evaluation, dry-run, and approval, and stops
with a step ledger when runtime proof or explicit dispatch approval is required.
On the native desktop host, if the bounded pass reaches `runtime-required`, the
route attempts the live bridge proof once and reruns the bounded pass so the
operator can land at `dispatch-ready` when the supervised SDK bridge is truly
healthy. By default it does not cross the final physical-dispatch boundary.
When the operator sends the same route with `allow_dispatch=true`, the desktop
host still performs the bounded pass first and only dispatches after
`dispatch-ready`; the dispatch step is routed through the native
`/api/moonbook/task-messages/{task_id}/execute-sidecar` path, not the portable
internal execution fallback.
`POST /api/moonrobo/task-loop` is the compact user-message loop. It accepts one
task message, persists the MoonBook task/conversation/memory evidence, then runs
the bounded first-loop for the accepted task id. On desktop, `allow_dispatch`
uses the same native sidecar dispatch boundary as `/api/moonrobo/first-loop`.
Without `allow_dispatch`, the loop prepares the command and stops at
`dispatch-ready`; with `allow_dispatch=true`, the response sets
`dispatch_requested: true` and the desktop host attempts the reviewed sidecar
dispatch after runtime proof is ready. The response also carries the current
task-message status, the MoonBook conversation thread, the updated Moontown
resident projection, and a `mapping` object that binds the RoboBook profile,
resident route, bridge id, runtime status, latest task, and latest execution
feedback into one digital/physical view. It also embeds `execution_proof` with
the latest task-execution snapshot id, path, verification status, and command
outcome, plus a `session` projection with the Robo session id, MoonBook thread
id, resident/mapping ids, latest user/Robo text, continuation route, dispatch
readiness, and execution verification state. Rabbita can therefore show whether
the user message actually reached verified physical execution without issuing a
second proof request or opening a separate chat store. If the desktop sidecar
dispatch is blocked by runtime startup, runtime health, or runtime validation,
the first-loop step and task-loop `recovery` object preserve the operator
recovery kind, route or evidence path, and summary so the same task surface can
show the next repair action. `POST /api/moonrobo/task-loop/continue` accepts an
existing task id and the same `allow_dispatch` flag, reruns those gates, and
returns the same task-loop response shape with `continued: true`; it does not
write a duplicate MoonBook task message.
`GET /api/moonrobo/executions` reads persisted `runs/task-executions/*.json`
snapshots and returns an execution-proof report. A snapshot is `verified` only
when the executed receipt, accepted bridge dispatch, and healthy post-dispatch
runtime proof are all present.
The resident projection also carries `latest_execution`, `execution_count`, and
`verified_execution_count`, so Moontown and MoonClaw can tell whether the latest
task is merely bridge-accepted or fully verified. When the latest execution is
not verified, `/api/agent/work-queue` emits read-only `verify-execution` work
against `/api/moonrobo/executions` before scheduling more robot work.
`POST /api/moonrobo/runtime-proof` persists the missing one-to-one physical
mapping evidence for that gate. In the native desktop host, this route requires
the active supervised runtime to match the configured bridge endpoint, fetches a
fresh telemetry frame from that bridge, writes `runs/runtime-health/latest.json`,
then verifies the frame's `robot_id` and `bridge_id` against the selected
RoboBook before returning the updated readiness report. It is evidence ingress
only; it does not execute a task or command the bridge. The portable host API
can still accept an explicit telemetry frame, but the desktop route is the
operator path for live proof. The native runtime-validation route remains the
stricter live-SDK gate for dispatch.
`POST /api/moonrobo/live-proof` is the single proof-run surface for operators
and agents that need to prove the whole loop rather than inspect separate
routes. It accepts a `MoonClawTaskLoopRequest`, runs the MoonClaw user-task
routine through Moonrobo, computes the post-run readiness plan and
task-execution proof report, persists the combined artifact under
`runs/live-proof/`, and returns `verified: true` only when the effective task
loop execution is verified and the platform readiness report is green. If
blocked, the response preserves the recovery or readiness `next_route` so
Rabbita can continue the same task instead of opening a separate chat or
operator workflow.
`/api/moontown/tasks/observe` lets a town standing goal request a read-only
observation task without taking over bridge control.
`/api/moontown/tasks/message` lets Rabbita or Moontown submit a user message as
a bounded task intent. It classifies observation, command-review, and
maintenance-review language. Observation messages start the read-only
observation session; review-classified messages persist a MoonBook task-message
plan and return the gated next route without starting hardware. Command-review
plans include a bounded intent draft so the cockpit can advance the reviewed
message through the MoonBook task-message safety routes without inventing a
second command contract. `/api/moonrobo/task-loop` wraps this lower-level route
when the caller wants the message and first-loop advancement in one request.
`GET /api/moonbook/task-messages` lists those persisted plans as a task board
with lifecycle stage, next route, and gate flags for each message.
`GET /api/moonbook/conversation` projects the same persisted messages as the
durable user/Robo conversation thread, so Rabbita and Moontown do not need a
separate chat store for the first platform slice.
`GET /api/moonbook/task-messages/{task_id}` returns one plan for operator or
agent review. `GET /api/moonbook/task-messages/{task_id}/status` projects the
task-message execution lifecycle from persisted MoonBook/RoboBook evidence:
planned, evaluated, dry-run collected, approved, runtime-required,
runtime-unhealthy, ready-to-dispatch, completed, or failed. On the desktop host
this status is enriched with the runtime health snapshot so the UI can show
whether a task is blocked by startup or by an unreachable bridge telemetry
endpoint.
The Rabbita cockpit independently polls `GET /api/runtime/health`,
`GET /api/runtime/log`, and `GET /api/runtime/validation` from the Bridge panel.
It shows the latest persisted health evidence path, telemetry status, frame id,
active supervisor log path, bounded log tail, validation report path, and
live-SDK readiness. That keeps the operator's one-to-one digital/physical
mapping visible even before a task message reaches execution.
When a reviewed task message is waiting at `runtime-required` or
`runtime-unhealthy`, the same health poll refreshes its task-message status.
The cockpit only auto-dispatches after the backend reports
`ready-to-dispatch`, which means evaluation, dry-run, approval, and runtime
health evidence are all present.
`POST /api/moonbook/task-messages/{task_id}/evaluate`, `/dry-run`, `/approve`,
and `/execute-sidecar` read the persisted intent draft, reuse the normal safety
pipeline, and record the matching evidence. Only `/execute-sidecar` can touch
the native bridge sidecar from the desktop host, and it still requires the prior
dry-run and approval evidence plus an active runtime supervisor whose
`bridge_base_url` matches the desktop host bridge endpoint. Before dispatch, the
desktop host also probes runtime health and requires `healthy` telemetry whose
`robot_id` and `bridge_id` match the selected RoboBook profile. It then writes
and enforces the runtime validation report; `/execute-sidecar` returns
`409 runtime-validation-blocked` unless live-SDK readiness is `ready`.
Execution persists both an `Executed` run receipt or failed bridge receipt and a
`runs/bridge-dispatches/{dispatch_id}.json` record for the exact bridge route,
request id, intent id, response status, produced receipt, and active supervisor
log path. It also persists a fresh MoonBook memory pack and returns that
`moonbook/memory/{pack_id}.json` path in the same response so task completion
has one durable recall artifact. The host execution response also writes
`runs/task-executions/{snapshot_id}.json`, so portable host execution and native
sidecar execution share the same task-proof ledger.
The desktop wrapper also takes a post-dispatch runtime health snapshot, writes
`runs/runtime-health/{health_id}.json`, and returns that path so task completion
can be diagnosed from the same evidence trail. The task response returns
`runs/task-executions/{snapshot_id}.json`, a compact inspection snapshot that
links the originating MoonBook task message, receipt, bridge dispatch, MoonBook
memory, runtime-health evidence, physical telemetry feedback, and supervisor
log in one place. `verified` execution now requires a matched telemetry frame at
or after the dispatch timestamp, a feedback artifact path, plus a command
outcome status for the executed capability, not only an accepted bridge
response.
`GET /api/moonrobo/executions` is the read-only projection of those snapshots
for Rabbita, MoonClaw, and Moontown.
For SDK E1 control-gated execution, the bridge writes the accepted high-control
envelope to `/tmp/moonrobo-sdk-e1-command.json`, which the supervised SDK writer
watches and publishes through the SDK binding. This keeps Rabbita, Lepus, and
Moontown on the typed Moonrobo evidence path instead of calling vendor control
objects directly.
`/api/moontown/tasks/observe-run` runs the bounded observation pipeline and
returns persisted evidence, replay, and resident state.
`/api/sessions/{session_id}/frames` appends typed telemetry frames to active
observation sessions.
`/api/replays/{session_id}` exposes a compact replay timeline for the persisted
observation telemetry artifacts.
`/api/replays/{session_id}/annotations` records and lists replay curation
labels; `/api/replays/{session_id}/annotations/{annotation_id}` reads one label.
`/api/datasets/episodes/{session_id}` exports that replay and review evidence
as a dataset episode for offline quality and learning workflows.
`/api/datasets/episodes/{session_id}/quality` reports blockers and warnings for
that episode before it is used in downstream dataset or policy workflows,
including missing curation annotations.
`POST /api/policies/evaluate` converts a learned-policy proposal into a
command intent, evaluates the safety result, writes the run receipt plus
`runs/policy-evals/{evaluation_id}.json`, and keeps
`physical_execution_allowed` false.
`GET /api/policies/evaluations` and
`GET /api/policies/evaluations/{evaluation_id}` expose that ledger for
read-only audit.
`GET /api/moonbook/memory` projects the current robot memory pack; `POST
/api/moonbook/remember` persists it under `moonbook/memory/` so MoonBook can
recall what the robot observed, latest runtime health, and what remains next.
RoboBook supplies the robot decorator and evidence projection over that
MoonBook substrate.
`GET /api/agent/work-queue` projects resident, task-message, review, replay
annotation, dataset quality, and policy ledgers into the next prioritized work
items for Rabbita and Moontown surfaces. Command task-message plans advance
through `evaluate-command-message`, `dry-run-command-message`,
`approve-command-message`, and `execute-command-message` as the corresponding
MoonBook receipts, dry-run evidence, approval records, and bridge dispatch
records appear.
`GET /api/agent/next-action` adds the route/method/body contract and optional
safe request body template for the top work item while keeping physical
execution disallowed.
For task-message review work, Rabbita uses the GET next action to open
`/api/moonbook/task-messages/{task_id}` and render the persisted plan as
operator evidence: classification, gated route, suggested capability, review
requirement, and `physical_execution_allowed: false`.
`POST /api/agent/dispatch-next` submits the selected safe evidence action from
that contract. It only dispatches allowlisted non-physical POST routes and
returns both the request body and downstream response for audit.
`GET /api/tools/registry` persists and returns the bounded provider registry
under `agents/tool-registry.json`. `POST /api/tools/register` replaces or
appends one provider entry and rejects any provider that attempts to grant
physical execution authority.

Rabbita or Moontown can expose this as a user message surface without becoming a
separate chat platform. The message is converted to a task intent by
`/api/moontown/tasks/message`, remembered in MoonBook after accepted planning,
and only allowlisted evidence actions can be dispatched from the desktop host.

The current server handles accepted TCP connections concurrently and closes each
connection after one HTTP response. This keeps the first desktop sidecar simple
while supporting browser burst loads for the Rabbita shell and API routes.

`POST /api/intents/evaluate` accepts one command-intent submission, evaluates it
through the safety pipeline, writes a RoboBook receipt, and returns the pipeline
result. `POST /api/intents/dry-run` and `POST /api/intents/approve` write the
evidence IDs needed for a later ready evaluation. `POST /api/intents/execute`
revalidates that evidence and records bridge completion through the execution
boundary by writing the executed receipt plus the bridge dispatch evidence. The
portable local host route uses deterministic completion. Native operators first
start or verify the runtime with `runtime-supervisor-start` /
`runtime-supervisor-status`, then use
`moon run cmd/main --target native -- execute-message-sidecar` to send the same
reviewed MoonBook task message to the SDK sidecar over HTTP and persist the
actual bridge response. The SDK sidecar is read-only by default, while the
supervised runtime launches it in `control-gated` mode with a command outbox for
allowlisted high-control walk/run command envelopes; any bridge rejection still
becomes a failed receipt with `bridge_error`. `moon run cmd/main --target native -- message-sidecar`
combines user message submission, safety evidence collection, sidecar dispatch,
and ledger persistence into one operator command, with the same active-runtime
preflight.
`POST /api/sessions/observe`, `POST /api/sessions/{id}/frames`, and
`POST /api/sessions/{id}/stop` record read-only observation session evidence
under `runs/observations/` and `runs/telemetry/`.
`POST /api/moontown/tasks/observe-run` composes those routes into one desktop
host contract for scheduled observation runs.
`GET /api/replays/{session_id}` reads that session plus its sorted
`runs/telemetry/{session_id}/` frames and returns the timeline used by Rabbita
and town surfaces.
`POST /api/replays/{session_id}/annotations` writes
`runs/annotations/{session_id}/{annotation_id}.json` after confirming the
session exists. The matching `GET` routes expose those labels for dataset
curation.
`GET /api/datasets/episodes/{session_id}` reads the same session, telemetry
frames, and matching process review to emit a replayable dataset episode.
`GET /api/datasets/episodes/{session_id}/quality` evaluates that episode for
minimum replayability, review acceptance, and replay curation.
`POST /api/policies/evaluate` is the offline policy gate. It is deliberately
separate from `/api/intents/execute`, so policy output can be reviewed,
simulated, and recorded without moving hardware.
`GET /api/moonstat/status` includes the latest policy gate and ledger path for
the Rabbita cockpit and suite status surfaces.
`GET /api/moonbook/memory` and `POST /api/moonbook/remember` bridge RoboBook
evidence into MoonBook memory cards for resident state, latest evidence, and
next work.
`GET /api/agent/work-queue` is the desktop task rail contract: it identifies
whether the next operator or agent action is bridge connection, evidence review,
replay annotation, dataset repair, policy dry-run, policy approval, or offline
policy evaluation. It also projects the latest runtime calibration plan into a
high-priority `calibrate-runtime` item before observation or command work when
`runs/runtime-calibration/latest.json` still contains blockers.
`GET /api/agent/runtime-calibration/latest` exposes that latest calibration
plan as read-only JSON for the task rail. `POST
/api/agent/runtime-calibration/resolve` accepts the selected calibration action,
resolver, timestamp, and note, writes a resolution receipt under
`runs/runtime-calibration/resolutions/`, and returns the next validation route
so Rabbita can immediately collect another repeated runtime-validation session.
While that resolution is newer than the latest validation session,
`/api/agent/work-queue` promotes `validate-runtime` above ordinary bridge and
observation work, forcing the loop to prove the calibration fix before command
continuation. Once a newer ready validation session is persisted, stale
calibration plans no longer contribute work-queue pressure.
The Bridge panel can prepare a runtime supervisor launch receipt through
`POST /api/runtime/supervisor/launch`, making the launch script, command, and
receipt path visible before any outer process manager starts the physical
runtime. It can also call `/start` and `/stop` to let the desktop host own the
runtime supervisor PID directly.
`GET /api/runtime/log` returns only the active supervisor's configured log path
and a bounded tail, so Rabbita can diagnose collector, writer, and bridge
startup without reading arbitrary files or loading a full runtime log.
`GET /api/agent/next-action` is the action-plan contract consumed by the
Rabbita task rail. It carries a safe draft request body for mutating evidence
routes, remains read-only planning metadata, and never starts bridge processes
or moves hardware.
Task-message review actions are intentionally GET-only and show the persisted
MoonBook plan in the cockpit instead of dispatching a command.
`POST /api/agent/dispatch-next` is the matching evidence dispatcher. It can
write replay annotations, run bounded observation evidence collection, or record
offline policy evaluation only when the selected queue action has a safe body
template and `physical_execution_allowed` remains false.

## Verification

The native test suite includes a browser-burst smoke test that starts the host
and requests the Rabbita root, readiness route, API health route, and cockpit
snapshot route at the same time.

`src/desktop_bundle` now writes the Lepus project descriptor, host manifest,
combined bundle manifest, `moonrobo.release-build.sh`,
`moonrobo.desktop-launch.sh`, and `moonrobo.runtime-supervisor.sh`. The
bundle-owned Lepus command is `sh moonrobo.desktop-launch.sh`, which starts the
physical runtime supervisor and the desktop host together on the same configured
bridge host and port. The release build
script installs the native desktop host and SDK bridge into bundle-local `bin/`
paths and copies the Rabbita build into bundle-local `ui/`, so packaged
operation no longer serves the source UI tree.
