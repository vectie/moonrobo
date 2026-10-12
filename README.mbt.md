# MoonRobo

> **Domain product · experimental hardware boundary.** Read the
> [product contract](docs/PRODUCT_CONTRACT.md) for the corrected MoonFlow /
> MoonClaw / MoonRobo call chain, physical authority and validation gates.

MoonRobo is the physical-world interface layer for the Moon agent suite.

It should bring robots into the same operating model as MoonDesk, MoonTown,
MoonBook, MoonClaw, and MoonGate, while keeping the physical execution boundary
explicit and auditable.

MoonRobo is built around:

- MoonBit for the core contracts, command model, safety model, and local
  services
- Rabbita for the web operator interface
- Lepus for the desktop shell
- MoonBook for the durable `books/<book-id>` book, accepted evidence, memory
  packs, task messages, and review queues
- RoboBook as the robot-domain decorator on MoonBook: robot identity, models,
  calibration, safety policy, bridge configuration, runs, data references, and
  accepted evidence summaries
- MoonData for the robot data plane: raw captures, canonical datasets, quality
  findings, cleaning lineage, replay artifacts, annotations, and exports
- bridge sidecars for simulator, SDK, and ROS-style hardware integration

The first hardware reference target is the local Noetix E1 SDK in `../sdk`.
The first interface reference is the sibling robot canvas work in `../olu`.

## Product Boundary

MoonRobo is not the scheduler, model runtime, durable knowledge store, or proxy
gateway.

- MoonTown owns standing goals, schedules, routing, resident robot agents, and
  mayor supervision.
- MoonClaw owns bounded agent execution, planning, diagnostics, and tool use.
- MoonBook owns durable robot books, pages, attachments, accepted evidence,
  review queues, and memory.
- MoonData owns raw and derived robot data: captures, datasets, episodes,
  frames, quality reports, annotations, lineage, and export manifests.
- MoonGate owns observability, suite status, usage, and runtime metrics.
- MoonLib owns shared MoonSuite filesystem contracts; MoonRobo product-home and
  suite-temp helpers are thin adapters over `@moonsuite`.
- MoonRobo owns robot-facing interfaces: robot profiles, digital twins,
  command intents, telemetry, safety gates, bridge protocols, teleoperation,
  RoboBook decorators, MoonData registration, and operator controls.

## Design-linked digital build

MoonRobo can build and independently validate a fresh, simulation-only
excavation-haul RoboBook from a typed design:

```text
moon run cmd/main -- build-design <robot-design.json> <robobook-root> <recorded-at> <workspace-relative-source-artifact>
moon run cmd/main -- validate-design <robobook-root> <recorded-at>
```

The `moonsuite.robot-design.v1` input must use `digital-only` authority and the
`excavation-haul-rover` class, and must carry at least four task-loop steps,
three mechanisms, three measurable validation scenarios, and a positive
commanded-speed limit. The generated profile contains four mobility joints,
an excavation lift, bucket tilt, tipping bed, payload and tool sensing, and a
simulation-only bridge. Build and validation receipts retain task-loop,
mechanism, scenario, and joint counts.

Validation re-derives the profile from the persisted typed design, checks every
profile joint against the URDF, and rejects identity drift, missing design
evidence, unsafe bridge configuration, or non-digital policy. Passing this gate
means structure-and-safety validated for MoonMoon handoff; it does not mean
mission performance or physical readiness.

## Closed Robot-Agent Loop

The target loop is evidence-backed and keeps domain policy outside MoonClaw:

```text
MoonDesk operator review
  -> MoonFlow durable work and authority state
  -> MoonClaw generic reasoning/tool execution when required
  -> installed MoonRobo adapter operation
  -> MoonRobo readiness, safety and calibration gates
  -> bounded robot bridge execution or refusal
  -> telemetry and proof receipt
  -> MoonBook accepted outcome and Bookkeeper Three-Gap analysis
```

MoonClaw owns generic agentic reasoning. MoonRobo owns robot operations,
physical safety, runtime validation, bridge dispatch and control evidence.
MoonData owns raw and derived robot-data lineage. MoonBook owns accepted memory
and outcome learning. MoonClaw never calls a raw SDK or bridge.

The former MoonClaw-hosted `POST /v1/robot/routine/run` path is retired and must
not be used as the product integration boundary. The current executable target
is an installed MoonRobo adapter discovered by MoonDesk/MoonFlow and invoked
through MoonClaw's generic tool runtime when reasoning is needed. MoonRobo's
readiness, context, proof-session and bounded command routes remain
product-owned implementation surfaces.

MoonRobo now publishes [`pack.json`](pack.json) and the executable
`moonrobo-local-v1` adapter. The cross-product digital-model operation is
`moonrobo/robot.integrate-digital-model@0.2.0`; readiness inspection and
governed command ingress are separate typed operations. The adapter persists
attempts and reconciles unknown outcomes before any retry. It never exposes
physical-effect authority.

## Documents

- [Compare measurements by recorded mode](docs/offline-state-conditioned-distribution.md)
- [Inspect recorded-state durations and export runs](docs/offline-recorded-state-duration.md)

- [Import recorded ROS 2 JointState messages](docs/offline-ros2-joint-state.md)

- [Explicit recorded telemetry time buckets](docs/offline-telemetry-buckets.md)
- [Pack Adapter](docs/PACK_ADAPTER.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [RoboBook](docs/ROBOBOOK.md)
- [MoonData](docs/MOONDATA.md)
- [Safety](docs/SAFETY.md)
- [Bridge Protocol](docs/BRIDGE_PROTOCOL.md)
- [Interface Plan](docs/INTERFACE_PLAN.md)
- [Agent Integration](docs/AGENT_INTEGRATION.md)
- [Runtime Slice](docs/RUNTIME.md)
- [Desktop Host](docs/DESKTOP_HOST.md)
- [Desktop Bundle](docs/DESKTOP_BUNDLE.md)
- [Replay And Simulation Plan](docs/REPLAY_SIMULATION_PLAN.md)
- [Rabbita Cockpit](ui/rabbita-cockpit/README.md)

## Initial Shape

```text
MoonRobo
  MoonBit core contracts
  Rabbita web cockpit
  Lepus desktop shell
  MoonSuite books/<book-id> MoonBook
  RoboBook decorator
  safety gate
  robot bridge sidecars
  simulator and replay surfaces
```

The first milestone started read-only and now reaches the first gated physical
handoff: one MoonBook-backed RoboBook maps to one supervised SDK runtime,
telemetry is persisted as evidence, reviewed user task messages can dispatch
allowlisted, profile-limited high-control envelopes only after the active
runtime telemetry confirms the selected robot and bridge identity, and a
dedicated SDK writer owns the final vendor-control call. Rabbita also exposes
the dedicated emergency stop route for the active runtime bridge, with
timestamped receipt and dispatch evidence. Arbitrary motion, low-control APIs,
learned-policy actuation, and autonomous physical loops remain outside the
boundary.

Current distance to the first goal is measurable through two read-only routes.
`GET /api/moonrobo/readiness` reports missing substrate and an ordered
remediation plan. The report is `ready` only when the selected RoboBook root has
one-to-one profile readiness, MoonBook task messages, persisted MoonBook
memory, bounded tool registration, healthy runtime evidence, and at least one
task-execution snapshot. `GET /api/moonrobo/loop-proof` answers the product
question directly: it scores the proposed closed loop across digital/physical
mapping, Robobook/MoonBook memory, user-message ledger, MoonFlow/MoonClaw
attempt receipts, canonical Robo loop artifact, and verified physical feedback. The
bounded `POST /api/moonrobo/prove-loop` route then takes the same product goal
as far as the current RoboBook root can prove without making a policy decision:
it bootstraps non-physical substrate, reconciles queued feedback evidence when
available, persists `.moonsuite/products/moonrobo/prove-loop/{proof_id}.json`,
writes the refreshed MoonBook memory pack, and returns before/after loop-proof
evidence. If the next
missing item is a robot routine command, it stops at
`POST /api/moonrobo/gateway/command`; MoonClaw must choose and submit that
command. The plan turns every failing readiness check into a safe next route,
such as tool-registry bootstrap, MoonBook memory persistence, runtime
supervision, MoonClaw command ingress, or platform-queue review.
`POST /api/moonrobo/bootstrap` applies the non-physical
substrate steps for a fresh root: bounded tool registry, MoonBook memory, and a
first reviewed task message. `POST /api/moonrobo/advance` then moves that
reviewed message through one safety gate at a time, stopping at live-runtime
validation before any physical dispatch. Those lower-level routes remain
explicit repair tools. The user-message product lane starts in MoonRobo and
hands declared work to MoonFlow. When generic reasoning is needed, MoonClaw
invokes the selected MoonRobo adapter operation. Rabbita does not need a
separate chat platform: the message remains a MoonBook task message, and
MoonFlow/MoonClaw receipts retain the agent-side execution record.
`GET /api/moonrobo/session` exposes that same session as a read-only product
surface: Rabbita, MoonTown, and MoonClaw can read the current Robo session,
conversation, resident mapping, execution proof, latest loop summary, latest
turn/step evidence, memory pack, and current owner/route decision without
creating a second chat store or starting a new task.
Rabbita now loads this route directly in the task surface, so the cockpit shows
the canonical one-to-one Robo session before the lower-level task ledger and
conversation details, while also restoring who owns the next safe action.
`POST /api/moonrobo/loop` is now the preferred MoonRobo product loop. One
request may carry a user task message, persists a canonical loop artifact under
`.moonsuite/products/moonrobo/robo-loops/`, and stops at the current owner
handoff. When that owner is MoonClaw, MoonClaw's gateway performs the policy
step from MoonRobo context.
`GET /api/moonrobo/loops` and `GET /api/moonrobo/loops/{loop_id}` expose that
history for replay and audit. The lower-level `ask`, `turn`, and `step` routes
remain the concise components used by the loop and by focused debugging tools,
not a separate chat platform.
The default Rabbita "Ask Robo" action now posts to `POST /api/moonrobo/loop`,
then reloads loop, turn, step, session, memory, readiness, and proof evidence.
The task surface shows the canonical loop artifact first, with durable turn and
step history still available for replay and debugging.
MoonRobo does not expose a second agent runtime.
`GET /api/moonrobo/steps` and `GET /api/moonrobo/steps/{step_id}` remain history
surfaces for existing Robo step artifacts. New attempts are persisted through
MoonFlow and MoonClaw generic receipts so the next step is grounded in MoonBook
memory and MoonRobo evidence rather than ephemeral chat.
When a command-enabled sidecar returns command feedback telemetry, MoonRobo
persists that frame and a matching runtime-health record directly into the same
execution snapshot.
`POST /api/moonrobo/executions/feedback` is the explicit gateway-server
version of that same binding: given an existing execution snapshot and a
telemetry frame, it persists the frame, checks robot/bridge identity and command
echo evidence, rewrites the snapshot, refreshes MoonBook memory, and updates
the execution proof report.
The final MoonBook memory pack for that task is written after the snapshot, so
Robo remembers the completed execution immediately.
`GET /api/moonrobo/executions` projects persisted task-execution snapshots into
a proof report with the latest task, bridge status, runtime status, physical
feedback status, and verified count after matched telemetry is captured from
the selected runtime. A snapshot is fully verified only when the executed
receipt, accepted bridge dispatch, healthy runtime, and fresh telemetry frame
agree, and the command outcome is classified for the executed capability
(`motion-feedback-checked`, `stop-feedback-checked`, or another explicit
outcome state). A matched telemetry frame is only `*-observed` until the
feedback artifact also echoes the submitted command capability, intent id, and
any persisted walk/run parameters. That same checked proof state now feeds the
MoonTown resident,
MoonBook memory, MoonClaw context, and
`/api/moonrobo/platform-queue`, where an unverified latest execution becomes
`bind-execution-feedback` work against `/api/moonrobo/executions/feedback`
before more robot work is scheduled.
`POST /api/moonrobo/runtime-proof` is the next bridge between software
readiness and physical readiness: it accepts a telemetry frame from the active
supervised runtime, verifies that the frame matches the selected RoboBook robot
and bridge ids, persists the full frame under `runs/telemetry/runtime-proof/`,
and records that artifact path in runtime-health proof evidence.
The MoonFlow/MoonClaw/MoonRobo adapter path turns a user message into one
durable governed attempt. It captures MoonRobo context, selects a declared
operation, invokes the safe product-owned step, and records refusal or
completion evidence. Until those adapter runs are green on a live RoboBook
root, the remaining first-goal work is real hardware runtime evidence,
calibrated stability, and sustained MoonTown scheduling over the same proof
surface, not a separate chat platform. Rabbita and the desktop host can now run repeated
validation through
`POST /api/runtime/validation/session`, which persists every sample report, the
latest aggregate validation session, and a session-derived calibration plan.
`GET /api/moonclaw/runtime-calibration/latest` projects that plan as MoonClaw work,
and `POST /api/moonclaw/runtime-calibration/resolve` persists the operator or
MoonClaw resolution under
`.moonsuite/products/moonrobo/runtime-calibration/resolutions/`. Until a newer
validation session exists, `/api/moonrobo/platform-queue` raises a
higher-priority `validate-runtime` item that points back to
`POST /api/runtime/validation/session`, so the same evidence loop proves the
fix before another robot-routine attempt. Readiness now projects that
same state as dispatch blockers: unresolved calibration points to
`/api/moonclaw/runtime-calibration/latest`, and a resolved calibration action blocks
physical dispatch until a newer validation session is persisted through
`POST /api/runtime/validation/session`. A newer ready validation session clears
stale calibration pressure even if an older plan remains on disk.
That puts the project at the first software proof surface for the user-visible
physical milestone: one digital Robo identity can accept a user message, pass
through MoonClaw/MoonRobo recovery, persist one combined proof artifact, and
report whether the live execution is verified. `GET /api/moonrobo/loop-proof`
and `moon run cmd/main -- loop-proof [robobook-root]` now summarize that state
as complete, operational-unproven, or incomplete; `moon run cmd/main --
prove-loop [robobook-root] [message] [now-ms]` runs the
bounded first proof attempt and records the latest `closed-loop-proof` memory
card. `POST /api/moonrobo/proof-session` and `moon run cmd/main --
proof-session [robobook-root] [message] [now-ms]
[iterations]` now repeat that proof attempt as one persisted session, stopping
when the loop is complete or when the same blocker repeats without progress.
`GET /api/moonrobo/live-readiness` and `moon run cmd/main -- live-readiness
[robobook-root]` sit before that proof loop: they report whether the latest
runtime validation and calibration state is clear enough to run proof sessions,
or whether MoonClaw should first call the validation or calibration route. In
that live-ready proof state, `can_run_robot_routine` means the bounded routine
lane can collect proof; `physical_execution_allowed` remains false until loop
proof is verified.
`GET /api/moonrobo/proof-sessions` and
`GET /api/moonrobo/proof-sessions/{session_id}` expose those persisted proof
sessions for Rabbita, MoonTown, and MoonClaw to reopen sustained proof history
without launching another robot or MoonClaw routine loop.
The remaining gap is running those sessions repeatedly on live hardware with
calibrated runtime stability and sustained MoonTown work scheduling over the
same evidence.

## Digital robot design

The cockpit's **Design a digital robot** workbench edits bounded excavation-haul
concepts, saves immutable revisions, builds and validates digital artifacts, and
exports exact robot inputs for MoonMoon. See
[the workbench guide](docs/digital-design-workbench.md) for supported fields,
revision recovery and the digital-only boundary.

### Offline sensor recording merge

Combine independently recorded pose, joint or sensor channels into one reusable
numeric CSV. The [offline sensor merge guide](docs/offline-sensor-merge.md) covers
exact or bounded-nearest alignment, explicit clock offsets, channel prefixes,
source-time reports and the synthetic pose/sensor example. Its output feeds the
existing explorer, comparator and trajectory tools without opening a device.

### Observed threshold episodes

Locate consecutive recorded samples strictly above or below a chosen channel
threshold, split on explicit sample gaps, and export exact timestamp endpoints,
source sample positions, counts and extrema as JSON or CSV. The
[threshold episode guide](docs/observed-threshold-events.md) explains observed
spans, equality boundaries and limits. This does not infer crossings or incidents.

### Explicit offline telemetry normalization

Rename channels and apply user-supplied scale/offset recipes before comparison.
The [normalization guide](docs/offline-telemetry-normalization.md) includes a
synthetic recipe, reusable CSV and a JSON report retaining original names and
unit labels. Timestamps stay exact; no units or calibration are inferred.

### Offline CSV telemetry exploration

Inspect timestamped joint and sensor recordings and export a selected time window
as numeric JSON with channel summaries:

```sh
moon run cmd/telemetry_csv --target native -- examples/telemetry/joints.csv 1020 1050
```

See [offline telemetry CSV](docs/offline-telemetry-csv.md) for the schema, sample,
CLI exit codes and export workflow. This command is offline and never dispatches
to hardware.

### Compare recorded runs

Compare a baseline and candidate recording on elapsed time, select channels or a
window, and export per-sample deltas plus bias, absolute, RMS and peak differences:

```sh
moon run cmd/telemetry_compare --target native -- examples/telemetry/baseline-run.csv examples/telemetry/candidate-run.csv --max-gap-ms 200
```

The [offline run comparison guide](docs/offline-run-comparison.md) explains exact
matches, optional bounded interpolation, visible gaps, JSON/CSV exports, and the
need for matching units and comparable run starts.

### Inspect recorded XY motion

Map named Cartesian position channels to an equal-scale route with disconnected
gaps, observed chord distance, interval speed and portable SVG/JSON/CSV exports:

```sh
moon run cmd/telemetry_path --target native -- examples/telemetry/rover-path.csv pose.x.m pose.y.m --units m --svg
```

The [offline trajectory guide](docs/offline-trajectory.md) explains mapping,
absolute time windows, cutoff selection and the limits of sampled motion.

## Structured JSONL telemetry import

Structured recorder exports can first pass through
[`telemetry_import_jsonl`](docs/offline-telemetry-jsonl.md): explicit nested-object
key paths select ordered channels and exact decimal-string millisecond timestamps.
It retains physical source-line numbers in JSON and emits numeric CSV for the
existing offline tools. See the synthetic JSONL recording and recipe in that guide.

## Recorded electrical power and energy

Use [`telemetry_energy`](docs/offline-electrical-energy.md) to derive sample
power and drawn/recovered/net Wh from explicitly selected voltage and current.
The offline workflow uses an explicit current convention, splits modeled
sign reversals and excludes recording gaps. JSON retains source observations
and interval lineage; reusable CSV feeds the existing explorer and plots.
These are estimates over supported intervals, not battery charge or hardware proof.

## Unwrap recorded periodic joint angles

Use [`telemetry_unwrap`](docs/offline-periodic-unwrapping.md) to remove wrap-boundary
jumps before plotting or deriving motion from periodic encoder channels. Supply
an explicit period, output name and unit per channel. Each gap-separated segment
starts from its own raw anchor; JSON retains corrections and half-period ties,
and CSV feeds the existing motion workflow. Hidden rotations cannot be recovered
from sparse samples; this is a shortest-displacement estimate, without hardware.

## Recorded joint motion estimates

For recordings containing positions but no velocity or acceleration, use
[`telemetry_motion`](docs/offline-joint-motion.md) to derive selected joint rates
or nonuniform-time acceleration estimates. Explicit units and gap limits,
source stencils and missing-estimate reports accompany reusable numeric CSV.
This is offline finite-difference analysis, without physical dispatch.

## Recorded telemetry time-series plots

Inspect selected recorded channels in stacked SVG panels with a shared time axis,
explicit supplied unit labels, independent Y scales and visible sample gaps.
`telemetry_plot` also exports exact selected observations and source positions
as JSON. See the [offline plotting guide](docs/offline-telemetry-plot.md) and its
synthetic input. This is recorded-data visualization, with no hardware action.

## Offline fixed-cadence telemetry reconstruction

[Reconstruct a fixed-cadence grid](docs/offline-telemetry-resampling.md) from
irregular recordings with bounded linear interpolation, exact source brackets,
explicit missing times and connected-segment CSV export for exploration/plots.
Derived points remain estimates; original recording gaps are retained.

## Event-aligned offline run comparison

[Compare around selected observed episodes](docs/offline-event-comparison.md)
when two recording starts do not mark the same run phase. Choose one threshold
episode in each file, inspect signed pre/post-event differences, and export paired
values and gaps with original timestamps and explicit anchor lineage. This is
offline observation analysis; event correspondence and clock drift are not inferred.

## Recorded odometry import

Import ROS 2 Odometry JSONL into the existing route and telemetry tools with explicit pose/twist frames and preserved covariance metadata. See [recorded odometry import](docs/offline-ros2-odometry.md).

## Recorded route frame conversion

Use [`telemetry_frame`](docs/offline-coordinate-frames.md) to express recorded
planar positions in another explicitly declared frame. A fixed yaw and
translation append two target-coordinate columns while preserving all source
columns and timestamps. Keep the JSON recipe/lineage report with the CSV, then
inspect the target channels with the existing trajectory tools.

## Offline paired planar route comparison

Use `telemetry_planar` to compare two explicitly compatible XY recordings with
paired coordinates, Euclidean separation and gap-aware JSON/CSV/SVG exports.
See [the offline planar comparison guide](docs/offline-planar-comparison.md).
Frames, units and alignment are caller declarations, never hardware evidence.

## Recorded sample distributions

Inspect explicit value-bin counts and nearest-rank quantiles for one recorded
channel, including underflow/overflow and exact selected source observations.
The [offline distribution guide](docs/offline-telemetry-distribution.md) includes
a dependency-free Node command, portable SVG and reusable window CSV exports.
Counts describe observed samples, not elapsed-time occupancy or safety.

## Reassemble rotated telemetry captures

[Stitch same-session CSV fragments](docs/offline-telemetry-stitch.md) into one
chronological recording with explicit same-clock and overlap choices. Retain
all source locations and content hashes, inspect recording gaps, and reopen the
whole session or one gap-separated segment in the existing distribution explorer.
The dependency-free Node workflow never shifts clocks or fills missing samples.

## Recorded channel-lag exploration

[Inspect possible channel offsets](docs/offline-telemetry-lag.md) in one regular
recorded window, review real overlap and ambiguous associations, then explicitly
select paired observations for the existing distribution explorer. The Node
workflow preserves both original timestamps in JSON and never infers physical latency,
causality or readiness. It requires no dependency installation or device access.
