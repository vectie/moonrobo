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
`GET /api/moonbook/task-messages` and projected into `GET /api/agent/work-queue`
as operator-review work.
Rabbita opens that queued operator-review work through
`GET /api/moonbook/task-messages/{task_id}` and displays the classification,
next route, suggested capability, review flag, and no-physical-execution flag
before any later gated route can be used. Command-review plans also carry a
bounded intent draft; when the operator evaluates it, Rabbita calls
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
MoonBook memory, and runtime health. The parallel immediate-safety path is
`POST /api/runtime/emergency-stop`: Rabbita can call it against the active
runtime bridge, and Moonrobo still writes receipt plus bridge-dispatch evidence
for the event.

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

## Memory Rule

Useful observations must be remembered in MoonBook. Otherwise agents can plan
correctly once and then forget the state on the next run.

The intended loop is:

```text
observe or review
  -> write RoboBook evidence
  -> project MoonBook memory
  -> persist with /api/moonbook/remember
  -> expose memory to MoonClaw and Moontown
  -> plan next safe work item
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
high-control command writer, and a dedicated emergency stop route exposed in
Rabbita.

The remaining gap to the first goal is live hardware hardening:

- validating the collector, high-control writer, and bridge sidecar together
  against live SDK hardware
- stronger live IDs, timestamps, calibration evidence, and vendor-specific
  emergency semantics
