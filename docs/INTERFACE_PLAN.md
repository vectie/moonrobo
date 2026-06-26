# Interface Plan

Moonrobo needs an operator surface before it needs autonomy. The first
interface should make robot state, safety state, and evidence obvious.

The interface is built with Rabbita for the web cockpit and Lepus for the
desktop shell.

## Product Shape

```text
Moonrobo Cockpit
  MoonBook/RoboBook explorer
  robot digital twin
  telemetry rail
  command-intent queue
  agent work queue
  safety verdict panel
  approval drawer
  replay timeline
  bridge health
  Moontown resident-agent status
```

## First Screen

The first screen should be the usable cockpit, not a landing page.

Required first-screen elements:

- selected robot identity
- bridge health
- current mode
- telemetry freshness
- digital twin viewport
- joint/sensor summary
- command queue
- prioritized agent work queue
- safety status
- latest receipt

## Main Views

### Robot

For inspecting embodiment:

- model viewport backed by the RoboBook `model.primary` artifact
- joint list
- sensor list
- capability list
- calibration and model warnings

The first model viewport should treat URDF as the canonical MVP format. It
should resolve the URDF path relative to the RoboBook root, show clear
diagnostics when the file or meshes are missing, and keep the joint tree
inspectable even when full mesh rendering is unavailable. Once telemetry or
replay frames are present, the viewport should bind frame joint positions to the
matching URDF joints and surface unmapped joints as calibration evidence.

### Telemetry

For live observation:

- latest frame timestamp
- stale/healthy state
- mode
- joint values
- IMU values
- operator input
- bridge errors

### Command

For proposed actions:

- command intent editor
- parameter controls
- dry-run button
- safety verdict
- approval state
- execute button only when allowed
- emergency stop or hold control

### Replay

For evidence review:

- receipt list
- timeline scrubber
- telemetry frame viewer
- command intent and verdict
- bridge result
- artifacts

### Town

For Moontown integration:

- resident robot card
- task message box that creates the same normalized task intent as scheduled
  work through `POST /api/moontown/tasks/message`
- standing goals
- scheduled tasks
- current assignment
- maintenance notices
- recent incidents
- MoonClaw context and next-plan view

## Desktop Shell

Lepus should package:

- Moonrobo MoonBit service
- Rabbita cockpit
- selected bridge sidecars
- scoped MoonBook workspace access with RoboBook decorator inspection
- local logs and receipts
- service lifecycle controls

The desktop shell should not become the scheduler or durable knowledge owner.
It hosts the operator cockpit and local sidecars.

## UI Rules

- Physical execution controls must be visibly safety-gated.
- The execute control is disabled unless the latest verdict allows execution.
- Stale telemetry must be a first-screen signal.
- Bridge errors must be visible and linked to receipts.
- Low-control features should not appear in normal mode.
- Replay and receipts should be one click away from every command.
- Simulation and read-only modes should be visually distinct from live control.

## Reference Reuse

The sibling `../olu` work is useful for robot canvas, model loading, file IO,
hardware panels, and inspection workflows. Moonrobo should borrow patterns and
possibly code when appropriate, but the product should stay focused on:

- physical-world agent operation
- safety-gated command intents
- RoboBook evidence
- Moontown resident robot agents
- Rabbita cockpit
- Lepus desktop shell

## Near-Term UI Milestone

Build a read-only cockpit:

1. load an example RoboBook
2. display robot identity and model metadata
3. show mock bridge health
4. stream fixture telemetry
5. render a receipt timeline
6. show safety status as read-only

Only after that should the UI add high-control command proposals.

The MoonBit cockpit projection is the first UI contract:

```text
moon run cmd/main --target native -- cockpit [robobook-root]
moon run cmd/main --target native -- cockpit-sdk-file [robobook-root] [snapshot-json]
```

It emits one JSON payload with robot identity, RoboBook readiness, bridge
health, telemetry summary, safety-gated command proposal, and receipt summary.
Rabbita should render this projection first before adding live controls.

## Rabbita Cockpit Slice

The first concrete shell lives in `ui/rabbita-cockpit`. It is a MoonBit/Rabbita
surface and is deliberately backed by the same MoonBit cockpit projection
contract. It does not own robot parsing, safety decisions, or SDK bridge
behavior.

This shell establishes the first-screen layout:

- RoboBook identity and readiness at the left edge
- bridge status and telemetry freshness at the top right
- digital twin and joint summary in the center
- safety-gated command review with dry-run, approval, and execution evidence
- task message entry that turns a user request into the same Moontown task,
  RoboBook evidence, and MoonBook memory path as scheduled work
- Moontown observation run control with bounded frame collection and replay
  summary
- telemetry and latest receipt along the bottom
- Moonrobo Loop product progress from the cockpit snapshot
- Moonstat suite status with evidence counts and latest policy evaluation gate
- agent work queue with next action and target route
- replay annotation and curation controls for dataset readiness

The local host route is now owned by `src/desktop_host`: it serves the Rabbita
assets, exposes `/api/cockpit/snapshot` plus the `/api/intents/*` evidence
routes, and emits the Lepus project metadata. The first command control edits a
high-level walk proposal, collects dry-run evidence, records approval, and
re-evaluates to `ready-for-execution`. The execution control now hits the bridge
execution boundary and records a completion receipt; the portable local host
uses deterministic completion, while native sidecar execution records the actual
SDK sidecar response into the receipt and dispatch ledgers. The latest receipt
and Moonrobo Loop product progress are both available from the cockpit snapshot,
so the first screen can answer operator control state and overall loop distance
from one payload.
panel surfaces the persisted bridge error when the physical sidecar rejects or
fails a command.
The observation control calls `/api/moontown/tasks/observe-run` and renders the
stopped session, latest replay frame, and resident availability returned by the
MoonBit host API.
The task message control is now the first Robo chat/control surface. Its
primary Ask Robo button submits to `POST /api/moonrobo/ask`, so one user message
produces a MoonBook task-message record and immediately returns the MoonBook
conversation thread, refreshed memory pack, loop proof, live readiness, and
current Robo decision. Save-only, Run Routine, and Run Loop remain secondary
diagnostic controls for the same route family. The panel renders the accepted
task, session, RoboBook memory path, MoonBook card count, loop proof, readiness,
and decision from the same ask response, so the persisted task-message plans
become the visible user/Robo transcript without a separate chat store. The
closed routine path remains explicit: it captures MoonClaw context before the
task, submits the message through the canonical Moonrobo loop, refreshes context
after loop evidence and MoonBook memory update, persists one
`runs/moonclaw-robot-routines/` artifact, and renders the routine status,
routine path, memory update flag, Robo loop status/path, task status,
conversation latest task, resident availability, runtime/bridge mapping, and
latest execution feedback in the same surface. It also renders the routine
`execution_proof` summary: proof count, latest snapshot id/path, verification
state, and command outcome. The returned `session` projection gives the UI the
single Robo conversation handle: session id, MoonBook thread id,
resident/mapping ids, latest user/Robo text, continuation route, dispatch
readiness, and execution verification. The proof panel also renders automatic
feedback-bind status after
`POST /api/moonrobo/prove-loop`, so operators can see whether latest runtime
telemetry closed the physical-feedback gate. Sustained proof sessions roll up
the same feedback-bind attempts and successes in the session card and history,
so the cockpit can show whether repeated proof collection actually closed the
physical-feedback gate. The Live Readiness panel mirrors that rollup as a
compact proof-feedback closure signal, and product status treats a successful
proof-session feedback rollup as final physical-feedback evidence. When
dispatch is blocked, Rabbita follows the readiness or MoonClaw context route for
runtime, validation, or calibration repair, then runs
the robot routine again with the current task intent.
`Run Routine` uses the MoonClaw robot-routine endpoint as an explicit secondary
agent lane, so the UI does not need a separate chat store or a parallel
physical-control path.
The cockpit also fetches `/api/moonstat/status` after the snapshot load and
renders suite-level receipt, observation, review, and policy-evaluation counts
plus the latest policy gate path.
It also fetches `/api/runtime/supervisor` and surfaces the physical runtime
state, bridge base URL, process count, and issue count in the Bridge panel. In
the desktop host, `/api/bridge/sidecar`, `/api/runtime/supervisor`, and
`/api/runtime/supervisor/script` are bound to the configured bridge host and
port so the panel, generated runner, and reviewed `/execute-sidecar` task route
all refer to the same bridge endpoint.
The Bridge panel can call `POST /api/runtime/supervisor/launch` to prepare the
configured launch script and receipt, then show the operator-visible script path
before an outer process manager starts the physical runtime. It can also call
`POST /api/runtime/supervisor/start` and `/stop`, which let the desktop host
start the prepared supervisor shell, persist the active PID receipt, and stop
the collector/bridge lifecycle through the supervisor cleanup trap. The same
panel can call `POST /api/runtime/validation/session` to collect repeated
runtime-readiness samples, display the latest validation session, and refresh
the calibration plan before retrying a blocked robot routine. The same
panel exposes `POST /api/runtime/emergency-stop` as the immediate bridge
emergency path and reports the returned receipt and dispatch evidence paths.
The task rail fetches `/api/agent/next-action` and renders the highest-priority
item first. Queue items include kind, priority, target id, route, method, body
schema, optional safe request body template for mutating evidence routes,
execution mode, and safety note, so Rabbita can map them to compact operator
controls without duplicating pipeline logic.
For `calibrate-runtime` items, the rail follows
`/api/agent/runtime-calibration/latest` and renders the calibration plan plus
blocker actions directly, including evidence paths and next operator steps. The
rail can then call `POST /api/agent/runtime-calibration/resolve` for the
selected action, show the persisted resolution receipt, and immediately rerun
the validation session before another robot-routine attempt. While the
latest resolution is still waiting on proof, `validate-runtime` becomes the top
queue item and points directly at the repeated validation route.
For `review-command-message` and `review-maintenance-message` items, the rail
opens the persisted MoonBook task-message plan and renders the classification,
gated route, suggested capability, review requirement, and physical execution
flag as read-only evidence.
When a command-review plan includes an intent draft, the rail can evaluate that
draft through `POST /api/moonbook/task-messages/{task_id}/evaluate`; the
dry-run, approval, and execute controls then call the matching `/dry-run`,
`/approve`, and `/execute-sidecar` task-message routes so they stay bound to the
reviewed message-derived intent and native sidecar response. The task-message
ledger mirrors those same controls at row level: newly submitted tasks are
focused, review-classified submissions open their review automatically, and row
continuation verifies the latest status before evaluate, dry-run, approval,
runtime start/health check, or sidecar execution. The agent work queue reflects
this same progression: it moves the command task from evaluate to dry-run to
approve to execute as persisted evidence appears, but these command-message
gates are not generic dispatch actions.
The same rail can submit `POST /api/agent/dispatch-next` for selected safe
evidence work. The dispatcher refuses read-only actions, hardware execution, and
non-allowlisted routes, then returns the request body and downstream response as
auditable evidence. For `bind-execution-feedback`, the rail can dispatch the
selected work without a JSON editor because the host builds the feedback request
from latest runtime-health telemetry; the desktop host refreshes that telemetry
from the active bridge immediately before dispatch.
The message box does not store a parallel chat memory. It submits through the
task route, renders the current user/Robo turn from the submitted task and
status evidence, shows the accepted observation task and memory path, and relies
on MoonBook memory so MoonClaw and Moontown remember what changed.
