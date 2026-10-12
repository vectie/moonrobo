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
