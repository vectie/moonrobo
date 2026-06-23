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
currently mapped to a reachable physical bridge. If a reviewed task message is
waiting on runtime startup, each healthy or unhealthy health poll refreshes that
task status; when the backend reports `ready-to-dispatch`, the cockpit posts the
already-approved task through `/execute-sidecar` and reports the returned
MoonBook memory path, desktop runtime-health evidence path, and task execution
snapshot path in the execution status.

The Task Message panel submits operator requests to
`/api/moontown/tasks/message`. The route normalizes the request into a safe
observation task, records RoboBook evidence, persists MoonBook memory, and
returns the accepted task, session, card count, resident availability, and memory
path for the cockpit.
The same panel also loads `/api/moonbook/task-messages` on startup and after
submissions, showing the persisted task-message ledger as a compact conversation
and work history with route, review, physical-execution, and RoboBook path
metadata. Each ledger row can open its own `/api/moonbook/task-messages/{task_id}`
review, so operators can continue a previous task without waiting for it to be
the top agent-queue item.

The Agent Queue rail loads `/api/agent/next-action`, renders the next safe body
template when one exists, and can submit `/api/agent/dispatch-next` for
allowlisted evidence actions. Dispatch remains non-physical: it writes curation,
observation, or policy-evaluation evidence and returns the downstream response
for audit. Runtime calibration blockers appear as read-only
`calibrate-runtime` work that opens `/api/agent/runtime-calibration/latest`
before the rail advances to observation or command-message work.

For task-message review work, the rail opens
`/api/moonbook/task-messages/{task_id}`, then reads
`/api/moonbook/task-messages/{task_id}/status` so the cockpit can show the
current stage, next route, runtime state, receipt state, bridge state, and
gated evidence flags from the same MoonBook/RoboBook ledgers used by execution.

The native `src/host_api` package owns those route contracts, and
`src/desktop_host` serves them beside the built Rabbita assets for the Lepus
desktop shell.
