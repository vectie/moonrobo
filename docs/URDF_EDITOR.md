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
  limits, visuals, mesh readiness, model diagnostics, and telemetry mapping.
- Rabbita renders the selected model through a Three.js STL viewport.
- Extracted URDF folders can be imported into RoboBook model imports.
- The cockpit can render the local Noetix E1 assembly package with STL meshes.
- `src/urdf_editor` now has a source-preserving URDF document model with
  stable robot, link, joint, visual, collision, inertial, and material node
  identities.
- The editor document projects inertial mass/inertia and robot-level or
  visual-scoped material color/texture fields into selectable inspector rows.
- Source patches can update joint origins, joint limits, visual origins,
  visual geometry, collision origins, collision geometry, inertial mass/inertia
  blocks, material color/texture fields, and link/joint names without rewriting
  unrelated XML.
- The host exposes active-document and edit APIs that write model-edit receipts
  when edits are saved.
- Saved edits write before-source and after-source snapshots, compact digests,
  and a diff summary under `runs/model-edits`.
- The host and Rabbita editor can revert the latest saved URDF edit for the
  active RoboBook model.
- Rabbita has an editor lane with a model tree, selection inspector, typed edit
  preview, save, and latest-revert controls.
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
- Editor sessions compute a compact source diff and past/present/future history
  projection in `src/urdf_editor`. Rabbita renders the current diff hunk and
  history rows so unsaved source changes can be reviewed before Save Session.
- `src/urdf_editor` exposes viewport selection targets that map runtime links,
  joints, visuals, and collisions to stable editor node IDs. Rabbita viewport
  link, joint, visual, and world visual-instance rows now select the same editor
  session and hydrate the edit form from that selected node.
- The Three.js STL viewer tags each rendered visual mesh with the same editor
  node ID and emits `moonrobo:urdf-editor-select` when a mesh is clicked.
  Rabbita registers an idempotent mesh-pick bridge on startup, consumes that
  event, selects the matching editor node, and hydrates the edit form through
  the same session path as viewport rows.

Not yet implemented:

- source patch commands for transmission, mimic, dynamics, safety-controller,
  gazebo, plugin, comments, and unknown vendor tags
- full structured preservation for transmission, mimic, dynamics,
  safety-controller, gazebo, plugin, comment, and unknown-tag extension nodes
- richer visual feedback for direct mesh picks, including selected mesh
  highlighting and camera focus
- transform gizmos that commit origin edits back to the URDF source
- a full saved-edit history browser and multi-hunk source diff panel

The current `src/urdf` parser is intentionally a compact projection for
rendering and diagnostics. A full editor needs a richer source-preserving layer
above or beside it.

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
- separate visibility and overlay controls

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

The first editor can preserve these as structured or opaque XML nodes until
Moonrobo has a strong reason to edit them directly:

- transmissions
- gazebo tags
- plugins
- comments
- unknown vendor tags
- formatting around untouched nodes

Preservation is mandatory. Rich editing can come later.

## Editor Surfaces

Rabbita should grow a dedicated URDF editor lane inside the cockpit:

- model tree: robot, links, joints, visuals, collisions, inertials, materials
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
POST /api/robobook/urdf/edit
POST /api/robobook/urdf/revert
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
update-visual-origin
update-visual-geometry
update-material
update-collision-origin
update-collision-geometry
update-inertial
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

Blocking diagnostics:

- malformed XML
- duplicate link names
- duplicate joint names
- missing parent or child links
- no root link
- disconnected topology
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
- extension tags preserved but not editable

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
- Preserve original XML for unknown nodes and comments.
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

- Map rendered meshes back to URDF visual/collision node ids.
- Click viewport objects to select inspector rows.
- Add transform controls for origin edits.
- Commit transforms through typed patch commands.

Exit: an operator can move a visual or collision origin in 3D and save it to
the URDF.

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

That slice proves the editor architecture without confusing it with physical
execution.
