# URDF Editor Plan

Moonrobo needs two related but separate lanes:

- the robot execution loop, where MoonClaw chooses bounded robot work and
  Moonrobo gates bridge execution through RoboBook evidence, readiness,
  safety, and receipts
- the URDF editor lane, where operators and agents inspect and update the
  selected robot model artifact, then refresh the digital twin before any
  physical task relies on that model

The editor lane should not bypass the execution loop. It updates model evidence
inside RoboBook and produces validation artifacts that MoonClaw, Moontown, and
MoonBook can use later.

## Current State

Moonrobo currently has a real URDF-backed viewport, not a full editor.

Implemented:

- RoboBook `model.primary` selects the active URDF artifact.
- The host reads the selected URDF and projects links, joints, origins, axes,
  limits, visuals, collisions, inertials, mesh readiness, model diagnostics,
  and telemetry mapping.
- Rabbita renders the selected model through a Three.js STL viewport.
- Extracted URDF folders can be imported into RoboBook model imports.
- The cockpit can render the local Noetix E1 assembly package with STL meshes.
- `src/urdf_editor` now has a source-preserving URDF document model with
  stable robot, link, joint, visual, collision, inertial, and material node
  identities.
- The editor document projects inertial mass/inertia and robot-level or
  visual-scoped material color/texture fields into selectable inspector rows.
- The editor document projects comments, transmissions, gazebo blocks, plugins,
  and unknown vendor tags as preserved extension nodes with stable editor IDs,
  parent ownership, source spans, tree rows, and guarded inspector commands.
- Non-comment extension nodes also expose a typed attribute edit command for
  their opening tag, so common gazebo, plugin, transmission, and vendor-tag
  attributes can be added, updated, or removed without rewriting the extension
  body.
- Transmission extension nodes expose a typed edit command for the common
  control-facing fields: transmission type, referenced joint name, actuator
  name, and mechanical reduction. The command preserves the surrounding
  transmission source and can expand self-closing transmission tags into normal
  blocks when child fields are added.
- Gazebo and standalone plugin extension nodes expose a typed plugin edit
  command for plugin `name`, `filename`, and direct child parameters. The
  command preserves the surrounding gazebo/plugin XML, can add, update, or
  remove one or more parameters, and expands self-closing plugin tags when a
  parameter is added.
- The editor document validates source structure with blocking diagnostics for
  duplicate names, missing or unknown joint links, bad limit ordering, invalid
  mimic targets, missing root graphs, disconnected cycles, and missing geometry,
  plus advisory diagnostics for missing inertials, visual/collision mismatches,
  inertial mass quality, fixed/continuous joint authoring mistakes, and
  preserved extension tags.
- Source patches can update joint origins, joint axes, joint limits, joint
  dynamics, joint mimic relationships, joint calibration fields, joint
  safety-controller fields, visual origins, visual geometry, collision origins,
  collision geometry, inertial mass/inertia blocks, material color/texture
  fields, preserved extension source, transmission fields, gazebo/plugin fields,
  link/joint names, new link/joint topology blocks, and visual/collision block
  creation or removal without rewriting unrelated XML.
- The host exposes active-document and edit APIs that write model-edit receipts
  when edits are saved.
- The host blocks saved edits and Save Session writes when the edited URDF has
  blocking diagnostics. Preview remains available so operators and MoonClaw can
  inspect and repair the proposed source before it becomes RoboBook evidence.
- Rabbita mirrors that boundary in the editor lane by showing blocking and
  advisory validation counts for the active session source and disabling Save
  Session while a dirty session has blocking diagnostics.
- Saved edits write before-source and after-source snapshots, compact digests,
  and a diff summary under `runs/model-edits`.
- The host exposes a saved edit-history projection for the active URDF model.
  It lists durable `runs/model-edits/*.json` receipts latest-first, filters out
  `latest.json` and `latest-revert.json` pointer files, and returns an empty
  history for first-run RoboBooks instead of rejecting the editor lane.
- The host and Rabbita editor can revert the latest saved URDF edit for the
  active RoboBook model.
- Rabbita has an editor lane with a model tree, selection inspector, typed edit
  preview, save, and latest-revert controls.
- The selection inspector renders supported source edit commands as component
  action buttons, and editable field command chips can switch the active typed
  command before Preview, Save, or Save Session.
- Gazebo/plugin parameter editing in Rabbita uses a repeated direct-parameter
  form, so operators can batch common plugin child-tag updates through one
  source-preserving preview or save request.
- `src/urdf_editor` exposes a compact Gazebo plugin schema catalog for common
  ROS control, differential-drive, and joint-state publisher plugins. Rabbita
  can apply those presets to fill plugin `name`, `filename`, and known direct
  parameters while preserving matching values already present in the form.
- `src/urdf_editor` has a standalone editor-session core for selection,
  persisted baseline source, dirty state, present source, bounded past/future
  snapshots, no-op filtering, commit, undo, redo, and rename-aware selection
  retargeting. Runtime document and edit responses expose that session state so
  viewport picking, transform handles, source diff previews, and richer history
  controls can share one boundary.
- Rabbita keeps the active URDF editor session in the cockpit model. Preview
  edits now apply to the current session instead of reloading from disk, tree
  selection updates the session, Undo/Redo are local session operations, and
  Save Session persists the current preview source through the host API without
  reapplying the form command.
- Editor sessions compute a source diff and past/present/future history
  projection in `src/urdf_editor`. The diff engine now reports separated
  line-oriented hunks with context, and Rabbita renders a review surface with
  hunk count, byte/line deltas, numbered before/after hunk cards, and
  baseline-vs-changed history rows so unsaved source changes can be reviewed
  before Save Session.
- Rabbita renders saved model-edit receipts in the URDF editor lane. Operators
  can refresh the persisted history, see command/target/status rows, inspect
  diff summaries and source snapshot paths, and the panel refreshes after saved
  edits, session saves, imports, startup, and latest-revert operations.
- Saved history rows can restore either the before-source or after-source
  snapshot for a chosen receipt. The restore API only accepts receipt IDs from
  the active model history, writes the restored URDF through the host boundary,
  and records the restore as a new model-edit receipt.
- Saved history rows can load a receipt detail comparison. The host compares
  the receipt before/after snapshots, returns parsed before/after documents and
  hunked source diff data, and Rabbita renders that diff before an operator
  chooses whether to restore either side.
- Saved history rows can also compare the current active URDF source against a
  receipt's before or after snapshot, so restore decisions can be reviewed
  against the live model instead of only within the original receipt pair.
- Receipt comparison responses include the exact left/right source text for
  the selected compare mode, and Rabbita renders those sources side-by-side
  below the hunk review so operators can inspect the full artifact before
  restoring either side.
- `src/urdf_editor` exposes viewport selection targets that map runtime links,
  joints, visuals, collisions, and inertials to stable editor node IDs. Rabbita
  viewport link, joint, visual, collision, inertial, and world visual-instance
  rows now select the same editor session and hydrate the edit form from that
  selected node.
- The Three.js STL viewer tags each rendered visual mesh with the same editor
  node ID and emits `moonrobo:urdf-editor-select` when a mesh is clicked.
  Rabbita registers an idempotent mesh-pick bridge on startup, consumes that
  event, selects the matching editor node, and hydrates the edit form through
  the same session path as viewport rows.
- The Three.js viewer also renders collision geometry as a transparent
  wireframe overlay. Collision meshes and primitives are tagged with
  `collision:<link>:<index>` editor node IDs, can be selected from the viewport,
  and preview collision-origin drags before those drags are normalized into
  `update-collision-origin` session edits.
- The mesh viewer has explicit Visuals and Collisions layer controls. The
  controls persist in browser storage, update rendered visibility for
  progressively loaded meshes, expose their state through viewer datasets, and
  filter viewport picking through the visible layers so collision inspection
  does not fight normal visual selection.
- The mesh viewer listens for canonical editor selection changes and highlights
  the matching rendered visual or collision overlay while moving the orbit
  target to that object bounds. Direct mesh picks, viewport rows, and tree
  selections therefore share the same visible selected body part.
- The mesh viewer has a compact transform-control helper for selected visual,
  collision, inertial, link, and joint origins. It attaches local Move/Rotate
  controls to the selected origin, previews rendered visual-origin changes in
  the viewport, and emits structured `moonrobo:urdf-editor-transform-draft` and
  `moonrobo:urdf-editor-transform-commit` browser events for the Rabbita edit
  lane to consume.
- Rabbita registers a transform-commit bridge on startup. Editable visual and
  joint-origin commits from the viewport are normalized into existing
  `update-visual-origin` or `update-joint-origin` editor requests. Editable
  collision and inertial-origin commits are normalized into
  `update-collision-origin` and `update-inertial` editor requests. All of these
  flow through the session preview path with `save=false`, so gizmo edits become
  source-preserving URDF session changes before an explicit Save Session.
- The viewport transform toolbar now separates preview from commit. It shows a
  live local `xyz`/`rpy` readout, lets operators Move or Rotate the selected
  origin, and requires an explicit Apply before the transform commit is sent to
  the Rabbita edit session. Revert drops an uncommitted viewport preview back
  to the selected model pose.

Not yet implemented:

- richer schema-aware extension editing beyond common transmission fields,
  plugin name/filename, and direct plugin parameters, such as typed controls
  for schema value kinds and package-specific validation

The current `src/urdf` parser is intentionally a compact projection for
rendering and diagnostics. The full editor source of truth remains the richer
source-preserving `src/urdf_editor` layer.

## Reference Pattern

The sibling `../olu` codebase is a useful reference for editor architecture:

- canonical robot data is kept separate from source text
- mutations flow through structured actions
- editable source patching is separate from viewport state
- import/export, selection, undo/redo, and 3D picking are first-class surfaces
- visual editing uses viewport interaction, but persistence goes through source
  patch commands
- history is modeled as past/present/future snapshots, while selection is kept
  as its own small state surface instead of being embedded in renderer code

Moonrobo should borrow the pattern, not the product boundary. Moonrobo remains
the physical-world agent interface, RoboBook evidence owner, Rabbita cockpit,
Lepus desktop shell, and MoonClaw/Moontown gateway surface.

## Target Architecture

```text
URDF files and mesh assets
  -> source-preserving UrdfDocument
  -> UrdfEditorSession selection/history state
  -> editable robot model projection
  -> Rabbita URDF editor panels
  -> Three.js viewport selection and transform handles
  -> typed edit commands
  -> source patches
  -> validation projection
  -> RoboBook model evidence
  -> MoonBook memory summary
  -> MoonClaw and Moontown context
```

The editor should produce three durable outputs:

- updated URDF source and related model assets
- validation evidence for topology, mesh readiness, limits, and telemetry
  mapping
- model-edit receipts that summarize what changed and why

## Editable Components

The editor should expose the URDF as structured components, not as loose text
fields only.

### Robot

- robot name
- active source path
- package roots and mesh resolution rules
- format and import diagnostics

### Links

- link name
- parent/child topology view
- visibility in the editor
- visual, collision, inertial, and metadata sections

### Joints

- joint name
- type: fixed, revolute, continuous, prismatic, floating, planar
- parent link and child link
- origin `xyz` and `rpy`
- axis
- limits: lower, upper, effort, velocity
- dynamics: damping and friction
- mimic
- calibration
- safety controller

### Visual Geometry

- owning link
- geometry kind: mesh, box, sphere, cylinder
- mesh filename and resolved asset status
- mesh scale
- primitive dimensions
- origin `xyz` and `rpy`
- material reference or inline material

### Collision Geometry

- owning link
- geometry kind
- mesh filename and resolved asset status
- scale or primitive dimensions
- origin `xyz` and `rpy`
- separate visibility and overlay controls, implemented in the viewport for
  visual and collision layers

### Inertial

- mass
- center-of-mass origin
- inertia matrix: `ixx`, `ixy`, `ixz`, `iyy`, `iyz`, `izz`
- validation for missing or suspicious values

### Materials

- named material declarations
- inline visual material references
- color and texture fields
- unresolved texture diagnostics

### Preserved Extensions

The first editor preserves these as selectable XML nodes. Transmissions expose
common typed fields, non-comment extensions expose guarded opening-tag attribute
edits, gazebo/plugin nodes expose common plugin fields, and every preserved
extension can still be updated through guarded raw source when a typed form is
not available:

- transmissions
- gazebo tags
- plugins
- comments
- unknown vendor tags
- formatting around untouched nodes

Preservation is mandatory. Richer plugin-specific editing can come later, but
the operator can already see which component owns each preserved extension and
update supported extension fields without rewriting unrelated source.

## Editor Surfaces

Rabbita should grow a dedicated URDF editor lane inside the cockpit:

- model tree: robot, links, joints, visuals, collisions, inertials, materials,
  extension nodes
- inspector panel for the selected component
- 3D viewport picking for meshes, links, and joints
- transform controls for editable origins
- source preview and diff panel
- validation panel with blocking and advisory diagnostics
- save/apply/revert controls
- undo/redo for local edit sessions

The cockpit can keep the execution loop visible, but execution controls and
model editing controls should not be mixed in one panel.

## API Boundary

The host should expose typed editor APIs instead of letting the browser write
files directly.

Implemented routes:

```text
GET  /api/robobook/urdf/document
GET  /api/robobook/urdf/history
POST /api/robobook/urdf/edit
POST /api/robobook/urdf/revert
POST /api/robobook/urdf/restore
POST /api/robobook/urdf/compare
```

Future routes can split validate and save flows once the edit session grows
beyond single-command preview and save.

Edit commands should be explicit:

```text
save-session
rename-link
rename-joint
update-joint-origin
update-joint-axis
update-joint-limit
update-joint-dynamics
update-joint-mimic
update-joint-calibration
update-joint-safety-controller
update-visual-origin
update-visual-geometry
update-material
update-collision-origin
update-collision-geometry
update-inertial
update-extension-raw
update-extension-attribute
update-transmission
update-gazebo-plugin
add-link
add-joint
add-visual
add-collision
remove-visual
remove-collision
```

Every save should produce a model-edit receipt under RoboBook runs or model
evidence, including:

- edit id
- source path
- selected robot id
- command list
- validation summary
- before/after digest
- before/after source snapshot paths
- compact diff summary
- author route: operator, MoonClaw, import, or repair tool

## Validation Rules

The editor should validate before save and after save.

Current behavior: preview requests can return diagnostics without writing
source. Saved edits and Save Session requests are rejected before file writes or
receipt creation when the edited document contains blocking diagnostics.
Rabbita also marks the active session save gate as blocked and disables Save
Session for dirty sessions with blocking diagnostics.

Blocking diagnostics:

- malformed XML
- duplicate link names
- duplicate joint names
- missing parent or child links
- no root link
- disconnected root graph or cyclic topology with no root
- unresolved required mesh assets
- invalid numeric fields
- joint limit lower greater than upper
- source patch cannot be applied cleanly

Advisory diagnostics:

- missing inertial
- visual without collision
- collision without visual
- fixed joint with axis or limits
- continuous joint with lower or upper limit
- suspicious mass or inertia
- telemetry joint names not mapped to URDF joints
- extension tags preserved with limited typed or raw-source editing

## Relationship To The Execution Loop

The execution loop remains:

```text
MoonClaw robot routine
  -> Moonrobo gateway server
  -> RoboBook identity, readiness, calibration, and safety gates
  -> bridge execution or recovery blocker
  -> RoboBook evidence
  -> MoonBook memory
  -> Moontown resident state
```

The URDF editor lane feeds that loop but does not execute robot actions:

```text
URDF edit
  -> model validation
  -> RoboBook model evidence
  -> MoonBook model-memory summary
  -> MoonClaw context
  -> future task planning and calibration
```

This keeps the agentic decision boundary clean. MoonClaw can request or propose
model edits, but Moonrobo owns the editor API, source patching, validation, and
evidence.

## Milestones

### Milestone 1: Source-Preserving Document

- Add `UrdfDocument` with stable node ids.
- Preserve original XML for comments and extension nodes as selectable opaque
  components.
- Parse robot, links, joints, visuals, collisions, inertials, and materials.
- Keep the existing viewport projection as a read-only consumer.

Exit: load the E1 URDF and re-emit it without losing preserved sections.

### Milestone 2: Typed Patch Commands

- Add edit command DTOs.
- Implement rename and numeric-field patches.
- Add validation before applying patches.
- Add tests for no-op, invalid, and successful patches.

Exit: update joint limits and visual origins without rewriting unrelated XML.

### Milestone 3: Host Editor API

- Add document, edit, and latest-revert routes.
- Persist model-edit receipts with before/after source snapshots.
- Keep all file writes scoped to the selected RoboBook root.

Exit: a scripted edit can update the selected URDF and refresh cockpit
projection.

### Milestone 4: Rabbita Inspector

- Add model tree and component inspector.
- Support link, joint, visual, collision, inertial, and material selection.
- Show validation diagnostics, save evidence, and latest-revert status.

Exit: an operator can select a component and edit simple scalar fields.

### Milestone 5: Viewport Picking And Transforms

- Map rendered meshes back to URDF visual/collision node ids and viewport rows
  back to visual, collision, inertial, link, and joint node ids.
- Click viewport objects to select inspector rows.
- Add transform controls for visual, collision, inertial, link, and joint
  origin edits.
- Commit transforms through typed patch commands.

Exit: an operator can move visual, collision, inertial, and joint origins in 3D
and save them to the URDF.

### Milestone 6: Agent-Assisted Model Repair

- Let MoonClaw propose bounded model-edit commands.
- Require validation and operator approval for structural changes.
- Summarize edit receipts to MoonBook memory.

Exit: MoonClaw can help repair model issues without bypassing Moonrobo's
source, validation, or evidence boundary.

## Non-Goals For The First Editor

- physics simulation authoring
- arbitrary vendor SDK control
- low-level motor control
- complete CAD editing
- learned policy generation
- lossy whole-file XML rewriting
- hidden browser-side file writes

## First Implementation Slice

The first practical slice should be small:

1. add `UrdfDocument` and parse enough node identity to preserve source
2. implement `update-joint-limit`
3. implement `update-visual-origin`
4. add host validation and save receipts
5. add a Rabbita inspector for joints and visuals
6. reload the current Three.js viewport after each saved edit
7. record before/after source snapshots and revert the latest saved edit
8. project inertials and materials as selectable editor components
9. implement `update-inertial` preview/save for mass and inertia matrix fields
10. project collision and inertial origins into the viewport contract
11. attach Move/Rotate controls to visual, collision, inertial, and joint
    origins and preview those edits through the Rabbita session path
12. render collision meshes and primitives as selectable viewport overlays

That slice proves the editor architecture without confusing it with physical
execution.
