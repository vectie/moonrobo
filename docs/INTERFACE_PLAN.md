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

- model viewport
- joint list
- sensor list
- capability list
- calibration and model warnings

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
- Moontown observation run control with bounded frame collection and replay
  summary
- telemetry and latest receipt along the bottom
- Moonstat suite status with evidence counts and latest policy evaluation gate
- agent work queue with next action and target route
- replay annotation and curation controls for dataset readiness

The local host route is now owned by `src/desktop_host`: it serves the Rabbita
assets, exposes `/api/cockpit/snapshot` plus the `/api/intents/*` evidence
routes, and emits the Lepus project metadata. The first command control edits a
high-level walk proposal, collects dry-run evidence, records approval, and
re-evaluates to `ready-for-execution`. The execution control now hits the bridge
execution boundary and records a completion receipt; the local host uses
deterministic completion until a supervised SDK sidecar owns physical transport.
The observation control calls `/api/moontown/tasks/observe-run` and renders the
stopped session, latest replay frame, and resident availability returned by the
MoonBit host API.
The cockpit also fetches `/api/moonstat/status` after the snapshot load and
renders suite-level receipt, observation, review, and policy-evaluation counts
plus the latest policy gate path.
The task rail fetches `/api/agent/next-action` and renders the highest-priority
item first. Queue items include kind, priority, target id, route, method, body
schema, optional safe request body template for mutating evidence routes,
execution mode, and safety note, so Rabbita can map them to compact operator
controls without duplicating pipeline logic.
The same rail can submit `POST /api/agent/dispatch-next` for selected safe
evidence work. The dispatcher refuses read-only actions, hardware execution, and
non-allowlisted routes, then returns the request body and downstream response as
auditable evidence.
The message box should not store a parallel chat memory. It should submit to
`POST /api/moontown/tasks/message`, show the accepted observation task and
memory path, and rely on MoonBook memory so MoonClaw and Moontown remember what
changed.
