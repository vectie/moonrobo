# Moonrobo Architecture

Moonrobo extends the Moon suite from desktop and document work into the
physical world. Its job is to make robots visible, controllable, reviewable,
and safe as agent participants without hiding hardware risk behind a generic
agent abstraction.

Moonrobo should be understood as the physical interface layer:

```text
RobotBook documents and ledgers
  -> Moonrobo robot profile, twin, safety gate, bridge protocol
  -> MoonClaw bounded planning / diagnosis / simulation workers
  -> Moontown schedules, resident robot agents, mayor supervision
  -> Robot bridge sidecar
  -> simulator or physical robot
  -> telemetry, receipt, replay, evidence back into RobotBook
```

## Stack

- **MoonBit**: core contracts, protocol DTOs, safety policy, CLI/service logic,
  bridge adapters, deterministic tests, and generated interfaces.
- **Rabbita**: browser-based robot cockpit for operators, town surfaces,
  telemetry, replay, digital twin, and review.
- **Lepus**: desktop shell for packaged local operation, supervised sidecars,
  scoped workspace access, and native app distribution.
- **MoonBook**: durable RobotBook workspaces.
- **MoonClaw**: bounded agent execution for planning, inspection, diagnosis,
  simulation review, and report generation.
- **Moontown**: scheduling, resident robot agents, standing goals, routing,
  escalation, and operator-visible civic/physical-world state.
- **Moonstat**: observability, suite status, local health, usage, and metrics.

## Boundary

Moonrobo must stay narrow enough to reason about. It owns robot-facing product
and protocol surfaces, not the entire robotics stack.

Moonrobo owns:

- robot profiles and capability schemas
- digital twin and telemetry projections
- command-intent and run-receipt contracts
- safety gate policy and approval flows
- bridge protocol for simulator, SDK, and ROS-style hardware sidecars
- teleoperation surfaces
- replay and evidence capture
- RobotBook scaffolding and validation

Moonrobo does not own:

- long-running town scheduling
- durable domain knowledge beyond RobotBook files
- generic agent runtime internals
- model proxying, provider routing, or accounting
- vendor SDK internals
- direct low-level control loops inside UI code

## Core Packages

The first MoonBit packages should be small and contract-first:

```text
core/
  robot_profile
  embodiment
  capability
  command_intent
  telemetry
  run_receipt
  safety_verdict
  bridge_protocol
  robotbook_contract

runtime/
  robotbook_loader
  safety_gate
  bridge_client
  replay_store

cmd/
  main
```

The root package can remain a facade. Implementation should move into named
packages once the docs are translated into code.

## Data Flow

The live execution path must be explicit:

```text
operator or Moontown request
  -> CommandIntent
  -> RobotProfile capability check
  -> SafetyGate
  -> dry-run / simulator receipt
  -> human or policy approval
  -> bridge execute
  -> TelemetryFrame stream
  -> RunReceipt
  -> RobotBook evidence
  -> Moontown status
```

No UI control should call a vendor SDK directly. No agent should send raw motor
commands to a robot. All physical execution goes through the same safety-gated
bridge protocol.

## First Hardware Reference

The local `../sdk` repository is the first concrete hardware reference. It
provides:

- Noetix E1 SDK
- CycloneDDS transport
- high-control and low-control APIs
- Python bindings through pybind
- C++ examples
- 24 motor states and commands
- IMU and joystick data
- high-level commands such as walk, run, switch, teach, and play-teach
- robot configuration and policy files

Moonrobo should wrap this as a sidecar bridge, not copy its logic into the
MoonBit core.

## Interface Reference

The sibling `../olu` work is a useful reference for robot canvas, model loading,
hardware configuration, file IO, and inspection workflows. Moonrobo should use
that learning without inheriting product ownership or naming. The Moonrobo UI
should be its own Rabbita application and should keep the product story centered
on physical-world agent operation.

## Resident Robot Agents

In Moontown, a robot should appear as a resident physical agent with:

- identity
- embodiment
- current mode
- location or workspace
- capability list
- safety status
- bridge health
- recent receipts
- maintenance state
- standing goals

The resident agent is not the robot body. It is the town-facing control and
memory identity for that body.

The first resident projection is implemented in `src/resident` and exposed at
`GET /api/moontown/resident`. It is intentionally read-only: it aggregates the
RobotBook profile, bridge sidecar status, active observation session, latest
receipt, capability count, and review count so Moontown can see the robot
without owning execution.

The first task ingress is implemented in `src/task` and exposed at
`POST /api/moontown/tasks/observe`. A town standing goal submits an observation
task; Moonrobo compiles it into the existing read-only observation session flow,
runs the safety gate, writes RobotBook evidence, and returns the updated
resident projection. Moontown owns scheduling, while Moonrobo owns robot
execution boundaries and receipts.
Observation evidence includes a persisted telemetry frame artifact, so town and
review surfaces can link to concrete replay data without reaching into bridge
internals.
The first replay projection is implemented in `src/replay` and exposed at
`GET /api/replays/{session_id}`. It summarizes RobotBook observation sessions
and telemetry artifacts into the shape Rabbita and Moontown need for timeline
inspection while leaving raw frame files in the RobotBook ledger.
Replay annotations are implemented in `src/annotation` and persisted by
`src/runtime` under `runs/annotations/{session_id}/`. Host routes under
`/api/replays/{session_id}/annotations` make curation explicit evidence that can
feed dataset quality and policy evaluation later.
The reusable process engine lives in `src/pipeline`: it starts task-backed
observations, ingests frames, stops sessions, builds replay timelines, and
returns typed process results without depending on HTTP. `src/review` produces
deterministic diagnosis records from replay and receipt state, and `src/moonclaw`
turns resident state plus review evidence into a bounded context pack and next
process plan. `src/runtime` persists reviews under `runs/reviews/`. `src/host_api`
is the thin route facade for these engines. The first process-level route is
`POST /api/moontown/tasks/observe-run`; it calls the pipeline engine and returns
resident state for Moontown. `GET /api/reviews` exposes the durable review
queue, and `GET /api/moonclaw/context` exposes the agent-facing context and
recommended next action. This is the initial agentic robot process pipeline
surface; the deterministic frame source is the replaceable part when the
supervised bridge polls live hardware.
`src/policy` converts learned-policy proposals into command intents and
receipt-only evaluations. `src/runtime` stores those evaluations as JSON under
`runs/policy-evals/`, while `src/host_api` exposes list and detail routes for
read-only audit. `src/moonstat` projects the same RobotBook, resident, review,
policy, and agent-process ledgers into a compact status document exposed at
`GET /api/moonstat/status`. That endpoint is intentionally read-only: it lets
Moonstat and other suite surfaces track readiness, bridge degradation, review
pressure, policy pressure, evidence counts, latest replay, and latest process
run without receiving any execution authority.
`src/work_queue` is the first Moontown-ready agent work queue. It is a pure
projection over resident state, process reviews, dataset quality reports, and
policy evaluation receipts. `GET /api/agent/work-queue` exposes prioritized
work items such as bridge connection, evidence review, replay annotation,
dataset repair, and offline policy evaluation. This keeps scheduling decisions
visible without giving the queue direct bridge or file-write authority.
`GET /api/agent/next-action` turns the top queue item into method, route, body
schema, execution mode, and safety note metadata. It is a planning contract, not
an execution shortcut, and always keeps physical execution disallowed.

## Failure Philosophy

Physical execution needs fail-fast behavior:

- missing robot profile blocks execution
- missing bridge blocks execution
- stale telemetry blocks execution
- unknown capability blocks execution
- unsafe verdict blocks execution
- low-control access requires explicit developer gate
- bridge errors are preserved in receipts
- silent fallback is not allowed on actuation paths

The system can degrade to read-only observation or simulation, but it must make
that state visible.
