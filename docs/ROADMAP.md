# Moonrobo Roadmap

Moonrobo starts as a documentation and contract project, then grows toward a
safe agentic robot process pipeline.

The guiding rule: build read-only visibility before actuation, simulation before
physical execution, and evidence before autonomy.

## Phase 0: Charter And Contracts

Goal: make the product boundary and safety model concrete.

Deliverables:

- architecture, safety, MoonBook/RoboBook, bridge, and interface docs
- MoonBit DTOs for robot profile, command intent, telemetry, safety verdict,
  and run receipt
- example MoonBook workspace with RoboBook decorator layout
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
- example MoonBook-backed RoboBook validates locally

## Phase 1: Digital Twin MVP

Goal: make robots inspectable before they are controllable.

Current state: RoboBook declares the robot model path through `robot.json`, the
example Noetix E1 profile points `model.primary` at a checked-in
`model/robot.urdf`, and RoboBook readiness requires that declared model
artifact. Rabbita now treats the URDF viewport as the primary embodiment
surface, not a fallback illustration. The desktop host exposes scoped,
read-only RoboBook asset bytes under `/api/robobook/assets/{path}` and the
cockpit mounts a Three.js URDF/STL scene from the same `model_viewport`
projection consumed by agents. The renderer joins URDF visual metadata with
world-space visual instances, loads every resolved STL mesh, applies telemetry
driven visual transforms, fits the camera to the resulting body, and leaves the
joint, visual, and model diagnostics below the 3D scene.

The shared MoonBit projection remains the product contract: model source,
renderer status, diagnostics, parsed link/joint counts, RoboBook-to-URDF
mapping counts, structured `world_basis` orientation, telemetry-bound joint
pose rows, URDF limit state, visual geometry rows, mesh readiness, and
world-space visual instances. Real URDF package import is part of the platform
path: Rabbita and the host API can import an extracted URDF folder into
`model/imports/`, rewrite ROS-style `package://` mesh references to local
RoboBook paths, derive non-fixed joints, and activate the imported model in
`robot.json`.

This means the current visualization answer is "yes, in Rabbita, as a real
3D URDF/STL digital-twin viewport." It is not yet a physics simulator, but it
is already the product surface where an operator or resident agent can inspect
whether the selected RoboBook, URDF, mesh assets, link tree, and telemetry frame
agree.

Deliverables:

- Rabbita robot cockpit shell
- URDF-backed schematic model viewport for robot body and joints
- Three.js URDF/STL cockpit viewport backed by RoboBook asset routes
- URDF-backed link-pose simulation projection for agents and UI
- URDF visual geometry rows and local mesh asset readiness projection
- URDF visual instance projection with world-space pose per renderable visual
- extracted URDF package import into RoboBook `model/imports/`
- RoboBook loader
- joint and capability inspector
- model artifact diagnostics for missing URDF, missing meshes, unknown joints,
  and telemetry/model mismatch
- simulated telemetry stream
- replay timeline for recorded frames
- Lepus desktop bundle descriptor and launch scripts

The sibling robot-canvas work in `../olu` should be treated as a reference for
visual and file-handling patterns. Moonrobo should keep its own product surface:
operator cockpit, safety gate, resident robot state, and process evidence.

The next model milestone is a full URDF editor lane, documented in
[`URDF_EDITOR.md`](URDF_EDITOR.md). That lane should stay separate from the
robot execution loop: it edits RoboBook model evidence, validates topology and
mesh readiness, records model-edit receipts, and refreshes the same
digital-twin projection used by operators and agents.

The next replay milestone is a browser-safe replay and simulation lane,
documented in [`REPLAY_SIMULATION_PLAN.md`](REPLAY_SIMULATION_PLAN.md). It
should turn RoboBook telemetry and dataset episodes into explicit trajectory
artifacts, add cockpit timeline and overlay review, and keep browser-side
physics or policy experiments separate from physical bridge execution.

Exit criteria:

- a RoboBook can open in the cockpit
- the cockpit resolves `model.primary` and renders the 3D URDF/STL viewport or
  a clear model diagnostic
- the joint list is mapped to both the declared RoboBook joints and the rendered
  model joints
- live or replayed telemetry can drive joint transforms in the model viewport
- a simulated run produces a receipt
- no hardware SDK is required

## Phase 2: Read-Only Hardware Bridge

Goal: observe real robot state safely.

Current state: the SDK-shaped bridge, telemetry conversion, native supervisor
runner, persisted runtime health evidence, MoonBook memory recall, and
desktop/Rabbita runtime panel are in place. The observation path gives one
selected RoboBook a typed SDK telemetry boundary.

Deliverables:

- `sdk-e1-bridge` sidecar around `../sdk`
- bridge health endpoint
- desktop `/api/runtime/health` snapshot that combines active supervisor state
  with a bridge telemetry probe
- RoboBook `runs/runtime-health/latest.json` evidence feeding MoonBook memory
- read-only APIs for mode, joint state, IMU, joystick, and bridge metadata
- telemetry conversion into Moonrobo `TelemetryFrame`
- receipt for observation sessions
- Moonstat health/metrics integration

Exit criteria:

- bridge can start and stop cleanly
- stale telemetry is detected
- Rabbita and Moontown can see whether runtime status is `healthy`,
  `not-running`, or `bridge-unhealthy`
- read-only sessions record evidence
- no motion commands are available through the read-only observation bridge

## Phase 3: Safety-Gated High Control

Goal: allow constrained high-level commands with approval and receipts.

Current state: user messages can become MoonBook task-message plans, reviewed
command intents can collect evaluation/dry-run/approval evidence, desktop
execution requires an active supervised runtime, and each host or sidecar
execution writes a compact task-execution snapshot that links the message plan,
bridge dispatch, receipt, MoonBook memory, runtime-health evidence, and matched
telemetry feedback with a persisted feedback artifact path. Snapshots also
classify the command outcome for the executed capability, starting with
motion-feedback-checked for high-control walk/run commands only when the
feedback artifact echoes the submitted command, bridge request, and receipt.
The SDK E1
bridge can now run in `control-gated` mode and translate allowlisted high-control
walk/run intents into the reference SDK command envelope. That envelope is now
persisted to a supervised command outbox consumed by
`bridges/sdk_e1/sdk_e1_high_control_writer.py`, which can dry-run for fixture
smoke checks or publish through the SDK `HighController` binding when launched
against a live SDK. The bridge also exposes `POST /emergency/stop`, which
writes a zero-motion SDK `DEFAULT` command envelope and returns an executed
emergency receipt without entering the normal task-message approval flow. The
desktop host now exposes that through `POST /api/runtime/emergency-stop`, and
Rabbita renders it as a Bridge-panel action with timestamped request, receipt,
and dispatch evidence. Runtime validation reports now persist the stricter
readiness gate joining supervisor readiness, process state, telemetry identity,
and runtime-log evidence, and physical sidecar execution now blocks unless that
report is `ready`. Repeated validation sessions now aggregate multiple samples
into one RoboBook evidence artifact and produce calibration plans for blocked
readiness checks. The remaining gaps are running those sessions against live
hardware, a stronger vendor-specific stop primitive if the SDK exposes one, and
richer one-to-one calibration evidence. Runtime calibration is no longer only
advisory queue work: unresolved blockers and resolved-but-not-revalidated
calibration actions are projected into platform readiness and block explicit
dispatch until repeated validation refreshes the evidence. Task-loop recovery
uses those readiness actions as its continuation route, keeping Rabbita and
Moontown pointed at calibration or validation work instead of falsely presenting
the task as ready to dispatch. Runtime validation sessions now also carry an
explicit mapping proof: each sample records the observed robot and bridge ids,
then the session reports whether all samples matched the selected RoboBook
mapping. The first MoonClaw-to-Moonrobo robot lane is now in place through
`POST /api/moonrobo/gateway/command`: MoonClaw owns the routine policy and
submits the selected command, while Moonrobo records the command as durable task
ingress, refreshes MoonBook-backed task evidence, and reports the next safe
route. `POST /api/moonrobo/proof-session` repeats the proof path as a bounded
session, stops on verified completion or stalled progress, and persists
`runs/proof-sessions/{session_id}.json` for Rabbita, MoonClaw, and Moontown.

Deliverables:

- command-intent compiler for high-level actions
- safety gate with capability, mode, heartbeat, and approval checks
- profile motion limits for high-control walk/run parameters
- dry-run requirement for risky actions
- manual approval flow in Rabbita
- bridge support for high-level actions only
- supervised high-control command writer process
- emergency stop / hold command path with receipt evidence
- timestamped event IDs for repeated physical stop events
- run evidence: intent, verdict, approval, bridge result, telemetry summary
- task execution snapshots that give operators and agents one durable
  inspection handle for each user-visible task
- gateway-command artifacts that capture MoonClaw-authored command ingress,
  mapped RoboBook identity, MoonBook task evidence, readiness, and next route
- proof-session artifacts that collect repeated prove-loop attempts without
  creating another conversation or memory store

Allowed first commands:

- observe
- emergency stop / hold through the dedicated bridge route
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

The target shape is a closed gateway command loop. MoonClaw owns planning,
diagnosis, and next-step choice. Moonrobo owns the gateway: RoboBook identity,
readiness, safety, calibration, validation, dispatch, telemetry proof, and
recovery. MoonBook owns durable memory and conversation. RoboBook stays a thin
physical decorator around the MoonBook workspace. Every observation, blocker,
validation, execution, and lesson must write RoboBook evidence and update
MoonBook memory before MoonClaw chooses the next robot step.

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
  -> RoboBook evidence
  -> MoonBook memory
  -> Moontown status update
```

Deliverables:

- MoonClaw `Robot` routine lane that talks to Moonrobo gateway routes, never to
  raw bridge or SDK control
- Moontown resident robot agent projection from RoboBook, sidecar,
  observation, and receipt state
- standing-goal integration for scheduled observation and maintenance,
  beginning with `POST /api/moontown/tasks/observe`
- task-message ingress through `POST /api/moontown/tasks/message`, mapping
  user language into observation, command-review, or maintenance-review task
  plans, with physical execution disallowed unless a later gated route approves
  it
- task-message ledger projection through `GET /api/moonbook/task-messages`,
  with review-classified plans entering the MoonClaw platform queue
- task-message conversation projection through `GET /api/moonbook/conversation`,
  using the same MoonBook records as the one-to-one user/Robo transcript
- replay timeline projection for observation sessions through
  `GET /api/replays/{session_id}`
- telemetry frame ingestion for active observation sessions through
  `POST /api/sessions/{session_id}/frames`
- bounded observation run pipeline through
  `POST /api/moontown/tasks/observe-run`
- source-injected observation pipeline and native `observe-run-sidecar` command
  that polls the SDK bridge sidecar over HTTP before writing replay evidence
- SDK E1 bridge telemetry source that can read a collector-produced
  `SdkE1Snapshot` JSON file instead of only generated snapshots
- reusable `src/pipeline` process engine behind observation start, frame
  ingestion, stop, and bounded task runs
- deterministic `src/review` diagnosis records and `GET /api/reviews` queue
- MoonClaw evidence-only context projection through `GET /api/moonclaw/context`
- RoboBook run/evidence ledgers
- review queues for failed or risky runs
- replay links in town activity surfaces
- Moonstat status projection through `GET /api/moonstat/status` for suite
  health, evidence counts, latest run, replay, and review pressure
- MoonBook memory projection and persistence through `GET /api/moonbook/memory`
  and `POST /api/moonbook/remember`
- MoonClaw platform queue projection through `GET /api/moonrobo/platform-queue` for the next
  Moontown/Rabbita action across bridge, task-message, review, replay, dataset,
  and policy evidence
- registered route authority through `GET /api/tools/registry`, so MoonClaw can
  combine platform-queue pressure with bounded Moonrobo capability metadata instead
  of relying on private route knowledge
- read-only Moonrobo live-exercise audit history, while the MoonClaw platform queue
  exposes explicit pressure points instead of a Moonrobo-owned aggregate routine
  item
- persisted MoonClaw/tool registration contract through `GET /api/tools/registry`
  and `POST /api/tools/register`, treating Moonrobo workers and suite tools as
  bounded capability providers, not robot bodies or hidden operators
- MoonClaw context payload that includes the current MoonBook memory pack,
  embedded platform queue, registered Moonrobo tool capabilities, platform
  readiness report, readiness plan, live-readiness preflight, proof-session
  history, and live-exercise closure history, so MoonClaw-side routine
  selection can use durable recall, work-pressure evidence, typed route
  authority, calibration/validation blockers, and current closed-loop evidence
  together
- MoonClaw-owned routine execution outside Moonrobo: MoonClaw reads context,
  selects registered Moonrobo tools or gateway commands, and relies on Moonrobo
  to persist evidence while the durable MoonClaw `/run` endpoint refreshes
  MoonBook memory and records before/after context after successful safe calls
- gateway-hosted MoonClaw robot routine API through
  `POST /v1/robot/routine`, `POST /v1/robot/routine/invoke`, and
  `POST /v1/robot/routine/run`, with `../moonclaw/cmd/robot_routine` kept as a
  local probe that consumes the same context JSON contract without importing
  Moonrobo implementation packages
- Moonrobo command ingress through `POST /api/moonrobo/gateway/command`,
  accepting MoonClaw-authored robot commands as durable gateway/task input
- platform readiness report through `GET /api/moonrobo/readiness`, joining
  RoboBook readiness, MoonBook task-message conversation, MoonBook memory,
  bounded tool registry, runtime health, and task-execution evidence into one
  first-milestone status
- user-facing ask wrapper through `POST /api/moonrobo/ask`, joining task-message
  persistence, MoonBook conversation, refreshed memory, loop proof, live
  readiness, and the current Robo handoff without creating a separate chat
  platform; Rabbita's primary Ask action then calls MoonClaw's
  `POST /v1/robot/routine/run` endpoint for accepted non-review tasks
- explicit repair/proof routes for bootstrap, one-gate task advancement,
  runtime proof, loop proof, and bounded proof-session attempts
- explicit Moonrobo gateway command ingress through
  `POST /api/moonrobo/gateway/command`, accepting the command MoonClaw selected
  without hosting MoonClaw routine policy inside Moonrobo
- live exercise closure summary as read-only audit evidence, with missing
  closure routed back to MoonClaw context instead of a Moonrobo runner
- live exercise history through `GET /api/moonrobo/live-exercises` and detail
  reads for comparing repeated hardware-hardening attempts
- Rabbita Platform Readiness control focused on explicit validation,
  proof-session, feedback, memory, and history surfaces instead of an aggregate
  live-exercise button
- execution-proof projection through `GET /api/moonrobo/executions`, exposing
  persisted task-execution snapshots and their post-dispatch verification
  state, including physical feedback status from runtime telemetry and command
  outcome status from the executed capability
- execution-aware resident and agent planning: latest execution proof is
  surfaced through Moontown resident state, MoonBook memory, MoonClaw context,
  and `bind-execution-feedback` work against the bounded feedback route before
  new robot processes are scheduled
- explicit native dispatch remains on the reviewed MoonBook task-message
  `/execute-sidecar` route after runtime validation and approval gates are ready
- runtime proof ingress through `POST /api/moonrobo/runtime-proof`, accepting
  only telemetry that matches the selected RoboBook robot and bridge ids and an
  existing active supervised-runtime health record before persisting
  runtime-health evidence

Exit criteria:

- Moontown can read a resident robot projection without owning bridge control
- a Moontown standing goal can request a robot observation task through
  Moonrobo, with a receipt and observation session recorded
- a user can submit a task message through Rabbita or Moontown and advance a
  reviewed command through evaluation, dry-run, approval, runtime readiness, and
  bridge execution evidence
- Rabbita can issue a dedicated emergency stop through the active runtime bridge
  and persist receipt plus dispatch evidence
- Rabbita can show the latest runtime validation report and live-SDK readiness
  for the selected RoboBook/bridge mapping, including repeated-sample mapping
  proof for observed robot and bridge ids
- a bounded observation run can collect frames, stop cleanly, and return replay
  plus resident state
- MoonClaw can produce a plan and diagnosis, execute the first evidence-only
  gateway remediation for runtime validation, and remember the result in
  MoonBook before the next turn
- Moonrobo gates and records the run
- MoonBook receives durable evidence and memory; RoboBook exposes the robot
  projection over that evidence
- Moonstat can read one compact status document without controlling the robot
- Rabbita and Moontown can read one prioritized platform queue without owning bridge
  control or parsing RoboBook files
- a user can submit a task message through Rabbita or Moontown and have it
  become either a safe observation session or a durable review-classified
  MoonBook task-message plan that appears in the platform queue without a separate
  durable chat platform; command-review plans now carry an intent draft that
  Rabbita advances through shared MoonBook task-message safety routes
- MoonClaw can call Moonrobo through typed tool capabilities, and meaningful
  observations, review holds, and runtime validation remediations are remembered
  through MoonBook instead of being lost in agent context
- `GET /api/moonrobo/readiness` reports `ready` for the selected live RoboBook
  root after a user task message has passed review, reached the supervised SDK
  bridge, written runtime-health evidence, and produced a task-execution
  snapshot
- The practical distance to the desired first loop is: MoonBook task-message
  conversation and RoboBook memory are present; reviewed user commands can
  dispatch when runtime proof and explicit operator dispatch are present; the
  dispatch now writes the task-execution snapshot used by readiness, MoonBook
  memory, Moontown resident state, MoonClaw context, and Rabbita. The remaining
  work is repeated live hardware validation, calibration, and stronger physical
  feedback binding, not a separate durable chat platform.

## Phase 5: Dataset And Policy Work

Goal: introduce MoonData as the unique robot data plane before any
learned-policy autonomy.

Deliverables:

- MoonData contract packages for sources, captures, dataset manifests,
  episodes, frame refs, signal refs, quality findings, transforms, annotations,
  versions, replay artifacts, and export manifests
- local MoonData root initialization and path derivation
- Moonrobo capture registration for observation sessions, task executions, and
  command-feedback telemetry
- RoboBook `runs/data-refs/` ledger entries that point to MoonData ids instead
  of owning raw data
- canonical episode and frame manifests derived from accepted Moonrobo
  observations and executions
- quality checks owned by MoonData: timestamp gaps, frame-count thresholds,
  stale telemetry, robot/bridge identity mismatch, command echo mismatch,
  unsafe outliers, missing annotations, and rejected captures
- replay annotation ledger and UI backed by MoonData episode/frame refs
- non-destructive cleaning and curated dataset versions with lineage
- export manifests compatible with modern robot-learning workflows
- Moonrobo platform queue visibility for readiness, review, command-message,
  proof, and MoonData quality/curation pressure
- MoonClaw context that carries bounded MoonData refs and summaries instead of
  raw data blobs

Rules:

- MoonData is the only authority for raw robot data, cleaned datasets, quality
  reports, replay artifacts, annotations, curated versions, and exports
- RoboBook can reference MoonData artifacts and store accepted robot-domain
  summaries, but it must not become a raw or cleaned dataset store
- MoonClaw policies can propose actions from RoboBook evidence and bounded
  MoonData refs
- MoonClaw policies cannot directly own hardware execution
- policy outputs must become Moonrobo task messages or command intents and pass
  the explicit safety gate
- all policy analysis must be replayable from MoonData manifests and RoboBook
  control evidence
- replay annotations are MoonData artifacts and must remain linked to dataset,
  episode, frame, session, and receipt ids

Exit criteria:

- one Moonrobo observation session can register a MoonData capture session,
  canonical episode, and frame refs
- one task execution snapshot can link to a MoonData command-feedback frame or
  episode
- RoboBook memory cards contain accepted MoonData refs rather than raw dataset
  ownership
- Moonrobo readiness and platform queue can surface MoonData quality pressure
- a curated dataset version can be exported from MoonData with lineage and a
  verification report

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
5. Package the Rabbita build beside the native desktop and bridge binaries.
6. Wrap the generated release bundle in a Lepus desktop prototype.
7. Run the runtime-proof path against the supervised SDK bridge and real
   telemetry.
8. Run MoonClaw robot routine against the supervised SDK bridge or simulator and
   verify the resulting runtime-health evidence, validation session,
   MoonClaw gateway-command artifact, proof-session
   artifact, bridge receipt, dispatch evidence, execution snapshot, Robo loop
   artifact, live closure, and MoonBook memory on a live RoboBook root.
9. Add operator review UI for command-review and maintenance-review task
   messages.
