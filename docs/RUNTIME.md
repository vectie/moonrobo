# Moonrobo Runtime Slice

This slice turns the planning documents into a native MoonBit runtime path that
Rabbita and Lepus can build on.

## Current Runtime Boundary

The current runtime is intentionally small:

- load a RoboBook from disk
- decode `robot.json` into the MoonBit `RobotProfile` contract
- inspect required RoboBook paths
- produce deterministic mock telemetry
- pass a command intent through the safety pipeline
- start and stop read-only observation sessions with RoboBook evidence
- ingest typed telemetry frames into active observation sessions
- summarize persisted observation telemetry as replay timelines
- annotate replay sessions and frames for dataset curation
- project the selected robot as a Moontown resident agent
- accept a Moontown observation task and route it through the same evidence flow
- accept a user task message, classify it into observation or review work, and
  persist MoonBook memory plus task-message plan evidence
- run a bounded observation pipeline that starts, samples, stops, replays, and
  projects resident state
- record learned-policy proposals as receipt-only evaluations and expose the
  policy evaluation ledger for audit
- project a prioritized agent work queue from resident, task-message, review,
  dataset, replay annotation, and policy evidence
- project and persist MoonBook memory packs that summarize resident state,
  latest evidence, and next work
- expose a physical runtime manifest that binds the SDK collector, shared
  snapshot file, high-control command writer, command outbox file, and bridge
  sidecar into one supervised process graph
- poll the localhost SDK bridge sidecar through a native HTTP bridge client and
  feed those telemetry frames into the same bounded observation pipeline
- refresh `/api/runtime/health` from the Rabbita cockpit so the runtime panel
  continuously shows the latest persisted RoboBook health evidence
- persist `/api/runtime/validation` readiness reports that join supervisor
  readiness, active runtime state, live telemetry health, robot/bridge identity,
  and runtime-log evidence
- re-query reviewed task-message status from runtime health changes and dispatch
  through `/execute-sidecar` once the backend reports `ready-to-dispatch`

It does not expose arbitrary motion, low-control APIs, learned-policy actuation,
or autonomous physical loops. The current shape is enough for the first
one-to-one digital/physical mapping: one selected robot profile, one
MoonBook-backed RoboBook decorator, one supervised SDK runtime, one bridge
status, one command outbox, one resident projection, one replay/evidence trail,
and one memory pack that can be remembered. The remaining gap before routine
physical use is repeated hardware validation of the live writer and validation
report, stronger vendor-specific stop semantics if available, and
operator-facing calibration limits.

## Native CLI

The native CLI is the first stable integration seam:

```text
moon run cmd/main --target native -- inspect [robobook-root]
moon run cmd/main --target native -- mock [robobook-root]
moon run cmd/main --target native -- cockpit [robobook-root]
moon run cmd/main --target native -- cockpit-sdk-file [robobook-root] [snapshot-json]
moon run cmd/main --target native -- resident [robobook-root]
moon run cmd/main --target native -- runtime-supervisor [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-script [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-launch [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-status [robobook-root]
moon run cmd/main --target native -- runtime-health [robobook-root] [bridge-host] [bridge-port]
moon run cmd/main --target native -- runtime-validation [robobook-root] [bridge-host] [bridge-port]
moon run cmd/main --target native -- runtime-validation-session [robobook-root] [bridge-host] [bridge-port] [sample-count]
moon run cmd/main --target native -- runtime-supervisor-start [robobook-root]
moon run cmd/main --target native -- runtime-supervisor-stop [robobook-root]
moon run cmd/main --target native -- work-queue [robobook-root]
moon run cmd/main --target native -- next-action [robobook-root]
moon run cmd/main --target native -- observe-task [robobook-root] [task-id]
moon run cmd/main --target native -- observe-run [robobook-root] [task-id] [frame-count]
moon run cmd/main --target native -- observe-run-sidecar [robobook-root] [task-id] [frame-count] [host] [port]
moon run cmd/main --target native -- replay [robobook-root] [session-id]
moon run cmd/main --target native -- annotate-replay [robobook-root] [session-id] [frame-id]
moon run cmd/main --target native -- replay-annotations [robobook-root] [session-id]
moon run cmd/main --target native -- replay-annotation [robobook-root] [session-id] [annotation-id]
moon run cmd/main --target native -- episode [robobook-root] [session-id]
moon run cmd/main --target native -- episode-quality [robobook-root] [session-id]
moon run cmd/main --target native -- policy-evaluate [robobook-root] [episode-id]
moon run cmd/main --target native -- policy-evals [robobook-root]
moon run cmd/main --target native -- policy-eval [robobook-root] [evaluation-id]
moon run cmd/main --target native -- message-task [robobook-root] [message]
moon run cmd/main --target native -- ingest-sdk-frame [robobook-root] [session-id] [frame-id]
moon run cmd/main --target native -- api-snapshot [robobook-root]
moon run cmd/main --target native -- api-health [robobook-root]
moon run cmd/main --target native -- api-route [robobook-root] [method] [path] [body-json]
moon run cmd/main --target native -- serve [robobook-root] [ui-root] [host] [port] [bridge-host] [bridge-port]
moon run cmd/main --target native -- host-manifest [robobook-root] [ui-root] [host] [port] [bridge-host] [bridge-port]
moon run cmd/main --target native -- desktop-project [robobook-root] [ui-root] [host] [port] [sidecar-path] [bridge-host] [bridge-port]
moon run cmd/main --target native -- desktop-bundle [robobook-root] [ui-root] [host] [port] [sidecar-path] [bundle-root] [bridge-host] [bridge-port]
moon run cmd/main --target native -- plan-walk [robobook-root]
moon run cmd/main --target native -- bridge-health [robobook-root]
moon run cmd/main --target native -- bridge-telemetry [robobook-root]
moon run cmd/main --target native -- sdk-health [robobook-root]
moon run cmd/main --target native -- sdk-telemetry [robobook-root]
moon run cmd/main --target native -- sdk-telemetry-file [robobook-root] [snapshot-json]
moon run cmd/main --target native -- receipts [robobook-root]
moon run cmd/main --target native -- receipt [robobook-root] [receipt-id]
moon run cmd/sdk_e1_bridge --target native -- route [robobook-root] [method] [path] [body-json] [snapshot-json] [read-only|control-gated] [command-json]
moon run cmd/sdk_e1_bridge --target native -- serve [robobook-root] [host] [port] [snapshot-json] [read-only|control-gated] [command-json]
```

Default root:

```text
examples/noetix-e1
```

Command meanings:

- `inspect`: load and validate the RoboBook, then summarize identity,
  readiness, joints, capabilities, missing files, and validation issues.
- `mock`: load the RoboBook and emit one deterministic telemetry summary from
  the mock bridge.
- `cockpit`: emit the first-screen cockpit projection using mock bridge data.
- `cockpit-sdk-file`: emit the same projection from SDK sidecar snapshot JSON.
- `resident`: emit the Moontown-facing resident robot agent projection.
- `runtime-supervisor`: emit the physical runtime supervisor plan derived from
  the SDK collector, high-control writer, and bridge sidecar manifest.
- `runtime-supervisor-script`: emit an executable shell runner for that
  supervisor plan.
- `runtime-validation`: persist and print the live SDK readiness report for the
  selected RoboBook, active supervisor, telemetry identity, and runtime log.
- `runtime-validation-session`: run repeated validation samples, persist every
  sample report, and write one aggregate readiness session under
  `runs/runtime-validation/sessions/`. Blocked sessions also write a
  calibration plan under `runs/runtime-calibration/`.
- `memory`: emit the current MoonBook memory pack without persisting it.
- `remember`: persist the current MoonBook memory pack under
  `moonbook/memory/`.
- `work-queue`: emit the prioritized robot-agent work queue derived from
  resident, task-message, review, replay, dataset, and policy ledgers.
- `next-action`: emit the next route/method/body contract for the top queued
  robot-agent work item without executing it.
- `task-status`: emit the MoonBook task-message execution status for one
  `task_id`, including evidence gates, runtime requirement, receipt status, and
  bridge dispatch status.
- `observe-task`: submit a Moontown-style standing-goal observation task.
- `observe-run`: execute the bounded observation pipeline: start session,
  ingest deterministic SDK-shaped frames, stop session, and return replay plus
  resident state.
- `observe-run-sidecar`: poll the local SDK bridge sidecar over HTTP for
  telemetry frames, feed those frames into the same bounded observation
  pipeline, stop the session, and return replay plus review evidence.
- `execute-message-sidecar`: load a reviewed MoonBook task message, revalidate
  its dry-run and approval evidence, post the matching `ExecuteIntent` to the
  local bridge sidecar, and persist the sidecar response as a receipt plus
  bridge dispatch evidence. It also persists a fresh MoonBook memory pack and
  returns the memory path with the execution response. On the desktop host the
  same response includes the post-dispatch runtime health evidence path. It
  refuses to dispatch unless the runtime supervisor is actively running, points
  at the same bridge endpoint, and the persisted runtime validation report is
  `ready`.
- `bridge-execute`: send a typed `ExecuteIntent` envelope to the local bridge
  sidecar over HTTP and print the typed bridge response. It uses the same active
  runtime plus runtime-validation preflight. The SDK sidecar remains read-only
  by default, and the
  supervised runtime launches it in `control-gated` mode with a command outbox,
  so only allowlisted high-control walk/run envelopes can be accepted after
  Moonrobo safety gates and handed to the SDK writer.
- `replay`: emit the replay timeline for one observation session.
- `annotate-replay`: mark one replay session or frame as curated evidence.
- `replay-annotations`: list replay annotations for one session.
- `replay-annotation`: print one replay annotation.
- `episode`: emit a dataset episode export for one observation session.
- `episode-quality`: emit quality blockers and warnings for one dataset episode.
- `policy-evaluate`: submit a learned-policy proposal through the receipt-only
  policy gate.
- `policy-evals`: list persisted policy evaluation receipts.
- `policy-eval`: print one policy evaluation receipt.
- `message-task`: submit an operator task message, start observation when it
  classifies as read-only observation, or persist command/maintenance review
  work under `moonbook/task-messages/`.
- `message-sidecar`: submit an operator command message, run the MoonBook
  evaluation, dry-run, and approval gates, call the local bridge sidecar, and
  persist the actual sidecar response into the receipt and dispatch ledgers. It
  requires the desktop-owned runtime supervisor to be active first.
- command-message execution: after evaluation, dry-run, and approval evidence,
  local host execution writes the deterministic final receipt and dispatch
  evidence; native sidecar execution writes the actual bridge response. Rejected
  or error responses become failed receipts with `bridge_error` populated.
- `ingest-sdk-frame`: convert a deterministic SDK-shaped snapshot into a
  `TelemetryFrame` and append it to an active observation session.
- `api-snapshot`: emit the local host API body for `/api/cockpit/snapshot`.
- `api-health`: emit the local host API body for `/api/health`.
- `api-route`: probe the local host API router contract without starting a
  server, including POST body JSON for command-intent evaluation.
- `serve`: start the native localhost desktop host that serves the Rabbita UI,
  readiness JSON, and robot API routes together.
- `host-manifest`: emit the desktop host service manifest and route catalog.
- `desktop-project`: emit the Lepus project JSON that points a native window at
  the localhost host command, including the bridge sidecar host and port used
  by reviewed task-message execution.
- `plan-walk`: create a high-level walk intent, evaluate it through the safety
  pipeline, and write the resulting receipt JSON under `runs/receipts/`. It
  should currently stop at dry-run collection.
- `bridge-health`: emit a typed bridge health response as JSON.
- `bridge-telemetry`: emit a typed latest-telemetry response as JSON.
- `sdk-health`: emit a bridge health response from an SDK-shaped snapshot.
- `sdk-telemetry`: emit a latest-telemetry response from an SDK-shaped snapshot.
- `sdk-telemetry-file`: convert sidecar snapshot JSON into a bridge telemetry
  response.
- `receipts`: list decoded RoboBook run receipts.
- `receipt`: print one decoded RoboBook run receipt as JSON.
- `cmd/sdk_e1_bridge route`: probe the SDK E1 bridge sidecar protocol routes
  without starting a server. The optional `snapshot-json` argument points the
  bridge at one `SdkE1Snapshot` file produced by an SDK collector. In
  `control-gated` mode, `command-json` must point at the high-control command
  outbox.
- `cmd/sdk_e1_bridge serve`: start the local SDK E1 bridge scaffold on
  `127.0.0.1:5391` by default. The optional `snapshot-json` argument uses the
  same file-backed telemetry source. In `control-gated` mode, the final
  `command-json` argument is the file consumed by the SDK high-control writer.

## Rabbita/Lepus Path

The Rabbita cockpit should call into the same runtime contracts instead of
recreating robot parsing or safety checks in UI code.

Near-term screens should map directly to the CLI path:

- RoboBook picker and readiness summary from `inspect`
- mock bridge health and telemetry from `mock`
- proposed-command review from `plan-walk`
- first-screen cockpit projection from `cockpit` or `cockpit-sdk-file`

The Lepus desktop shell should package the native runtime and supervise later
sidecars. Scoped filesystem access belongs in Lepus; robot contract logic stays
in MoonBit packages.

The first Rabbita shell is in `ui/rabbita-cockpit`. It imports the
`src/cockpit` projection structs, renders a sample immediately, then loads the
same first-screen state from `/api/cockpit/snapshot` through Rabbita's HTTP
command path. The route contract lives in `src/host_api`; `src/desktop_host`
serves that route beside static Rabbita assets and emits the Lepus project JSON.
The shell also loads `/api/runtime/supervisor` so the operator can see physical
runtime readiness and bridge base URL before dispatching reviewed task-message
execution.
`POST /api/intents/evaluate` submits a command intent through the safety
pipeline and persists a RoboBook receipt, but it does not call hardware
execution. `POST /api/intents/dry-run` records dry-run evidence for a command
that needs simulation. `POST /api/intents/approve` records operator approval
against that dry-run evidence. `POST /api/intents/execute` consumes the same
evidence, re-runs the safety gate, dispatches the bridge execution boundary, and
persists an `executed` receipt.
The Rabbita cockpit also submits bounded Moontown observation runs to
`POST /api/moontown/tasks/observe-run` and renders the returned replay summary
and resident availability.
`POST /api/sessions/observe` starts a read-only observation session through the
same safety gate and bridge protocol. `POST /api/sessions/{id}/frames` accepts
one typed `TelemetryFrame`, writes it under
`runs/telemetry/{session_id}/{frame_id}.json`, and updates the active session's
frame count, latest frame, and artifact list. `POST /api/sessions/{id}/stop`
marks that session stopped with a final telemetry frame count. Start and stop
routes write a run receipt and a `runs/observations/{session_id}.json` record.
`GET /api/moontown/resident` returns the same robot as a town resident agent:
identity, role, availability, bridge state, active observation, latest receipt,
capability count, and review count.
`POST /api/moontown/tasks/observe` accepts a standing-goal observation task,
plans it into a read-only observation session, persists the same RoboBook
evidence, and returns the updated resident projection.
`POST /api/moontown/tasks/message` accepts an operator or town message, maps
observation language such as "inspect", "check", "status", or "telemetry" into
the same read-only observation task contract, and maps command or maintenance
language into review-classified task plans. Observation messages start a
session; review messages persist under `moonbook/task-messages/` with
`physical_execution_allowed: false`, return the resident projection, and
persist the resulting MoonBook memory pack.
`POST /api/moontown/tasks/observe-run` is the first bounded process pipeline:
it accepts a task plus a frame count, calls the reusable `src/pipeline`
observation process engine, starts the observation session, ingests telemetry
frames from the selected source, stops the session, writes a deterministic
process review, returns the replay timeline, and returns the updated resident
projection. The pipeline also exposes a source-injection entrypoint so native
surfaces can poll a bridge sidecar and feed live `TelemetryFrame` values into
the same evidence path instead of using generated SDK-shaped frames.
Observation starts also write the first telemetry frame under
`runs/telemetry/{session_id}/{frame_id}.json`; receipts and resident
observation summaries link to that artifact for replay and review.
`GET /api/replays/{session_id}` returns a compact replay timeline over the
persisted session and sorted telemetry frame artifacts. The timeline includes
session lifecycle fields and per-frame artifact paths, timestamps, mode, joint
count, and error count, giving Rabbita and Moontown a stable read-only surface
without requiring them to parse RoboBook files directly.
`POST /api/replays/{session_id}/annotations` records an operator or agent label
for a replay session or frame under
`runs/annotations/{session_id}/{annotation_id}.json`. `GET` on the same route
lists annotations for the session, and
`GET /api/replays/{session_id}/annotations/{annotation_id}` returns one
annotation. This is the first curation surface for dataset and policy workflows.
Dataset episodes include replay annotation ids and counts; quality reports warn
when an episode has no curation annotations.
`GET /api/reviews` returns the persisted process review queue from
`runs/reviews/`, including total review count, human-review count, findings, and
linked artifact paths.
`GET /api/moonclaw/context` returns the agent-facing context pack and bounded
next process plan derived from resident state, receipts, observations, and
reviews. The CLI mirror is:

```bash
moon run cmd/main --target native -- moonclaw-context [robobook-root]
```

Allowed evaluation receipts use `ready-for-execution`, not `executed`. The
`executed` status is reserved for the bridge execution route after the bridge
boundary has accepted and completed a command. This keeps cockpit
review, dry-run evidence, approval evidence, and live actuation auditable as
separate steps.

Example body:

```json
{
  "intent_id": "intent-cockpit-walk",
  "robot_id": "",
  "capability": "control.high.walk",
  "parameters": {
    "x": "0.10",
    "yaw": "0.00",
    "duration_ms": "1000"
  },
  "requester": {
    "kind": "operator",
    "id": "cockpit"
  },
  "receipt_id": "receipt-cockpit-walk",
  "now_ms": "1000",
  "approval_id": "",
  "dry_run_receipt_id": "",
  "developer_gate": false,
  "telemetry_age_ms": 10
}
```

An empty `robot_id` means “use the selected RoboBook profile”. Empty approval
and dry-run receipt IDs are treated as missing evidence, so high-control intents
first return `CollectDryRun` and persist a `WaitingForDryRun` receipt. After a
dry-run and approval are recorded, resubmitting the same intent with both IDs
returns `Execute` with a `ready-for-execution` receipt. Submitting that same
payload to `/api/intents/execute` records the bridge completion receipt as
`executed`.

`POST /api/policies/evaluate` is the offline policy gate. It persists a normal
run receipt plus `runs/policy-evals/{evaluation_id}.json`; the corresponding
read routes are `GET /api/policies/evaluations` and
`GET /api/policies/evaluations/{evaluation_id}`. `GET /api/moonstat/status`
includes the policy evaluation count, latest policy evaluation id, gate status,
and ledger path so Rabbita, Moontown, and Moonstat can see policy pressure
without gaining execution authority.
`GET /api/moonbook/memory` projects a compact memory pack from current resident
state, latest observation/review evidence, and next queued work. `POST
/api/moonbook/remember` persists the same pack under
`moonbook/memory/{pack_id}.json`, giving MoonBook durable recall of what the
robot observed and what it should do next.

This is the required memory path for robot agents. Observations that matter
should be written as RoboBook evidence and then distilled into MoonBook memory;
otherwise MoonClaw, Moontown, or a tool agent can plan correctly once and then
forget the robot context on the next run.

```bash
moon run cmd/main --target native -- memory [robobook-root]
moon run cmd/main --target native -- remember [robobook-root]
```

`GET /api/agent/work-queue` returns the highest-level robot-agent queue. It
does not persist new state; it orders existing evidence into actionable work:
connect bridge, review evidence, annotate replay, repair dataset quality,
dry-run or approve policy proposals, and evaluate curated episodes. The CLI
mirror is:

```bash
moon run cmd/main --target native -- work-queue [robobook-root]
```

`GET /api/agent/next-action` wraps the same queue with a typed next-action
contract: method, route, body schema, optional safe request body template,
execution mode, and an explicit `physical_execution_allowed: false`. Mutating
evidence routes carry the draft body; read-only actions omit it. It is the
action-plan seam for Rabbita and Moontown agents; it does not auto-run the
route.
Task-message review starts as operator evidence inspection. Command-message
plans then advance through evaluate, dry-run, approval, and execute queue items
as the persisted MoonBook evidence appears. These items expose the matching
task-message safety route as the next action, but generic agent dispatch still
refuses command-message gates.

```bash
moon run cmd/main --target native -- next-action [robobook-root]
```

`POST /api/agent/dispatch-next` is the safe evidence dispatcher for that plan.
With no body, it attempts the top queued action. With a `{ "work_id": "..." }`
request, it can dispatch a selected queued work item. The route refuses
read-only actions, physical execution, and non-allowlisted routes; successful
responses include the action, request body, downstream status, and downstream
JSON.

```bash
moon run cmd/main --target native -- dispatch-next [robobook-root] [work-id]
```

The user-message path reuses these contracts instead of creating a separate
durable chat platform. A chat or command box in Rabbita/Moontown submits to
`POST /api/moontown/tasks/message`; the route creates a task intent, writes
RoboBook evidence, persists MoonBook memory, and still blocks physical action
wording. Command-review plans include an intent draft with capability,
parameters, and receipt id; Rabbita activates that draft through the
MoonBook task-message safety routes:
`POST /api/moonbook/task-messages/{task_id}/evaluate`, `/dry-run`, `/approve`,
and `/execute-sidecar`. Each route reads the persisted task-message record and
submits the same message-derived intent to the safety pipeline. Physical
execution still requires explicit command-intent review, dry-run evidence,
operator approval, the safety gate, an active runtime supervisor, a ready
runtime validation report, and the native bridge sidecar route. The sidecar execution path writes
`runs/task-executions/{snapshot_id}.json` after dispatch, so a user-visible task
has one durable handle for the message plan, receipt, bridge dispatch, MoonBook
memory, and latest runtime-health evidence.

MoonClaw and Moonrobo suite tools enter through the same boundary. A tool can
read memory, inspect status, propose a plan, update permitted artifacts, and
report evidence, but it is registered as a bounded capability provider rather
than given implicit authority. `GET /api/tools/registry` persists and returns
the default provider registry at `agents/tool-registry.json`, while
`POST /api/tools/register` replaces or appends one provider entry. Registry
validation refuses any capability that grants physical execution authority. Any
observation that changes the robot agenda should still be persisted with
`POST /api/moonbook/remember`.

## Reference Direction

The sibling robot-canvas work and local SDK remain references for model loading,
file access, hardware configuration, and bridge behavior. Moonrobo should reuse
that learning while keeping its own product boundary: physical-world agent
operation with RoboBooks, safety gates, receipts, and Moontown-visible robot
residents.

The SDK E1 reference exposes the live telemetry fields through
`HighController::get_joint_state()`, `HighController::get_imu_data()`,
`HighController::from_dds_get_joydata()`, and `HighController::get_mode()`.
Moonrobo keeps those fields normalized as `SdkE1Snapshot`. The SDK bridge can
read that snapshot contract from a JSON file, so a native SDK collector can poll
DDS and write the latest snapshot without changing the host API, pipeline, or
RoboBook evidence model.
Allowlisted high-control execution uses the same file boundary in the other
direction: the MoonBit bridge writes one SDK-shaped command envelope to
`/tmp/moonrobo-sdk-e1-command.json`, and the SDK writer watches that file.

The first collector is `bridges/sdk_e1/sdk_e1_readonly_bridge.py`. It imports
the SDK Python binding in live mode, calls only read APIs, and atomically writes
the latest `SdkE1Snapshot` with `--output`:

```text
python3 bridges/sdk_e1/sdk_e1_readonly_bridge.py --live --sdk-root ../sdk --output /tmp/moonrobo-sdk-e1.json
python3 bridges/sdk_e1/sdk_e1_high_control_writer.py --watch --input /tmp/moonrobo-sdk-e1-command.json --sdk-root ../sdk
moon run cmd/sdk_e1_bridge --target native -- serve examples/noetix-e1 127.0.0.1 5391 /tmp/moonrobo-sdk-e1.json control-gated /tmp/moonrobo-sdk-e1-command.json
```

`/api/bridge/sidecar` and the desktop bundle manifest include the matching
physical runtime process graph. `/api/runtime/supervisor` turns that graph into
the launch lifecycle: validate manifest, start collector, wait for the snapshot
file, start high-control writer, start bridge, probe health, stop bridge, stop
writer, then stop collector.
`/api/runtime/supervisor/script` emits the current POSIX runner for that plan;
the desktop host binds all three routes to its configured bridge host and port,
so the Rabbita runtime panel, supervisor route, generated script, and
`/execute-sidecar` action use the same bridge endpoint.
`POST /api/runtime/supervisor/launch` persists that runner and a launch receipt
under `runs/runtime-supervisor/`, returning the exact `sh` command for Lepus or
another outer supervisor to run. The generated runner appends stdout and stderr
to `runs/runtime-supervisor/{launch_id}.log`, and both the launch receipt and
active run receipt expose that `log_path`.
The desktop host also exposes `GET /api/runtime/supervisor/run`,
`GET /api/runtime/health`, `GET /api/runtime/validation`,
`POST /api/runtime/supervisor/start`, and
`POST /api/runtime/supervisor/stop`. These routes use the native process
backend to start the prepared supervisor shell, persist its PID in
`runs/runtime-supervisor/active.json`, refresh status with a PID liveness check,
probe bridge telemetry when the process is running, write
`runs/runtime-health/{health_id}.json`, update
`runs/runtime-health/latest.json`, and stop the supervisor so its cleanup trap
can terminate the collector, high-control writer, and bridge sidecar. The health
snapshot is the operator and agent answer for whether the digital RoboBook
resident currently maps to a reachable physical runtime: `healthy` means the
active supervisor and
telemetry bridge agree on reachability, robot identity, and bridge identity;
`bridge-unhealthy` means the process is active but the robot-facing endpoint is
not reachable. Task-message sidecar execution refuses dispatch unless that
health snapshot is `healthy` and its telemetry `robot_id` and `bridge_id` match
the selected RoboBook profile. The validation route adds a stricter readiness
report that is `ready` only when the supervisor plan, collector snapshot, active
process, healthy telemetry, identity match, and runtime log are all present; it
persists both timestamped and latest JSON under `runs/runtime-validation/`.
Emergency stop remains available through the
active matching supervisor route so safety control is not blocked merely because
telemetry is degraded. Bridge dispatch evidence and task execution snapshots
carry the active runtime `log_path`, so a completed task links operator
approval, bridge request, bridge response, memory pack, runtime health, and
supervisor logs in one evidence trail.
The desktop bundle writes the same runner as
`moonrobo.runtime-supervisor.sh` and writes `moonrobo.desktop-launch.sh` as the
Lepus-facing entrypoint that starts both the supervisor and desktop host. The
bundle also writes `moonrobo.release-build.sh`, which builds and installs the
native desktop host and SDK bridge into bundle-local `bin/` paths and copies
the Rabbita cockpit build into bundle-local `ui/`. This is the first executable
backend while native process FFI stays isolated behind `src/supervisor`.

## Next Runtime Steps

1. Run the persisted runtime validation report repeatedly against live SDK
   hardware through `runtime-validation-session`, inspect the generated
   `runs/runtime-calibration/latest.json`, then use failures to drive
   calibration and bridge hardening.
2. Wrap the generated desktop bundle in a Lepus desktop prototype.
3. Add live-hardware calibration and vendor-specific emergency-stop evidence.
4. Promote runtime log tail evidence into MoonBook memory when startup or
   execution fails.
