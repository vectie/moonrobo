# MoonRobo Rabbita Cockpit

## Local results and read-only smoke

`results.html` is the presentation view: overview, full-motion failures,
experiment library, and provenance. It links back to a selected cockpit
experiment through `/?experiment=ID`. The reference tab embeds the original
SuperMimic site with explicit authorship; its scientific claims are separate
from local smoke evidence. No training or physical execution is launched.

The 2026-10-28 local session serves `target/ui-smoke-20261028/book` on port 5290
and the built UI on port 4190. That isolated RoboBook is copied from the E1
example, with `moondata` linked to the existing
`target/learning/experiment-book/moondata` store. The robot example's mock
telemetry is not displayed as live telemetry. The experimental records are
the actual sealed local artifacts.

Recreate the result export from a running host, from the repository root:

```sh
mkdir -p ui/rabbita-cockpit/public/results
moon run scripts/smoke_results_site.mbtx -- "$PWD" http://127.0.0.1:5290 \
  "$PWD/target/ui-smoke-20261028/book" "$PWD/ui/rabbita-cockpit/public/results"
npm --prefix ui/rabbita-cockpit run build
MOONROBO_REFERENCE_HOST=http://127.0.0.1:5290 node --test \
  ui/rabbita-cockpit/reference-registry.integration.test.mjs
```

The export checks the service, read-only snapshot, experiment registry, sealed
evaluation SHA-256 values, and both replay routes. It includes all 48 registered
experiment summaries, both 40-motion evaluation reports, and their provenance.
The browser verifies complete pose contracts and content-addressed mesh bytes.
The hero poster is a screenshot of the registered feedforward replay at its
initial frame, with the reference overlay hidden, not generated imagery.

Verified workflows: task intake and refresh, experiment selection and trial
inspection, replay selection/play/pause/seeking, motion filtering/details,
source tabs, and desktop/mobile layout. Native replay roots may omit
`parent_id`; the frontend accepts this equivalent of `null`. Submission errors
remain visible outside collapsed technical details. The result page shows
missing prediction/hardware/scale studies as not run or not registered.

The `Data` workspace now opens an inline `Experiments → Results → 3D replay`
flow. A single experiment selection is shared by all three tabs. Candidate
inspection, motion filters, expanded motion details, and the replay cursor are
retained when switching tabs or visiting another workspace. Playback pauses
when hidden. Full-motion details expand inline; experiments without pose
records show an empty state rather than another experiment's recording.
Deep links accept `/?experiment=ID&view=results` (or `view=replay`).

`learning-workspace.js` keeps the evidence and viewer controllers in a persistent
DOM island attached to the Rabbita navigation slot. `workbench.css` applies the
Results page's neutral typography, surfaces, cards, and controls to the cockpit.
The presentation page remains available from the header.

The replay uses a white stage and a single transport dock, following the
SuperMimic presentation's light navigation and media-first composition.
`replay-stage.css` keeps the workspace tabs sticky below the measured header.
The picture height reserves space for the complete dock and timeline, including
on a 375 × 667 viewport. A ResizeObserver recalculates it when the header,
selectors, or transport wrap. Reference comparison is opt-in; playback details
and source hashes are folded below the first screen. The language switch stays
in document flow so it cannot cover playback controls.

> **Integration migration — 2026-07-30:** The former
> `/v1/robot/routine/run` shortcut is retired. The cockpit submits reviewed work
> through MoonFlow to an installed MoonRobo adapter; MoonClaw remains the
> generic agent runtime.

This is the first MoonBit/Rabbita operator surface for MoonRobo. It renders the
`vectie/moonrobo/src/cockpit` projection contract directly, so robot parsing,
safety decisions, and bridge semantics stay in the MoonBit runtime packages.

The cockpit uses five workspaces: `Operate`, `Robot`, `Tasks`, `Data`, and
`System`. Each has focused section tabs and remembers its selected section while
switching workspaces. `Operate` opens the command flow beside the robot preview;
telemetry and activity have their own tabs. `Tasks` separates chat, review,
history, and observation. Model editing, design, and digital trials live under
`Robot`; experiments and replay live under `Data`.

Paths, internal identifiers, model geometry, and evidence are available through
collapsed details. Connection, refresh, and emergency stop remain in the header.
Design and trial dialogs also use section tabs and preserve their form drafts.
Tabs support arrow keys, Home, and End; closing a tool returns focus to its
launcher. Workspace labels support both English and Simplified Chinese.

See [Cockpit Audit And Upgrade Record](../../docs/COCKPIT_AUDIT.md) for the
measured baseline, the upgrade mapping, validation evidence, and remaining
priorities.

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
loads `/api/moondata/status` for bounded canonical inventory and validation
pressure, and lets the operator edit a high-level walk proposal. The cockpit
can evaluate the proposal, collect dry-run evidence through
`/api/intents/dry-run`, record
approval through `/api/intents/approve`, then re-evaluate the same intent as
`ready-for-execution`. The Execute action submits the same evidence to
`/api/intents/execute` for direct walk proposals. Reviewed task-message commands
use `/api/moonbook/task-messages/{task_id}/execute-sidecar`, which persists the
actual native sidecar response into the receipt and bridge dispatch ledgers.

The cockpit also exposes the first MoonTown-facing process control:
`/api/moontown/tasks/observe-run`. The operator can submit a bounded observation
task with a frame count, then see the stopped replay session, latest frame, and
resident robot availability returned by the MoonBit host API.

The MoonClaw panel reads MoonRobo-owned context from `/api/moonclaw/context`.
Accepted inspection tasks refresh local evidence without calling a separate
agent endpoint from the browser. Agent work belongs to the installed MoonRobo
adapter invoked through MoonDesk / MoonFlow; physical effects retain their
existing readiness and authority gates. Historical routine records remain
readable, but the retired routine action is no longer offered or automatically
invoked. Hosted API requests use the configured public base path on the current
origin, including in the browser test build.

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

The MoonData view is read-only. It reports initialization and readiness,
artifact-family counts, validation blockers and warnings, repair pressure, the
catalog path, and up to 40 canonical artifact summaries. Raw payloads and
manifests remain owned by MoonData packages; browser code does not scan or parse
the data root.

**MoonData → Learning experiments** opens the registered learning comparison.
It reads `/api/moondata/learning-experiments` and a selected candidate's
`/{experiment}/physics/{seed}` evidence. The table preserves failed candidates;
the inspector overlays recorded baseline/candidate root height and upright Z,
with per-observation contacts and a shared simulated-time cursor. Curves stop
at their own recorded endings; missing baseline timestamps are not interpolated.
Checkpoint and physics payload references remain inspectable. See the
[experiment registry guide](../../docs/LEARNING_EXPERIMENT_REGISTRY.md) for
registration commands and current limits. There is no learning launch, skill
activation or hardware execution in this viewer.

For candidates with registered follow-ups, **Recorded evaluation** switches
between original, repeat, fresh and extended reports. The view preserves the
original pass duration and displays longer-trial failures. Each selection uses
its own checksum-bound physics payload; it does not reinterpret a short pass
as long-term stability.

The Platform Readiness panel polls `/api/moonrobo/readiness`, the first
milestone report for the selected RoboBook root. It shows whether the
MoonBook/RoboBook mapping is ready, how many checks pass or fail, how many
conversation turns and memory cards exist, whether tools are registered, the
latest runtime health state, and which evidence checks still block the
user-message-to-physical-task loop.
It also renders `/api/moonrobo/live-readiness`, the immediate physical
preflight that joins repeated runtime validation, calibration, proof-session
history, and loop-proof status before the operator or MoonClaw requests another
proof-session attempt.
`Proof Session` posts to `/api/moonrobo/proof-session` with a bounded,
non-dispatching request, repeats the proof loop up to the configured limit, and
refreshes live-readiness, loop-proof, execution proof, MoonBook messages, and
MoonClaw work state after it stops. The same card reads
`/api/moonrobo/proof-sessions` so persisted proof-session history remains
visible after reload.
The same panel also renders `/api/moonrobo/loop-proof`, which answers the
product question directly: how many of the closed-loop proof checks are already
true for this RoboBook root. It shows digital/physical mapping, Robobook-backed
MoonBook memory, task-message ledger, MoonClaw routine evidence, MoonRobo
Robo loop evidence, verified physical feedback, latest artifact paths, and the
next route to continue.
`Prove Loop` posts to `/api/moonrobo/prove-loop`: the host bootstraps
non-physical substrate, attempts the MoonClaw gateway command through the same
runtime gates, and returns the refreshed proof without granting raw bridge
authority.

The Task Message panel is the one-to-one Robo conversation surface. It submits
operator requests to `/api/moontown/tasks/message`, then reads
`/api/moonbook/conversation` as the durable user/Robo transcript instead of
adding a separate chat store. The route normalizes the request into a safe
observation task, records RoboBook evidence, persists MoonBook memory, and
returns the accepted task, session, card count, resident availability, and
memory path for the cockpit.
`Ask Robo` sends the same text through `/api/moonrobo/gateway/command` when the
command has been selected by MoonClaw. MoonRobo records that command as gateway
task ingress, refreshes MoonBook-backed task evidence, and returns the current
decision route. The cockpit renders the resulting task status, gateway command
path, decision, execution-proof count,
latest snapshot id/path, verification
status, and command outcome directly in the task result. The same result shows
the Robo session projection: Robo session id, MoonBook thread, resident/mapping
identity, latest user/Robo text, continuation route, dispatch readiness, and
execution verification. If live dispatch is blocked, Rabbita keeps the operator
on the same task surface and points at the runtime, validation, or calibration
route surfaced by readiness and MoonClaw context.
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

The Platform Queue rail loads `/api/moonrobo/platform-queue`, renders the highest-priority
evidence item, and opens explicit MoonRobo product routes for operator-owned
steps. MoonClaw remains responsible for routine selection and tool invocation.
Runtime calibration blockers appear as read-only
`calibrate-runtime` work that opens `/api/moonclaw/runtime-calibration/latest`
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

## Local mission rehearsal (R578)

Open **Build a robot concept**, start or re-open an excavation-haul design,
then choose **Load current design into rehearsal**. The workbench copies the
current editable task loop and bounded speed range into a local, manual
operator tabletop exercise. Saving or building is not required.

Start practice and explicitly mark each simulated step completed. Operator hold
and injected hazards stop progression. A telemetry gap during a running step
marks that step unknown: restore the simulated link, choose whether practice
evidence says the step completed or never started, clear any hazard, and
explicitly resume. Completing a step during reconciliation advances exactly
once; it never automatically resumes or repeats that step.

Close or Escape holds a running rehearsal; reopen and explicitly resume. Editing
or replacing the design clears practice state. Reset restarts the tabletop
exercise with clear simulated conditions. A page reload clears all practice
state. Practice speed must remain inside the design's declared bounds and can
only change while not running. Steps are displayed as text, never markup.

This is a UI sequencing exercise, not a physics simulation, scenario validator,
real telemetry, hardware readiness check, authorization or retained proof. It
never calls a host, bridge, SDK, robot or provider. Existing build, saved-design,
MoonMoon export, physical safety policy and authority contracts are unchanged.

Focused checks: `node --test ui/rabbita-cockpit/*.test.mjs` from repository root.
These are deterministic function/controller tests with DOM doubles, not a browser
or hardware qualification run.
