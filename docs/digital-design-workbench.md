# Digital design workbench

Open **Design a digital robot** in the cockpit. Start an excavation-haul draft,
edit the task loop, mechanisms, validation scenarios and minimum/maximum speed,
then save a named revision. Build that revision and inspect the generated source
summary before downloading its MoonMoon simulation-input package.

## Supported scope

- One bounded class: `excavation-haul-rover`
- 4–24 task-loop statements, 3–12 mechanisms with unique lowercase IDs, and
  3–12 validation scenarios with unique IDs and expected outcomes
- Speed limits in m/s: `0 < minimum <= maximum <= 0.5`
- The existing design builder generates a profile, box-link URDF with generic
  revolute joints, simulation-only bridge, safety policy and receipts
- Validation proves artifact consistency. It does **not** execute the declared
  validation scenarios or establish calibrated dynamics, manufacturing geometry,
  terrain suitability or physical readiness

The workbench never dispatches commands, calls providers, invokes a hardware SDK,
changes the active RoboBook, or overwrites a physical profile. It writes only
beneath the selected root's `.moonsuite/products/moonrobo/design-workbench` directory.

## Revision and interruption behavior

A design ID plus revision identifies an immutable draft. An exact repeated save
returns the existing draft, preserving its timestamp. To change a draft, choose a
new revision (for example, `r2`) and save. Builds require the saved source digest.
Repeated successful builds return the same frozen package without regenerating
receipts. Old revisions remain byte-identical.

Builds reserve their own directory atomically and write the package commit marker
last. An interrupted build, incomplete manifest, missing source or changed source
is **unconfirmed**. Re-opening is read-only; it neither repairs nor reruns a build.
Preserve that revision and use a new revision after review. Failed requests keep
the editable fields and require an explicit re-open before another mutation.
Closing the dialog suppresses stale callbacks and delayed downloads.

The panel preserves editable fields while closed. After a page reload, choose
**Refresh saved designs** to discover saved work without remembering its ID.
Exact-ID **Re-open saved revision** remains available for entries beyond the
catalogue bound. Re-opening, replacing with the template, or forking asks before
replacing unsaved fields. Browsing and comparing never replace those fields.

## Saved library, comparison and fork

1. **Refresh saved designs** reads at most 40 revision summaries, considering at
   most 40 design directories and 40 revision entries per design, in sorted name
   order. A visible truncation warning means more work may exist. Directory name
   enumeration occurs before this bound; this is not a streaming filesystem index.
2. Choose **Revision A** and **Revision B**, then **Inspect and compare**. Each
   selection is re-read through the existing revision inspector and verified
   against its catalogue digest. Task-loop positions, mechanisms keyed by ID,
   validation scenarios keyed by ID, and minimum/maximum speed in m/s show
   separate A/B values and changed/same labels. This compares declared concepts,
   never simulation performance or physical readiness. Selecting the same saved
   revision twice is allowed and requires only one inspection per comparison.
3. Choose inspected A or B and a new revision name, then **Fork into editable
   fields**. The source is re-read and verified again. Forking keeps the design ID,
   copies the declared concept fields into the ordinary editor, and sets the new
   revision name. It writes nothing. Review, **Save draft revision**, **Build** and
   **Download** remain separate explicit actions. The normal immutable save route
   rejects existing revisions even if the catalogue was truncated or became stale.

Refresh retains still-present selected IDs but clears old comparison details;
inspection is required again. Changing a selection, closing the panel or Escape
suppresses late comparison/fork callbacks. Closing a read-only request never
marks the editable draft's save outcome uncertain. A reload starts with empty
editor fields and requires a fresh catalogue read.

Missing drafts, corrupt/unreadable drafts, invalid names and unreadable design
directories are labeled and non-selectable. Unconfirmed/partial build evidence is
explicit: its verified draft may be compared or forked, but its old build is never
repaired, retried or exported. A failed refresh clears actionable comparison data
and reports that the library is unavailable; it does not claim the library is empty.
All stored names and concept text render as text, not HTML. The existing local
workbench filesystem and revision inspector remain the trust boundary; this is
not a sandbox for hostile filesystem trees or a byte-size-bounded filesystem scan.
Sources with embedded newlines or delimiters that cannot be copied losslessly
into the line-based editor can still be compared; opening/forking them fails
without replacing fields or changing saved evidence.

## Portable concept intake from another workspace

An integration engineer can bring an exported
`moonrobo.simulation-input-envelope.v1` JSON file from another workspace into a
new local concept. This is separate from selective reuse of items in the local
saved-design catalogue: intake copies the complete supported design declarations.

1. Under **Bring a concept from another workspace**, choose a local JSON file of
   at most 2 MiB, then **Inspect local concept file**. This reads a snapshot of the
   file in the browser, with no upload, host request, save or editor replacement.
   Inspection verifies the package digest, all eight exact source digests, source
   references and robot binding through the existing package inspector. It then
   verifies that the embedded design's ID/revision matches the package and that
   its contract, digital-only authority and excavation-haul-rover class are supported.
2. Inspect the visible source ID, revision, exact design/package digests, all
   eight verified source references/digests and all editable design fields. These
   hashes establish internal byte consistency, not source authenticity or author
   trust. Imported profiles, URDF and receipts are
   inspected as package contents only; none is installed or adopted as local
   build, validation, mission or hardware readiness.
3. Choose a **New local design ID** and **New local revision**, both lowercase
   slugs of 1–64 characters. Their pair must differ from the source pair. Either a
   different ID or a different revision can satisfy that condition. Known existing
   or unconfirmed local revisions reject. An unrefreshed or truncated catalogue
   cannot establish availability; the existing immutable native save remains the
   final conflict check and never silently renames or overwrites a saved revision.
4. **Preview local concept replacement** displays the source identity/digests,
   all eight verified source references/digests, and the complete replacement
   design: new ID/revision, display name, mission authority and class, ordered
   task loop, mechanisms, scenarios and speed limits. Every
   source design field must round-trip through the ordinary editor without loss.
   Unknown fields at any design nesting level, trimmed values, multiline display
   names, unsupported delimiters/newlines and invalid bounds reject rather than
   silently dropping or changing declarations. The check models textarea CR/CRLF
   normalization to LF, so carriage returns cannot silently alter imported text.
   JSON object member ordering and formatting are not design semantics; original file text is not rewritten.
5. **Replace editor with previewed concept** checks the current file selection,
   target identity and exact editable field values again. The ordinary unsaved-work
   confirmation can cancel replacement. Applying replaces all editor fields and
   invalidates the earlier saved/build/export selection and rehearsal state. It
   does not save or build anything. Review or edit the concept, then explicitly
   **Save draft revision**, **Build this digital revision** and **Download** through
   the existing native workflow. Only a fresh local build supplies local validation.

Changing the selected file clears its inspection and preview. Editing the local
identity or current editor, refreshing the catalogue, closing or Escape clears
replacement actionability. Delayed file reads cannot populate a newer selection;
repeat clicks are single-flight. Invalid, unreadable, empty or oversized files
clear prior import actionability while keeping editor fields. Apply consumes its
preview, including cancellation or failure, so repeating it requires a new preview.
A reload starts with no imported state. All imported names/declarations render as
text, never HTML. Source provenance is session-only and is not added as a new
persisted native schema.

Qualification: 15 new Node function/production-controller tests cover retained
native export input, source tampering, self-consistently rehashed identity errors,
lossy and unknown fields, local file controls, guarded replacement, new identity,
known conflicts, interruption, repeat actions and text rendering. The new local
save response is explicitly synthetic. No fresh native intake/save/build/export
round-trip or graphical browser run is claimed. Native contracts, SDKs, bridges,
providers, infrastructure and physical authority are unchanged.

## Selective concept reuse

After **Inspect and compare**, choose inspected A or B under **Reuse selected
concept items**. To inspect one saved revision, select it in both comparison slots.
Choose mechanisms, scenarios or both groups, then explicitly select individual
items (Ctrl/Command for multiple choices). Start or fill a valid current editor
before previewing; reuse adds declarations to that current design.

1. **Preview selected reuse** shows the inspected source identity/digest, selected
   IDs and the complete combined native design fields. It writes nothing and leaves
   the editor intact. The target's ID, revision, name, task loop, speed limits and
   existing items remain its own. No other source fields are copied.
2. Existing IDs are conflicts, including identical declarations. There is no
   implicit overwrite, renaming or deduplication. Deselect the conflict or explicitly
   edit the current ID and preview again. More than 12 mechanisms or 12 scenarios,
   absent/duplicate choices, no selection, invalid current fields, and selected
   text that cannot round-trip through the line-based editor all reject atomically.
3. **Apply preview to editable fields** re-opens the saved source through the
   existing inspector, verifies exact draft text and the catalogue digest, and
   checks that target fields, source and selections still match the preview. It
   then fills the current editor with the selected additions. It neither saves nor
   builds. Review and choose a new revision before the normal explicit save/build/
   download actions. Existing immutable revision conflicts still apply.

Changing a target field, source, group, item or comparison invalidates the preview.
Refreshing the library, closing or Escape does too. Repeated or late Apply cannot
replace newer fields, and a failed source re-read keeps them intact. Names and
source declarations are rendered as text. A verified draft whose old build is
unconfirmed may supply declarations; none of that old build's readiness transfers.

This is digital concept composition, not mechanical compatibility analysis,
calibration inheritance, scenario execution or physical authorization. Source
provenance is displayed in the session preview/apply status; no new persisted
lineage schema is added to the native design contract. Once applied, the normal
save/build/export workflow owns the new revision and validation identity. No
hardware adapter, bridge, RoboBook, provider or execution route was changed.

Increment qualification: Node tests exercise the actual controller and selected-item
logic, including original native producer fixtures for source inspection and
existing save/build/export regressions. The new combined-save response in its DOM
journey is explicitly synthetic. A new native build of a combined design and a
real graphical browser were not run for this JavaScript-only change.

## Portable MoonMoon handoff

The new transport wrapper is `moonrobo.simulation-input-envelope.v1`:

- `package_json`: the exact embedded JSON text
- `package_digest`: `sha256:` plus the lowercase SHA256 of its UTF-8 bytes

The inner `moonrobo.simulation-input.v1` is a **robot-input package**, not a complete
MoonMoon mission design or a simulation result. It contains:

- `design_id`, `revision`, `design_ref`, `integration_receipt_ref`
- `robot_artifact`: the existing MoonMoon `RobotArtifactBinding` field names,
  including bare lowercase `robot_json_sha256`, `robot_urdf_sha256` and
  `validation_receipt_sha256` values
- `sources`: the existing MoonMoon study source shape
  `{ artifact_ref, digest, text }`, with exact source text and `sha256:` digests
- `review_required: true`, `physical_execution_allowed: false`, and explicit limits

All eight portable source paths begin `books/<design_id>/<revision>/`:

1. `robot.json`
2. `model/robot.urdf`
3. `bridge/bridge.json`
4. `safety/policy.json`
5. `design/robot-design.json`
6. `design/build-receipt.json`
7. `design/validation-receipt.json`
8. `design/integration-receipt.json`

The integration receipt uses the existing
`moonrobo.digital-model-integration-receipt.v1` contract and
`robot.integrate-digital-model` operation. Its source digest binds the saved
concept, and its references bind the actual produced model and receipts. The
workbench calls the existing builder and validator directly; it does not dispatch
through the generic adapter runtime or grant MoonFlow any physical authority.

MoonMoon must separately supply its site, terrain, mission payload, route,
constraints, verification criteria and calibration evidence. Importing a changed
robot binding establishes a new robot baseline; it must not silently compare as
the previous robot revision.

## Host surface

POST `/api/moonrobo/design-workbench/save` accepts `{ design, recorded_at }`.
POST `.../catalogue` accepts `{}` and returns `moonrobo.design-catalogue.v1`:
`entries`, `limit: 40`, `truncated`, and `physical_execution_allowed: false`.
Entries include identity, name, state, verified source digest, timestamp,
selectability and a diagnostic. The route is read-only and uses `inspect_revision`
(which calls `load_draft`); it does not add a second persistence or build path.
POST `.../open` accepts `{ design_id, revision }`.
POST `.../build` and `.../export` additionally require `expected_digest`.
The save/open/build responses contain `{ draft, state, package,
physical_execution_allowed: false }`. State is `draft`, `built` or `unconfirmed`.
Export returns the exact envelope after checking every persisted source.

## Verification boundary

Native producer and direct host-route tests exercise actual local file outputs;
the JavaScript DOM fixtures consume those outputs and exercise listener/state
behavior. No browser/live UI, hardware, provider, or local-Mac validation is claimed.
