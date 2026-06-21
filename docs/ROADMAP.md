# Moonrobo Roadmap

Moonrobo starts as a documentation and contract project, then grows toward a
safe agentic robot process pipeline.

The guiding rule: build read-only visibility before actuation, simulation before
physical execution, and evidence before autonomy.

## Phase 0: Charter And Contracts

Goal: make the product boundary and safety model concrete.

Deliverables:

- architecture, safety, RobotBook, bridge, and interface docs
- MoonBit DTOs for robot profile, command intent, telemetry, safety verdict,
  and run receipt
- example RobotBook layout
- Noetix E1 profile draft from `../sdk/config`
- tests for stable serialization and validation rules

Non-goals:

- no live robot commands
- no low-control API exposure
- no hidden bridge side effects

Exit criteria:

- `moon info && moon fmt`
- `moon test`
- public interfaces reviewed through generated `.mbti` diffs
- example RobotBook validates locally

## Phase 1: Digital Twin MVP

Goal: make robots inspectable before they are controllable.

Deliverables:

- Rabbita robot cockpit shell
- model viewer for robot body and joints
- RobotBook loader
- joint and capability inspector
- simulated telemetry stream
- replay timeline for recorded frames
- Lepus desktop packaging sketch

The sibling robot-canvas work in `../olu` should be treated as a reference for
visual and file-handling patterns. Moonrobo should keep its own product surface:
operator cockpit, safety gate, resident robot state, and process evidence.

Exit criteria:

- a RobotBook can open in the cockpit
- a robot model and joint list are visible
- a simulated run produces a receipt
- no hardware SDK is required

## Phase 2: Read-Only Hardware Bridge

Goal: observe real robot state safely.

Deliverables:

- `sdk-e1-bridge` sidecar around `../sdk`
- bridge health endpoint
- read-only APIs for mode, joint state, IMU, joystick, and bridge metadata
- telemetry conversion into Moonrobo `TelemetryFrame`
- receipt for observation sessions
- Moonstat health/metrics integration

Exit criteria:

- bridge can start and stop cleanly
- stale telemetry is detected
- read-only sessions record evidence
- no motion commands are available through the bridge yet

## Phase 3: Safety-Gated High Control

Goal: allow constrained high-level commands with approval and receipts.

Deliverables:

- command-intent compiler for high-level actions
- safety gate with capability, mode, heartbeat, and approval checks
- dry-run requirement for risky actions
- manual approval flow in Rabbita
- bridge support for high-level actions only
- emergency stop / hold command path
- run evidence: intent, verdict, approval, bridge result, telemetry summary

Allowed first commands:

- observe
- stand / hold if supported safely by the bridge
- switch mode only when explicit and reversible
- high-level canned actions only behind approval

Blocked:

- arbitrary joint position control
- torque control
- learned policy execution
- autonomous physical task loops

Exit criteria:

- every physical command has a receipt
- unsafe verdicts cannot be bypassed through UI
- bridge failure preserves original error
- Moontown can see robot state but cannot execute without the gate

## Phase 4: Agentic Robot Process Pipeline

Goal: connect robots to Moontown and MoonClaw without losing safety or evidence.

Pipeline:

```text
request
  -> context pack
  -> task plan
  -> simulation or dry-run
  -> safety verdict
  -> approval
  -> execution
  -> telemetry observation
  -> reflection
  -> RobotBook evidence
  -> Moontown status update
```

Deliverables:

- Moontown resident robot agent projection from RobotBook, sidecar,
  observation, and receipt state
- standing-goal integration for scheduled observation and maintenance,
  beginning with `POST /api/moontown/tasks/observe`
- replay timeline projection for observation sessions through
  `GET /api/replays/{session_id}`
- telemetry frame ingestion for active observation sessions through
  `POST /api/sessions/{session_id}/frames`
- bounded observation run pipeline through
  `POST /api/moontown/tasks/observe-run`
- reusable `src/pipeline` process engine behind observation start, frame
  ingestion, stop, and bounded task runs
- MoonClaw planning and diagnosis tasks
- RobotBook run/evidence ledgers
- review queues for failed or risky runs
- replay links in town activity surfaces

Exit criteria:

- Moontown can read a resident robot projection without owning bridge control
- a Moontown standing goal can request a robot observation task through
  Moonrobo, with a receipt and observation session recorded
- a bounded observation run can collect frames, stop cleanly, and return replay
  plus resident state
- MoonClaw can produce a plan and diagnosis
- Moonrobo gates and records the run
- MoonBook receives durable evidence

## Phase 5: Dataset And Policy Work

Goal: collect and evaluate robot data before any learned-policy autonomy.

Deliverables:

- episode export format compatible with modern robot-learning workflows
- replay annotation UI
- dataset quality checks
- offline policy evaluation receipts
- policy proposal gate separate from physical execution gate

Rules:

- learned policies can propose actions
- learned policies cannot directly own hardware execution
- policy outputs must become command intents and pass the safety gate
- all policy runs must be replayable

## Phase 6: Fleet And Physical Town

Goal: scale from one robot to multiple robots and shared spaces.

Deliverables:

- ROS-style bridge option
- fleet/task adapter for multi-robot coordination
- shared map and location model
- robot-to-building protocol in Moontown
- maintenance and charging schedules
- multi-robot incident ledger

Exit criteria:

- robots are visible as resident agents in town
- shared physical tasks route through Moontown
- execution still happens only through Moonrobo safety gates

## Near-Term Task List

1. Add MoonBit core DTOs and validation tests.
2. Scaffold `examples/noetix-e1/robot.json`.
3. Start read-only SDK sidecar process around the `src/sdk_e1` snapshot contract.
4. Build Rabbita cockpit shell around the `src/cockpit` projection.
5. Package a local Lepus desktop prototype once the web cockpit is useful.
