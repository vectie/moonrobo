# Moonrobo Rabbita Cockpit

This is the first MoonBit/Rabbita operator surface for Moonrobo. It renders the
`vectie/moonrobo/src/cockpit` projection contract directly, so robot parsing,
safety decisions, and bridge semantics stay in the MoonBit runtime packages.

## Run

```bash
moon build --target js --debug
node prepare-rabbita-build.mjs debug
npm run dev
```

## Build

```bash
moon build --target js --release
node prepare-rabbita-build.mjs release
npm run build
```

The current slice renders a sample immediately, loads `/api/cockpit/snapshot`,
and lets the operator edit a high-level walk proposal. The cockpit can evaluate
the proposal, collect dry-run evidence through `/api/intents/dry-run`, record
approval through `/api/intents/approve`, then re-evaluate the same intent as
`ready-for-execution`. The Execute action submits the same evidence to
`/api/intents/execute` for direct walk proposals. Reviewed task-message commands
use `/api/moonbook/task-messages/{task_id}/execute-sidecar`, which persists the
actual native sidecar response into the receipt and bridge dispatch ledgers.

The cockpit also exposes the first Moontown-facing process control:
`/api/moontown/tasks/observe-run`. The operator can submit a bounded observation
task with a frame count, then see the stopped replay session, latest frame, and
resident robot availability returned by the MoonBit host API.

The Bridge panel exposes the physical runtime controls. It can prepare the
supervisor launch receipt, start the native supervisor process through the
desktop host, and stop the recorded PID while keeping the script and active-run
receipts under RoboBook evidence. It also exposes
`POST /api/runtime/emergency-stop` for the dedicated bridge emergency path,
which returns timestamped request, receipt, and dispatch evidence without going
through the normal task-message approval chain. On startup it also polls
`/api/runtime/health`, `/api/runtime/log`, and `/api/runtime/validation`,
rendering the latest persisted runtime-health path, telemetry status, active
supervisor log path, bounded log tail, validation report path, and live-SDK
readiness so operators can tell whether the selected RoboBook resident is
currently mapped to a reachable physical bridge. `Validate Session` posts to
`/api/runtime/validation/session`, persists repeated readiness samples, and
shows the latest aggregate session plus session-derived calibration plan. If a
reviewed task message is waiting on runtime startup, each healthy or unhealthy
health poll refreshes that task status; when the backend reports
`ready-to-dispatch`, the cockpit posts the already-approved task through
`/execute-sidecar` and reports the returned MoonBook memory path, desktop
runtime-health evidence path, and task execution snapshot path in the execution
status.

The Platform Readiness panel polls `/api/moonrobo/readiness`, the first
milestone report for the selected RoboBook root. It shows whether the
MoonBook/RoboBook mapping is ready, how many checks pass or fail, how many
conversation turns and memory cards exist, whether tools are registered, the
latest runtime health state, and which evidence checks still block the
user-message-to-physical-task loop.
The same panel also renders `/api/moonrobo/loop-proof`, which answers the
product question directly: how many of the closed-loop proof checks are already
true for this RoboBook root. It shows digital/physical mapping, Robobook-backed
MoonBook memory, task-message ledger, MoonClaw routine evidence, Moonrobo
live-proof evidence, verified physical feedback, latest artifact paths, and the
next route to continue.

The Task Message panel is the one-to-one Robo conversation surface. It submits
operator requests to `/api/moontown/tasks/message`, then reads
`/api/moonbook/conversation` as the durable user/Robo transcript instead of
adding a separate chat store. The route normalizes the request into a safe
observation task, records RoboBook evidence, persists MoonBook memory, and
returns the accepted task, session, card count, resident availability, and
memory path for the cockpit.
`Ask Robo` sends the same text to `/api/moonclaw/robot-routine`, which reads
MoonClaw context, runs Moonrobo live proof, refreshes context after evidence and
MoonBook memory update, and persists one closed routine artifact under
`runs/moonclaw-robot-routines/`. `Ask & Dispatch` uses the same routine route
with explicit dispatch enabled; when the desktop host reaches sidecar execution,
the cockpit renders the routine status/path, memory-update flag, nested proof
status/path, execution-proof count, latest snapshot id/path, verification
status, and command outcome directly in the task result. The same result shows
the task-loop session projection: Robo session id, MoonBook thread,
resident/mapping identity, latest user/Robo text, continuation route, dispatch
readiness, execution verification, and any recovery pointer. If live dispatch
is blocked, the task result also shows the recovery kind, path, step, and
summary returned by the first-loop sidecar step.
`Continue Session` and `Retry Dispatch` call
`/api/moonrobo/task-loop/continue` with the current task id, so recovery retries
advance the same Robo session instead of submitting a duplicate message.
The same panel also loads `/api/moonbook/task-messages` and
`/api/moonbook/conversation` on startup and after submissions, showing the
persisted task-message ledger as compact work history with lifecycle stage,
current route, next route, gate flags, review, physical-execution, and RoboBook
path metadata while the conversation projection shows the user text and Robo
reply. The submitted task is focused in the ledger; when it needs review,
Rabbita opens its
`/api/moonbook/task-messages/{task_id}` review automatically. Each actionable
ledger row can continue its verified next gate directly: evaluate, dry-run,
approval, runtime start/health check, or sidecar execution.

The Agent Queue rail loads `/api/agent/next-action`, renders the next safe body
template when one exists, and can submit `/api/agent/dispatch-next` for
allowlisted evidence actions. Dispatch remains non-physical: it writes curation,
observation, or policy-evaluation evidence and returns the downstream response
for audit. Runtime calibration blockers appear as read-only
`calibrate-runtime` work that opens `/api/agent/runtime-calibration/latest`
before the rail advances to observation or command-message work. When that work
is selected, Rabbita loads the calibration plan and renders the plan id, status,
blocking/action counts, runtime/robot/bridge ids, and each blocker action with
its evidence path and next operator step.

For task-message review work, the rail opens
`/api/moonbook/task-messages/{task_id}`, then reads
`/api/moonbook/task-messages/{task_id}/status` so the cockpit can show the
current stage, next route, runtime state, receipt state, bridge state, and
gated evidence flags from the same MoonBook/RoboBook ledgers used by execution.

The native `src/host_api` package owns those route contracts, and
`src/desktop_host` serves them beside the built Rabbita assets for the Lepus
desktop shell.
