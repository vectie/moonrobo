# Cockpit Audit And Upgrade Record

This document records the Rabbita cockpit audit completed before commit
`eae787f7`, the upgrade delivered by that commit, and the remaining product
gaps. It complements [Interface Plan](INTERFACE_PLAN.md): the interface plan is
the design contract, while this document preserves observed evidence and the
current implementation state.

## Audit Scope

The review covered:

- information architecture and task flow
- familiarity for robot operators and developers
- safety and runtime visibility
- URDF viewport and editor ergonomics
- MoonData visibility and ownership boundaries
- host-to-browser response contracts
- desktop and phone responsiveness
- accessibility basics and interaction target sizing
- automated tests, production build, and browser runtime behavior

The audit date was 2026-07-10. The baseline was the `moondata` branch
immediately before `eae787f7`.

## Baseline Findings

### 1. The cockpit was a subsystem inventory, not an operator workflow

The browser mounted 13 major panels at once. The rendered page exposed roughly
251 buttons and 59 inputs and extended to about 15,000 pixels on desktop and
25,000 pixels on a phone viewport. Robot operation, URDF editing, agent tasks,
runtime diagnostics, readiness proof, receipts, and suite status all competed
for the same page hierarchy.

This made individual controls technically reachable but difficult to find
again. Operators had to remember page position instead of navigating by task.
The interface did not match the familiar mental model of an operational
cockpit: observe, act safely, inspect the robot, manage work, inspect data, and
diagnose failures.

### 2. Safety state was present but not persistent

The safety gate and emergency stop existed, but runtime state, telemetry
freshness, and emergency stop could leave the viewport during long-page
scrolling. A physical robot interface should keep these signals independent of
the selected subsystem and current scroll position.

### 3. The URDF viewport was visually secondary to its metadata

The Three.js renderer worked and loaded the selected URDF/STL assembly, but the
viewport shared its panel with import controls, the full editor, link and joint
rows, collision data, inertials, and world instances. The primary robot signal
was therefore surrounded by a much larger inspection document. Camera fitting
also left excessive empty scene around the robot.

### 4. The URDF editor was capable but difficult to scan

The editor already supported source-preserving edits, model-tree selection,
diagnostics, source diff, history, plugin parameters, and many geometry and
joint fields. Its weakness was not feature coverage; it was progressive
disclosure. Every field family and inspection list appeared in one continuous
surface regardless of the selected node or current edit task.

### 5. MoonData had no first-class operator surface

MoonData already had substantial storage, catalog, validation, repair,
lineage, replay, and query packages. The cockpit and desktop host did not expose
a stable MoonData status projection, so operators could not answer basic
questions such as whether the data root was initialized, validated, blocked,
or carrying repair pressure.

### 6. Host and browser contracts had drifted

Three response-shape mismatches produced visible invalid-response errors:

- live readiness emitted `proof_session_feedback_binding_required_count` and
  `proof_session_feedback_binding_success_count`, while the browser expected
  retired auto-feedback names
- empty task-execution proof responses omitted the optional `latest` field,
  while the browser expected `latest: null`
- empty Robo session execution proof used the same omitted optional field and
  failed for the same reason

The backend state was valid; the UI parser rejected the serialized shape.

### 7. Mobile layout was responsive in width, not in task priority

Panels collapsed to one column, but that preserved the long document rather
than creating a phone workflow. The persistent header initially consumed too
much vertical space, navigation required horizontal scrolling, and viewport
tools could obscure the rendered robot.

### 8. Basic interaction quality needed tightening

The existing visual language was restrained and appropriate for an operations
tool, but many controls were below a 44-pixel touch target and focus treatment
was inconsistent. Repeated panels and badges were familiar, yet the repetition
flattened hierarchy because almost every subsystem had equal visual weight.

### 9. The browser bundle remained heavy

The production Rabbita entry was approximately 2.2 MB minified. Mounting only
the active view reduces DOM and rendering cost, but all view code is still
included in the initial bundle.

### 10. Test results exposed a separate repository fixture problem

The focused MoonData packages passed. The cockpit baseline had one stale
MoonClaw lifecycle expectation. A repository-wide native run also exposed many
host tests sharing fixed `/tmp` directory names and failing during setup. Those
fixture-directory failures are separate from cockpit behavior and remain a
test-infrastructure issue.

## Usability Assessment

Before the upgrade, the cockpit was familiar at the component level but not at
the workflow level.

- **Familiar controls:** status badges, form fields, safety actions, receipts,
  telemetry metrics, model tree, and runtime controls used recognizable
  patterns.
- **Unfamiliar composition:** there was no stable task navigation or clear
  distinction between normal operation and deep diagnostics.
- **Expectation mismatch:** users expect the robot, safety gate, freshness, and
  emergency action to dominate an operator surface. The baseline gave similar
  prominence to every subsystem.
- **Efficiency:** repeated work required long scrolling and visual search.
- **Learnability:** the number of simultaneously visible controls made feature
  discovery possible but made the safe primary path harder to infer.

The main problem was therefore information architecture, not missing styling.

## Upgrade Delivered

Commit `eae787f7` rebuilt the cockpit around task ownership.

### Focused application shell

The shell now exposes five stable views and mounts only the active view:

- `Operate`: digital twin, safety-gated command flow, robot summary,
  telemetry, product progress, and latest receipt
- `Robot`: digital twin, robot identity, URDF import/editor, and bounded model
  inspectors
- `Tasks`: Robo conversation, platform queue, observation flow, MoonClaw
  context, and receipt evidence
- `MoonData`: data-plane readiness, validation pressure, artifact counts, and
  canonical inventory
- `Diagnostics`: runtime lifecycle, platform readiness, Moonstat, telemetry,
  receipts, and proof state

This removes subsystem controls from the normal operating path without
removing their capability.

### Persistent safety and status

The sticky application header keeps these signals visible in every view:

- selected robot label and id
- runtime status
- telemetry freshness
- read-only/control mode
- snapshot refresh
- emergency stop

### Larger robot viewport

The digital twin is now the dominant first-screen surface. Model editing and
long inspection lists moved into the `Robot` workspace. The initial camera fit
was tightened so the robot occupies more of the available canvas while
retaining orbit controls, layer toggles, picking, and transform tools.

### First MoonData cockpit contract

`GET /api/moondata/status` is now a typed, read-only host projection. It
reports:

- root and catalog path
- initialization and readiness
- typed artifact counts
- latest validation state, blockers, and warnings
- open repair count
- at most 40 canonical artifact summaries

The desktop route catalog advertises the endpoint, and the browser does not
scan raw MoonData files or acquire write authority.

### Serialized response fixes

The browser now consumes the current feedback-binding field names and accepts
the host's omitted optional `latest` fields. Fixtures were updated to represent
the serialized host contract instead of a stale browser assumption.

### Responsive and accessibility baseline

The upgrade added:

- 44-pixel command and navigation targets
- explicit keyboard focus treatment
- reduced-motion behavior
- a compact phone header
- five phone tabs that fit without page-level horizontal overflow
- a contained viewport toolbar
- responsive MoonData metrics and artifact rows

## Upgrade Sequence And Ownership

The major upgrade was implemented in this order:

1. **Stabilize serialized contracts.** The Rabbita parsers and fixtures were
   aligned with current host output in
   `ui/rabbita-cockpit/main/commands.mbt`,
   `ui/rabbita-cockpit/main/model.mbt`, and
   `ui/rabbita-cockpit/main/view_wbtest.mbt`.
2. **Expose a bounded MoonData read model.** `src/host_api/moondata_status.mbt`
   introduced the typed projection and `src/host_api/host_api.mbt` exposed it
   at `GET /api/moondata/status`.
3. **Advertise the host capability.** `src/desktop_host/config.mbt` added the
   route to the desktop service catalog with route-catalog coverage.
4. **Create task-level navigation.** `ui/rabbita-cockpit/main/shell.mbt`
   introduced the persistent header, five views, global safety/status, and
   active-view mounting.
5. **Separate operation from model inspection.**
   `ui/rabbita-cockpit/main/view.mbt` reduced the primary viewport to the scene
   and summary, then moved URDF import, editing, and detailed inspectors into
   the `Robot` workspace.
6. **Make desktop and phone layouts operational.**
   `ui/rabbita-cockpit/styles.css` added the new grid, touch targets, focus
   treatment, mobile compaction, and reduced-motion rules.
   `ui/rabbita-cockpit/viewer/urdf-stl-viewer.js` tightened initial camera
   fitting.
7. **Verify and publish.** Focused MoonBit suites, production build, desktop
   and phone browser checks, WebGL draw evidence, commit, and branch push were
   completed before the upgrade was reported shipped.

The implementation commit is `eae787f7` (`feat: rebuild cockpit around
MoonData workflows`).

## Validation Evidence

The upgraded build was verified with:

- 72 of 72 Rabbita cockpit tests passing
- 36 of 36 MoonData API tests passing
- the MoonData host projection test passing
- 6 of 6 desktop host route-catalog tests passing
- native checks for `src/host_api` and `src/desktop_host` passing
- a successful production Vite build
- desktop browser validation at 1280 by 720
- phone browser validation at 390 by 844
- zero page-level horizontal overflow at both checked widths
- zero browser console warnings or errors during the checked workflows
- a live WebGL canvas with nonzero draw calls and triangle count

At 1280 by 720, the main canvas measured approximately 1204 by 602 pixels. At
390 by 844, it measured approximately 326 by 456 pixels. The phone header was
reduced from 310 pixels during the first responsive pass to 208 pixels after
compaction.

## Remaining Gaps

### P0: complete MoonData ownership for the active robot model

The example workspace currently has no initialized
`moondata/indexes/catalog.json`. The new view correctly reports
`not-initialized`; it does not invent sample records. The active example URDF
is still resolved through the existing RoboBook-selected runtime path. The
unique-source design is complete only when the URDF and related mesh/material
payloads are imported into MoonData, the RoboBook stores the selected MoonData
model ref, and runtime/viewport consumers resolve that ref without a second
durable model owner.

### P0: add end-to-end serialized contract tests

Parser unit tests now cover the corrected shapes, but the strongest protection
is to feed actual `src/host_api` serialized responses into the Rabbita parser
contract. This should cover empty and populated execution proof, live
readiness, Robo session, and MoonData status responses.

### P1: add progressive disclosure inside the Robot workspace

The top-level information architecture is fixed, but the URDF editor remains
dense. The next editor pass should show fields by selected node and edit kind,
add search/filter for the model tree, and separate validation, source diff, and
history into focused subviews without hiding save-state or blocking issues.

### P1: expand MoonData from status to bounded workflows

The first view is intentionally read-only. Operators still need scoped routes
and UI for:

- robot-model import and activation
- source/capture registration
- validation findings
- repair-plan review and receipt state
- dataset/version lineage
- replay and annotation review
- export readiness and handoff dossiers

These workflows must remain typed projections and explicit commands, not raw
filesystem browsing.

### P1: make replay and receipts a connected workflow

The latest receipt is visible, but there is no first-class replay timeline that
joins intent, safety verdict, dispatch, telemetry feedback, MoonData frame or
episode refs, and annotation state. Receipts should open this evidence surface
directly.

### P1: complete semantic accessibility

Keyboard focus and target sizes are improved, but the view navigation still
uses styled buttons without full tab semantics. Add selected-state attributes,
landmark labels, live-region handling for asynchronous status, and automated
keyboard/screen-reader checks.

### P1: repair native test isolation

Host tests should use unique temporary roots and idempotent setup/cleanup. The
current fixed `/tmp` names make full-suite results sensitive to stale state and
concurrent execution.

### P2: reduce initial browser bundle cost

The active-view shell reduces DOM cost but does not split JavaScript. The
`Robot` editor and diagnostics code are strong candidates for lazy loading if
Rabbita and the build pipeline can preserve typed boundaries across chunks.

### P2: make views linkable and restorable

The active view is currently in application memory. URL-backed navigation or
another explicit restoration contract would make diagnostics, MoonData, and
Robot selections linkable without making browser state authoritative.

### P2: validate repeated live operation

The browser was verified against the local host and mock/current evidence. A
hardware-facing release still needs repeated runtime startup, validation,
command gating, emergency-stop, reconnect, stale telemetry, and feedback-proof
exercises with persisted receipts.

## Next Acceptance Gate

The next major UI/data-plane milestone should not be considered complete until:

1. the example robot model is a resolvable MoonData robot-model artifact
2. RoboBook selects that artifact by MoonData id or ref
3. the viewport renders only from the selected MoonData model projection
4. actual host JSON is contract-tested against the browser parsers
5. model import, validation findings, and repair pressure are operable through
   bounded routes
6. the full native test suite uses isolated temporary roots
