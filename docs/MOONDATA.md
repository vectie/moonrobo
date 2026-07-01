# MoonData Data Plane

MoonData is the Moon suite's robot data plane. It is the unique source of
truth for robot-model bytes, raw robot data, cleaned data, dataset identity,
episode/frame indexes, quality findings, annotations, repair evidence, replay
artifacts, lineage, and export manifests.

MoonData is not a wrapper around another product. It is a standalone
Moon-suite layer with MoonBit-first contracts, local-first storage, and a
small API surface that Moonrobo, RoboBook, MoonClaw, Rabbita, Moontown, and
Moonstat can all read without inventing separate data ledgers.

## Boundary

MoonData owns:

- raw captures from robots, simulators, SDK sidecars, and imports
- robot model artifacts, including URDF, mesh/material refs, model checksums,
  provenance, and derived kinematic metadata
- canonical robot data schemas
- dataset, episode, frame, signal, and media identities
- immutable manifests, checksums, and lineage graphs
- quality findings and quality-run reports
- non-destructive cleaning and transformation runs
- validation-backed repair plans and append-only repair receipts
- manual and agent annotations over episode/frame references
- replay artifacts derived from canonical data
- curated dataset versions and downstream export manifests

MoonData does not own:

- physical command execution
- safety gates, approvals, emergency stop, or bridge dispatch
- robot routine policy or agent planning
- durable conversation, recall, or accepted semantic memory
- robot identity, bridge configuration, safety policy, runtime calibration
  authority, or actuator-specific control parameters

The suite boundary is:

```text
Moonrobo = control plane: safety, runtime, bridge dispatch, receipts
MoonData = data plane: captures, datasets, quality, cleaning, replay, exports
RoboBook = robot memory/evidence projection: identity, policy, refs, summaries
MoonClaw = reasoning plane: planning, diagnosis, route selection
```

The strict rule is:

```text
Raw data never lives in RoboBook.
Cleaned data never lives in MoonClaw.
Physical dispatch never lives in MoonData.
MoonData ids are the canonical references for robot data artifacts.
```

In practice, "unique source of truth" means the durable bytes and manifests for
robot data live in MoonData first: URDF packages, mesh/material assets, raw
capture payloads, canonical frames, replay products, curated dataset versions,
repair evidence, and exports. Runtime, memory, and agent layers may cache
projections or store accepted summaries, but they must be able to resolve the
underlying artifact back to a MoonData id and `DataRef`. A filesystem path,
RoboBook selection, runtime route, or agent note is never the canonical handle
for robot data; the MoonData artifact id and payload refs are.

## Product Role

Moonrobo should continue to produce safety-gated physical evidence: receipts,
runtime health, validation reports, task execution snapshots, and bridge
dispatch records. When those events produce high-volume data such as telemetry
streams, video, depth, audio, command-feedback frames, replay windows, or
training episodes, Moonrobo registers the data in MoonData and stores only the
MoonData references in RoboBook.

RoboBook should remember meaning, not store datasets. A RoboBook memory card or
evidence record can say that dataset `mdata_ds_...`, episode `mdata_ep_...`,
or quality report `mdata_qr_...` is accepted for a task. The underlying files,
frame refs, quality findings, annotations, cleaning config, and export lineage
belong to MoonData.

MoonClaw should never receive raw data blobs in routine context. It should get
bounded MoonData references, summaries, quality status, and explicit slice
routes selected by Moonrobo or Moontown. If it needs to inspect more data, it
calls MoonData through typed read-only APIs.

## Robot Model Ownership

URDF belongs in MoonData when it is used as robot data: simulation setup,
visualization, replay, annotation, kinematic interpretation, dataset
normalization, or training/evaluation context. MoonData stores the URDF as a
payload `DataRef` inside a robot-model manifest, together with mesh/material
refs, byte counts, checksums, robot/model ids, provenance, validation findings,
and derived metadata such as link/joint names. The URDF file is not enough on
its own: any mesh or material URI embedded in the URDF must either be rewritten
to a declared `moondata://` `DataRef` in that robot-model manifest or
validation blocks the model and repair planning routes it as
`declare-or-remove-embedded-asset-ref` work. `package://` and `file://` asset
refs are import-time inputs only, not durable MoonData refs.

Moonrobo and simulator/runtime tools consume robot models by MoonData ref. They
may load the URDF to execute control, render a viewport, or run a simulation,
but they do not become the durable owner of that model file. RoboBook and
MoonBook store refs, selections, receipts, and summaries only. MoonClaw
receives bounded model refs and validated metadata, not arbitrary URDF
filesystem paths.

The boundary is:

```text
MoonData owns robot model artifacts and their verification evidence.
Moonrobo owns runtime use, safety, calibration authority, and dispatch.
Memory and agent layers cite MoonData robot-model refs.
```

## Storage Model

MoonData has its own root, separate from a RoboBook workspace:

```text
moondata/
  sources/
  captures/
  datasets/
    raw/
    canonical/
    curated/
  episodes/
  frames/
  signals/
  robot_models/
  media/
    imports/
    robot_models/
  indexes/
  quality/
  annotations/
  annotation_indexes/
  transforms/
  versions/
  replays/
  exports/
  lineage/
  validations/
  handoffs/
  repairs/
  repair_receipts/
```

Source data is immutable by default. Generated artifacts are written beside the
MoonData root as new manifests, indexes, reports, or derived versions. Cleaning
and export operations must not edit the original source files in place.
`indexes/catalog.json` is the compact discovery surface for the rest of the
suite. It lists MoonData artifact ids, manifest paths, status, and summaries so
Moonrobo, MoonClaw, Moontown, Rabbita, and Moonstat can consume bounded refs
without parsing raw directories or duplicating data identity in RoboBook.
MoonData can rebuild this catalog from manifests stored under its own root, so
the suite-facing catalog is a recoverable index over MoonData-owned artifacts
rather than a second ledger maintained by external tools. Annotation target
indexes are also recoverable projections: MoonData can clear and rewrite them
from annotation set manifests, then rebuild the catalog so review queues do not
own a separate reverse-index ledger.
Before an export or suite handoff, MoonData validation should check that the
catalog is rebuild-equivalent to the stored MoonData manifests, catalog entry
count matches the entries, artifact ids are unique, required fields are
present, every cataloged manifest path is the canonical MoonData-owned path for
that artifact identity, every local manifest path exists, and every local
`moondata://...` input or export output ref still resolves under the selected
MoonData root with the recorded byte count and checksum. `DataRef.uri` values
must be `moondata://` payload refs; external routes such as `file://` and
`sidecar://` may appear as source provenance or import inputs, but not as
durable payload refs. Text payloads use `text-sum-v1` checksums; binary
payloads such as meshes use `bytes-sum-v1` checksums so validation never
depends on lossy text decoding. Local `moondata://` refs must be relative paths
without absolute, empty, backslash, or parent-directory segments, so a manifest
cannot escape the MoonData root.
Local payload `DataRef`s must also live under the owned payload roots:
`media/imports/`, `media/robot_models/`, `media/replays/`, or `exports/`.
Robot-model validation also opens the URDF payload, rejects durable
`package://` or `file://` asset references, and requires every embedded
`moondata://` asset URI to be declared by the same robot-model manifest's URDF,
mesh, or material refs.
When multiple manifests cite the same local `moondata://` payload URI, their
recorded byte counts and checksums must agree; otherwise the root has split
payload identity and validation blocks handoff.
Files under MoonData-owned payload roots such as `media/imports/`,
`media/robot_models/`, `media/replays/`, and export outputs under `exports/`
must also be reachable from cataloged manifest `DataRef`s. Undeclared payload
files are unmanaged data and block validation before handoff.
Conversely, a local `DataRef` must not point at a cataloged manifest, catalog,
index, validation report, or other control-plane JSON file; manifests describe
payloads, they are not payloads.
It should also verify
that manifest references still form a closed MoonData graph: datasets point to
cataloged sources, captures, episodes, and lineage; episodes point to cataloged
frames; versions point to accepted episodes and quality gates; exports point to
cataloged versions, datasets, and quality runs; and ready exports have a
matching replay artifact with generated payload refs covering the exported
version. Referenced episodes, quality runs, versions, signals, replays, and
exports must also stay inside the same dataset graph, so a handoff cannot
silently mix artifacts from another dataset just because their ids exist.
Every annotation set must have exactly one
cataloged target index, and that index must match its source annotation set
targets, labels, reviewer, status, and timestamp, so review queues cannot rely
on a missing, duplicated, or stale projection. Handoff dossiers must also carry
a repair-pressure snapshot that matches the current cataloged repair runs,
repair receipts, and joined repair worklist; if cleanup evidence changes, the
old dossier becomes stale and must be republished from the data plane. The
validation result is itself a MoonData artifact under `validations/`, so a
suite handoff can cite the exact integrity report it used.

RoboBook stores references like:

```json
{
  "moondata_dataset_id": "mdata_ds_noetix_e1_20260701_001",
  "moondata_episode_id": "mdata_ep_noetix_e1_walk_0004",
  "moondata_quality_report_id": "mdata_qr_0004",
  "summary": "Accepted telemetry capture with verified command feedback"
}
```

## Core Contracts

MoonData uses small, serializable contracts as its stable vocabulary.
The core contract also owns `moondata://` URI parsing, relative-path safety,
and payload-root classification, so capture producers, robot-model importers,
and validators use the same durable reference rules.

```text
DataSource
  source id, kind, origin path or route, robot id, bridge id, created time

CaptureSession
  live capture id, source id, robot id, bridge id, receipt ids, time range

DatasetManifest
  dataset id, version, schema id, source refs, checksums, storage refs

EpisodeManifest
  episode id, dataset id, task refs, receipt refs, frame range, timebase

FrameRef
  frame id, episode id, timestamp, data refs, media refs, signal refs

SignalSeries
  series id, field path, units, sample count, timebase, storage ref

RobotModelManifest
  model id, robot id, URDF ref, mesh/material refs, provenance, validation status

QualityFinding
  finding id, rule id, severity, affected refs, evidence, recommendation

QualityRun
  run id, input dataset, rules, findings, summary, created time

TransformRun
  run id, input dataset, transform graph, output dataset, rejected refs

DatasetVersion
  version id, parent ids, accepted episode refs, quality gate, lineage refs

AnnotationSet
  annotation id, target refs, labels, reviewer/source, status, evidence

AnnotationTargetIndex
  index id, annotation id, target refs, label keys/values, reviewer, status

ReplayArtifact
  replay id, source dataset/episode refs, generated files, viewer metadata

ExportManifest
  export id, input version, target format, field mapping, output refs, report

ValidationReport
  report id, root, generated time, status, finding counts, findings

HandoffDossier
  dossier id, source validation, readiness, concrete output refs/evidence, refs, findings

RepairRun
  run id, source validation, action counts, typed repair actions, refs, summary

RepairReceipt
  receipt id, repair run/action, operation, target, status, actor, validation evidence
```

These contracts should derive JSON/debug equality in MoonBit and become the
single vocabulary shared by APIs, CLI tools, and UI projections.

## Initial Package Shape

MoonData starts as package-local MoonBit contracts and a small CLI before it
grows a UI:

```text
src/moondata_core/
  ids.mbt
  source.mbt
  dataset.mbt
  episode.mbt
  frame_ref.mbt
  signal.mbt
  robot_model.mbt
  lineage.mbt
  transform.mbt
  annotation.mbt
  replay.mbt
  export.mbt
  validation.mbt
  handoff.mbt
  repair.mbt

src/moondata_store/
  store.mbt

src/moondata_ingest/
  capture_registration.mbt

src/moondata_capture/
  stored_capture.mbt

src/moondata_quality/
  deterministic.mbt

src/moondata_assess/
  dataset_quality.mbt

src/moondata_transform/
  curation.mbt

src/moondata_curate/
  stored_curation.mbt

src/moondata_annotation/
  review.mbt

src/moondata_review/
  stored_review.mbt

src/moondata_replay/
  stored_replay.mbt

src/moondata_export/
  export_builder.mbt

src/moondata_publish/
  stored_export.mbt

src/moondata_handoff/
  stored_handoff.mbt

src/moondata_pipeline/
  local_file_product.mbt

src/moondata_index/
  index.mbt

src/moondata_import/
  local_files.mbt

src/moondata_robot_model/
  import_model.mbt

src/moondata_normalize/
  raw_to_canonical.mbt

src/moondata_api/
  status.mbt
  context.mbt
  handoff.mbt
  handoffs.mbt
  artifacts.mbt
  sources.mbt
  data_refs.mbt
  payloads.mbt
  repairs.mbt
  captures.mbt
  datasets.mbt
  episodes.mbt
  frames.mbt
  lineage.mbt
  signals.mbt
  robot_models.mbt
  quality.mbt
  versions.mbt
  exports.mbt
  transforms.mbt
  validations.mbt

src/moondata_validate/
  validation.mbt
  repair_validation.mbt

src/moondata_repair/
  repair_plan.mbt
  repair_receipt.mbt

src/moondata_boundaries/
  moondata_boundaries_test.mbt

cmd/moondata/
  init
  register-capture
  import-files
  import-robot-model
  normalize
  quality
  curate
  review
  publish-handoff
  replay
  export
  prepare-files
  rebuild-catalog
  rebuild-annotation-targets
  status
  context
  handoff
  handoffs
  slice
  artifacts
  sources
  data-refs
  payloads
  repair-plan
  publish-repair-plan
  repairs
  repair-work
  record-repair
  repair-receipts
  datasets
  captures
  episodes
  frames
  lineage
  signals
  robot-models
  quality-runs
  versions
  exports
  transforms
  validations
  annotations
  annotation-targets
  replays
  validate
```

The current implementation lands the core, store, ingest, deterministic
quality, stored capture registration, stored dataset assessment,
transform/curation, annotation, stored review materialization, replay, export,
stored curation/versioning, stored replay materialization, stored export
publishing, stored handoff dossiers, local file product pipeline, index,
import, robot-model import, normalize, and API projection packages.
`register-capture` is the durable sidecar/robot capture lane: it writes
source, capture, canonical dataset, episode, and frame manifests, then rebuilds
the catalog and returns a validation report so downstream suite tools can
discover and trust the capture immediately. Source, capture, dataset, episode,
and frame ids must be path-safe before root initialization, because stored
capture registration persists each of them as MoonData manifest files. Frame
payload URIs must already be path-safe `moondata://` refs under owned payload
roots such as `media/imports/`, `media/robot_models/`, `media/replays/`, or
`exports/`. External routes such as `sidecar://` belong in source provenance or
import inputs, not durable frame payload refs. Registration also verifies that
each frame payload exists under the MoonData root and that its declared
`byte_count` and checksum match the bytes on disk before any source, capture,
dataset, episode, or frame manifest is written.
`prepare-files` is the end-to-end local-file product path: it imports raw
payloads, normalizes them into a canonical dataset, evaluates quality, curates
an immutable version, creates review annotation and replay artifacts,
materializes export output, rebuilds the catalog, and returns validation
readiness. `import-files` is the raw intake lane: it copies local
text/JSON/CSV/log payloads into `media/imports/`, writes raw dataset, source,
capture, episode, frame, and signal-series manifests, then rebuilds the
catalog. Import dataset ids must be path-safe before any root or payload write,
because the dataset id becomes part of payload directories and derived
source/capture/episode/frame/signal manifest ids. `signals` lists cataloged
signal series by dataset, episode, field
path, or storage kind, with matched sample counts, storage refs, byte totals,
and checksums, without walking raw storage folders.
`import-robot-model` copies an extracted URDF package into
`media/robot_models/{model-id}`, rewrites simple `package://` mesh references
to MoonData URIs, writes a robot-model manifest with URDF, mesh, material,
link, and joint evidence, rebuilds the catalog, and returns a validation-backed
CLI envelope.
`robot-models` lists cataloged robot-model manifests by robot id, model id,
format, status, validation status, link name, joint name, and payload kind. It
summarizes URDF, mesh, and material refs with byte totals and checksums so
runtime, replay, simulation, annotation, and training code resolve model data
through MoonData refs instead of workspace-local paths.
`normalize` verifies raw dataset episodes and frames, writes canonical
dataset identity, transform, and lineage manifests, then rebuilds the catalog.
`quality` reads a canonical dataset, loads its referenced episodes and frames,
writes a durable quality run, and rebuilds the catalog.
`quality-runs` lists cataloged quality runs by dataset, episode, status,
finding severity, or rule id, with matched finding/blocker/warning totals and
latest quality status, so review and curation tools can use MoonData as the
quality authority without parsing manifests directly.
`curate` reads a canonical dataset plus a passed quality run, writes the
curated dataset, immutable version, transform run, and lineage, then rebuilds
the catalog.
`replay` reads an accepted curated dataset version, materializes a deterministic
replay payload under `media/replays/`, writes a replay artifact with source refs
to the version, accepted episodes, and frames, rebuilds the catalog, and returns
a validation-backed CLI envelope. This lets a staged dataset version gain replay
coverage before or after export without rerunning the full `prepare-files`
pipeline.
`export` reads an accepted dataset version, verifies its quality gates,
materializes a deterministic export payload under `exports/`, writes a durable
export manifest with output record count, byte count, and checksum metadata,
and rebuilds the catalog.
The stepwise producer CLI commands return the operation result plus a durable
validation report, so scripted pipelines can stop on `ready=false` instead of
performing a second status lookup.
`versions` lists immutable dataset versions by dataset, status, parent version,
accepted episode, quality gate, or summary substring, with matched accepted
episode totals, parent-version totals, quality-gate totals, and latest-version
status. `exports` lists durable export manifests by version, dataset, target
format, status, quality gate, or output kind, and summarizes matched output ref
count, total byte count, and checksums. Together they keep the
training/evaluation handoff boundary queryable through MoonData ids instead of
storage-folder parsing.
`transforms` lists cleaning and normalization transform runs by input/output
dataset, status, quality gate, rejected ref, lineage id, step kind, or summary
substring, with matched step, rejected-ref, quality-gate, and latest-run
evidence. `validations` lists durable validation reports by status and finding
dimensions, with matched finding/blocker/warning totals and latest report
coverage, so handoff gates can be inspected without rerunning validation or
parsing report files directly.
`review` materializes a stored review annotation set and its target index from
an accepted curated version. It verifies the curated dataset, accepted episodes,
frames, and quality-gate evidence before writing review state, then returns a
validation-backed CLI envelope.
`prepare-files` composes import, normalize, quality, curate, stored review,
replay payload generation, export, and validation into one local-file
data-product path. Its output includes annotation, annotation index, and replay
artifact ids, the durable validation report id, readiness flag, and final
catalog count, so the generated root is ready for suite handoff without a
second manual validation step.
`status` and `context` read the catalog plus the latest durable validation
report metadata, then return compact suite-facing projections. They expose
counts for source, capture, dataset, episode, frame, signal, quality,
transform, version, curation, annotation, annotation-target-index, replay,
export, lineage, validation-report, handoff-dossier, repair-run, and
repair-receipt artifacts plus the newest validation status by report
timestamp; `context` is `ready` only when that durable validation report passed,
its generated timestamp and covered catalog-entry count match the current
catalog, and repair pressure is clear. The catalog-entry coverage allows for
the report entry appended after validation. This lets suite consumers
distinguish stale, unvalidated, or uncleared data from handoff-safe data.
The same status and context surface carries the latest validation report id,
validation status, validation timestamp, covered catalog-entry count, coverage
flag, finding count, blocker count, warning count, repair work count, open
repair count, applied repair count, applied-without-validation count, failed
repair count, and pending repair count so callers can decide whether to stop,
review, clean, validate, or continue without a second validation scan or
summary-string parsing.
Catalog-only summaries can count entries and refs, but they never certify
readiness without loading the durable validation report.
`handoff` composes status, context, artifact inventory, lineage graph, optional
dataset-version slice, deduplicated MoonData refs, and an explicit top-level
readiness gate into one bounded dossier for downstream agents and tools. The
handoff is `ready` only when the current root validation passed, repair
pressure is clear, and any requested slice is also ready; stale, missing,
blocked, unvalidated, or uncleared repair data fails closed at the dossier
boundary. It also repeats the validation report id,
validation status, validation timestamp, covered catalog-entry count, coverage
flag, finding count, blocker count, warning count, repair-run count,
repair-receipt count, repair work count, open repair count, applied repair
count, applied-without-validation count, failed repair count, pending repair
count, concrete output refs, aggregate output ref count, byte count, checksums,
and latest validation findings at the dossier top level for bounded agent
handoff.
`publish-handoff` stores that bounded dossier as a MoonData-owned
`handoff-dossier` manifest, including the source validation and source repair
pressure snapshot it used, rebuilds the catalog, and writes a validation report
that covers the stored dossier itself. The stored snapshot is validated against
the same joined repair-work semantics as `status` and `handoff`: applied repair
receipts only close pressure when their post-repair validation report passed and
covers the current catalog. Downstream suite tools can cite the dossier id and
its concrete output refs instead of regenerating handoff context as hidden side
state.
`handoffs` lists stored handoff dossiers by version, readiness status,
validation report, or referenced artifact, with aggregate refs, output refs,
byte counts, checksums, ready count, repair work pressure, and latest-dossier
evidence.
`slice` reads a curated dataset version and returns a bounded handoff view with
accepted episode ids, quality gates, annotation sets, annotation target indexes,
replay artifacts, export manifests, output refs, aggregate output counts, byte
counts, checksums, manifest refs, and current validation readiness. It
keeps local slice readiness separate from root validation readiness and requires
accepted quality gates, a materialized export, and at least one matching replay
artifact with generated refs before a slice can be `ready`. This lets downstream
agents and tools avoid raw storage folders, side ledgers, unreplayable exports,
and stale data at the handoff boundary. `rebuild-catalog` scans persisted
MoonData manifests and rewrites `indexes/catalog.json`, which lets a MoonData
root recover its suite-facing index without rerunning sample generation.
`artifacts` is the compact catalog discovery surface for suite consumers: it
lists MoonData-owned artifact entries by kind, status, id substring, or summary
substring without exposing raw storage folders.
`sources` lists cataloged data-source manifests by id, kind, robot, bridge,
origin URI, label, or source-ref kind, with matched source-ref counts, byte
totals, checksums, and latest-source evidence, so raw robot/simulator/import
origins are queryable through MoonData rather than external ledgers.
`data-refs` projects embedded payload, signal, media, storage, generated,
export output, and handoff output refs from cataloged manifests into one typed
inventory, so suite consumers can find concrete data blobs without knowing
which manifest type owns the ref. The inventory also reports matched byte
totals, unique checksums, local payload status, payload roots, and resolved
local paths so callers can find missing, external, unsafe, non-payload, or
present refs without rereading every manifest.
`payloads` deduplicates that owner-level inventory by URI, reports all
cataloged owners for each concrete payload, and flags byte-count/checksum
metadata conflicts so repair tools can reason about unique data blobs instead
of repeated manifest refs.
`repair-plan` runs the same hard validation gate and turns each finding into a
typed repair action with an `operation_kind` and concrete `target_ref`, grouped
into missing payloads, unmanaged payloads, metadata conflicts, unsafe refs,
external refs, non-payload refs, manifest surface refs, or general integrity
repairs. Robot-model URDF references to undeclared `moondata://` assets route
to manifest-surface repair work with
`declare-or-remove-embedded-asset-ref`, so hidden URDF asset dependencies must
be made explicit in the robot-model manifest or removed. It is read-only: it
tells operators and agents what must be restored, declared, rewritten,
materialized, moved, split, or removed before handoff without creating a
separate cleanup ledger.
`publish-repair-plan` persists that action list as a cataloged `repair-run`
manifest under `repairs/` after writing the source validation report it used,
so cleanup decisions and repair evidence remain MoonData-owned artifacts rather
than CLI transcripts or external tickets.
`repairs` lists cataloged repair runs by validation report, validation status,
operation kind, target ref, action category, severity, rule id, artifact kind,
or artifact id, with action and category totals plus latest-run evidence.
Repair and cleanup tooling can therefore resume from MoonData-owned repair
evidence instead of repeating validation scans or reading CLI transcripts.
`repair-work` joins cataloged repair runs with their latest repair receipts,
projecting every planned repair action as open, applied, applied-unvalidated,
failed, or pending work. This is the operator/agent worklist for cleanup:
plans stay immutable, receipts stay append-only, and the worklist is a
recoverable projection over MoonData-owned artifacts. An applied receipt only
leaves applied-unvalidated pressure when its post-repair validation report is
cataloged, passed, generated after the receipt, and covers the current catalog.
`record-repair` records append-only execution evidence for one repair action as
a cataloged `repair-receipt` under `repair_receipts/`. It copies the
operation kind and target ref from the original repair action, so receipts
cannot silently drift from the plan they claim to execute. When an `applied`
receipt cites a post-repair validation report, that report must be cataloged,
generated after the receipt application time, passed, and cover the current
catalog, allowing for the validation report entry itself; otherwise the receipt
does not close cleanup.
`repair-receipts` lists recorded repair execution evidence by repair run,
action, operation kind, target ref, status, actor, or post-repair validation
report, allowing agents and operators to separate planned cleanup from applied
cleanup without an external ticket ledger.
`datasets` lists cataloged dataset manifests by kind, status, source, capture,
episode, or data-ref kind, with matched source, capture, episode, data-ref, byte
count, and latest-dataset evidence, so MoonData dataset ids remain the primary
handle for raw, canonical, and curated robot data.
`captures` lists cataloged capture sessions by source, robot, bridge, status,
or data ref kind, with matched data-ref, receipt, stopped-capture, byte-count,
and latest-capture evidence, so runtime/sidecar producers and suite consumers
can inspect capture inventory without parsing storage folders.
`episodes` and `frames` list cataloged episode and frame manifests by robot,
bridge, dataset, session, task, episode, and data-ref kind. Episode listings
also report matched frame, receipt, data-ref, byte-count, stopped-episode, and
latest-episode evidence; frame listings report matched payload, signal, media,
data-ref, byte-count, and latest-frame evidence, preserving bounded read paths
from dataset id to individual frame refs.
`lineage` reads cataloged lineage manifests and returns bounded nodes, edges,
and manifest refs so downstream tools can explain dataset provenance without
walking transform, version, and dataset storage folders themselves.
`rebuild-annotation-targets` clears persisted annotation target indexes,
rewrites them from annotation set manifests, and rebuilds the catalog, keeping
review lookup projections recoverable from MoonData-owned state.
`review` is the producer path for durable review state: it writes annotation
sets and target indexes directly from accepted versions, making curation
decisions reproducible from MoonData refs rather than review-queue side state.
`annotations` lists annotation sets from the catalog by dataset, episode,
frame, task id, reviewer, status, or label, with aggregate label, target-ref,
evidence-ref, and latest-annotation evidence, without scanning raw storage
folders.
`annotation-targets` lists persisted annotation target indexes by target
artifact, reviewer, status, or label evidence, so review queues can resolve
target-to-annotation coverage directly through MoonData.
`replays` lists replay artifacts from the catalog by dataset, episode, source
artifact ref, viewer profile, or generated payload kind, with matched episode,
source-ref, generated-ref, byte-count, checksum, and latest-replay evidence,
without scanning raw storage folders.
`validate` checks that the catalog is rebuild-equivalent to stored MoonData
manifests, then checks canonical manifest paths, local manifests, local
payload refs, signal storage refs, robot-model URDF/mesh/material refs, replay
generated refs, export output refs, handoff dossier refs, concrete handoff
output refs, source-validation snapshots, payload existence, byte counts and
checksums, robot-model URDF embedded asset closure, count fields, manifest id
consistency, cross-manifest payload metadata consistency, ready-export replay
coverage, unmanaged local payload files, external DataRef URIs, DataRefs
outside payload roots, DataRefs that point at manifest surfaces, and
handoff repair-pressure snapshots against current repair runs, receipts, and
post-repair validation coverage, and cross-manifest MoonData references before
downstream export or suite handoff, then writes a durable validation report and
catalogs it.
`moondata_boundaries` is the architecture guard: MoonData packages may depend
on MoonData packages and MoonBit core/x libraries, but they must not import
Moonrobo runtime, bridge, RoboBook/MoonBook, replay, annotation, host API, or
SDK implementation packages. It also ratchets the explicit MoonData package
set and scans MoonData-owned source/docs for stale reference-product residue so
new packages and copied concepts remain intentional.

## Data Flow

The live data path should be explicit:

```text
robot / simulator / SDK sidecar
  -> Moonrobo validates identity, safety, and runtime state
  -> Moonrobo writes control evidence and receipts
  -> Moonrobo registers capture data with MoonData
  -> MoonData indexes frames, signals, media, and episodes
  -> MoonData runs quality and cleaning pipelines
  -> MoonData publishes replay, annotation, version, and export manifests
  -> MoonData writes a catalog index for bounded suite reads
  -> RoboBook stores accepted MoonData refs and summaries
  -> MoonClaw reads bounded MoonData refs through Moonrobo context
```

This keeps physical authority and data authority separate while preserving one
audit path from user request to robot action to captured evidence to curated
dataset.

## Phase Plan

### Phase 1: Contract And Storage Skeleton

Define MoonData ids, manifests, dataset/episode/frame refs, lineage, and the
local storage layout. Add black-box tests for stable JSON round trips and path
derivation. No UI and no bridge execution changes yet.

Exit criteria:

- MoonData manifests can be serialized and validated
- a MoonData root can be initialized locally
- dataset and episode ids are stable and collision-resistant enough for local
  workspaces

### Phase 2: Moonrobo Capture Registration

Add a narrow registration path from Moonrobo observations and task executions
to MoonData. Observation sessions, telemetry frames, and command-feedback
frames continue to be produced by Moonrobo, but MoonData receives the canonical
capture/session/episode references.

Exit criteria:

- one Moonrobo observation session creates a MoonData capture session
- RoboBook stores MoonData refs instead of raw data ownership claims
- MoonBook memory cards summarize the accepted data refs, not raw frames

First implementation:

- `src/moondata_ingest` remains pure and builds capture/session/episode/frame
  manifests from sidecar-style frame refs
- `src/moondata_capture` persists those manifests under a MoonData root and
  rebuilds the catalog without importing runtime, bridge, memory, or agent
  packages
- `cmd/moondata register-capture` exercises the durable capture entrypoint for
  robot or sidecar producers; its CLI envelope includes a validation report for
  the produced root

### Phase 3: Canonical Robot Data Schema

Normalize Moonrobo telemetry, command feedback, replay frames, imported files,
task execution snapshots, and robot model artifacts into one canonical
dataset/episode/frame/model vocabulary.

Exit criteria:

- telemetry and command-feedback data share a common timebase model
- frame refs can point to inline JSON, chunked files, media, or signal storage
- robot id, bridge id, receipt id, and task id lineage are preserved
- URDF and mesh/material assets are addressable through MoonData robot-model
  refs instead of runtime-local paths

First implementation:

- `src/moondata_import` creates one `SignalSeries` manifest for each imported
  local payload and attaches the raw storage ref to the corresponding frame
  signal refs
- `src/moondata_store` persists and reads signal-series manifests under
  `signals/`
- `src/moondata_api` and `cmd/moondata signals` expose catalog-backed signal
  discovery by dataset, episode, field path, or storage kind, with aggregate
  sample counts, storage refs, byte totals, and checksums
- `src/moondata_core`, `src/moondata_store`, `src/moondata_api`, and
  `cmd/moondata robot-models` expose robot-model manifests by robot id,
  model id, URDF ref, mesh/material refs, provenance, validation status, byte
  totals, and checksums
- `src/moondata_robot_model` and `cmd/moondata import-robot-model` import
  extracted URDF packages into MoonData-owned `media/robot_models/` payloads
  and write cataloged robot-model manifests without using runtime or RoboBook
  storage paths

### Phase 4: Quality Authority

Move durable dataset quality into MoonData. Start with deterministic checks:
missing frames, timestamp gaps, stale telemetry, identity mismatch, command echo
mismatch, frame-count thresholds, bridge errors, unsafe outliers, and missing
annotations.

Exit criteria:

- MoonData owns quality findings and quality-run summaries
- Moonrobo readiness can read MoonData quality status
- RoboBook memory can reference an accepted quality report id

First implementation:

- `src/moondata_quality` keeps deterministic episode/frame rules pure and
  store-free
- `src/moondata_assess` reads canonical datasets from the MoonData root,
  evaluates referenced episodes and frames, writes quality runs, and refreshes
  the catalog
- `cmd/moondata quality` exercises the durable quality authority without
  touching runtime, memory, or agent packages; its CLI envelope includes a
  validation report for the produced root
- `src/moondata_api` and `cmd/moondata quality-runs` expose filtered quality
  run inventory by dataset, episode, status, finding severity, or rule id, with
  aggregate finding counts and latest quality status

### Phase 5: Cleaning, Versioning, And Lineage

Add non-destructive transform runs. Every cleaned dataset version points to raw
or canonical parents and includes transform config, rejected refs, and
checksums.

Exit criteria:

- curated dataset versions are immutable
- rejected episodes and frames are traceable to findings or manual decisions
- a version can be regenerated from its lineage and source refs

First implementation:

- `src/moondata_transform` creates curated datasets, versions, transform runs,
  and lineage manifests from canonical input datasets
- `src/moondata_curate` reads stored canonical datasets and passed quality
  runs, then persists curated datasets, versions, transforms, and lineage
- `src/moondata_store` persists curated datasets under `datasets/curated/`,
  versions under `versions/`, transforms under `transforms/`, and lineage under
  `lineage/`
- `cmd/moondata curate` exercises this path without touching runtime, memory,
  or agent packages; its CLI envelope includes a validation report for the
  produced root
- `src/moondata_api` and `cmd/moondata versions` expose immutable dataset
  version inventory by dataset, status, parent version, accepted episode,
  quality gate, or summary substring, with accepted-episode totals, parent
  version totals, quality-gate totals, and latest-version status
- `src/moondata_store`, `src/moondata_api`, and `cmd/moondata transforms`
  expose transform-run inventory by input/output dataset, quality gate,
  rejected ref, lineage id, step kind, and summary substring, with aggregate
  step counts, rejected-ref counts, quality-gate counts, and latest-run status

### Phase 6: Annotation And Replay

Attach annotations to MoonData episode/frame refs and generate replay artifacts
from MoonData, not from RoboBook-only file paths.

Exit criteria:

- replay artifacts carry MoonData source refs
- annotation sets can be listed by dataset, episode, frame, task, or reviewer
- Moonrobo replay routes can become projections over MoonData refs

First implementation:

- `src/moondata_core` defines `AnnotationSet`, `AnnotationLabel`, and
  `AnnotationTargetIndex`, and `ReplayArtifact`
- `src/moondata_annotation` creates review annotation sets and persisted target
  indexes
- `src/moondata_review` writes stored review annotations and target indexes
  from accepted curated versions, independently of the local-file product
  pipeline
- `src/moondata_replay` materializes replay payloads and replay artifact
  manifests from accepted dataset versions without importing runtime, memory,
  agent, or API packages
- `cmd/moondata review` exercises the stored review materialization path with a
  validation-backed CLI envelope, so curation decisions can be published
  separately from `prepare-files`
- `cmd/moondata replay` exercises the stored replay materialization path with a
  validation-backed CLI envelope, so replay coverage can be produced separately
  from `prepare-files`
- `src/moondata_pipeline` and `cmd/moondata prepare-files` now produce review
  annotation sets, target indexes, and replay artifacts as first-class outputs
  of the local-file product path before export and validation
- `src/moondata_api` and `cmd/moondata annotations` list annotation sets by
  artifact refs, task id, reviewer, status, or label from the MoonData catalog,
  with aggregate label, target-ref, evidence-ref, and latest-annotation
  evidence
- `src/moondata_api` and `cmd/moondata annotation-targets` list persisted target
  indexes by artifact ref, reviewer, status, or label evidence
- `src/moondata_index` and `cmd/moondata rebuild-annotation-targets` rebuild
  annotation target indexes from annotation set manifests before catalog rebuild
- `src/moondata_api` and `cmd/moondata replays` list replay artifacts by
  dataset, episode, source refs, viewer profile, or generated payload kind from
  the MoonData catalog, with aggregate generated payload evidence

### Phase 7: Export Authority

Make MoonData the only source for training/evaluation exports. Export manifests
include input version, target format, field mapping, quality gate, output refs,
and verification results.

Exit criteria:

- exports are reproducible from MoonData versions
- MoonClaw and Moontown can request bounded dataset slices by id
- downstream training code no longer reads RoboBook paths directly

First implementation:

- `src/moondata_export` builds export manifests from immutable dataset versions
- export manifests inherit version quality gates
- `src/moondata_publish` reads stored accepted dataset versions, verifies their
  passed quality runs, materializes export payloads, writes export manifests,
  returns record count, byte count, and checksum evidence, and refreshes the
  catalog
- `cmd/moondata export` publishes a stored export manifest without touching
  runtime, memory, or agent packages, then persists a validation report for the
  produced root and returns both export and validation results
- `src/moondata_api` and `cmd/moondata exports` expose filtered export-manifest
  inventory by version, dataset, target format, status, quality gate, or output
  kind, with aggregate output ref count, byte count, and checksums

### Phase 8: Suite Integration

Expose MoonData status through Moonrobo readiness, MoonClaw context, Rabbita
cockpit links, Moontown platform queue, MoonBook memory cards, and Moonstat
observability.

Exit criteria:

- every high-volume robot data artifact has a MoonData id
- every robot model artifact used for replay, simulation, annotation, or
  training has a MoonData id
- RoboBook contains only refs, summaries, receipts, and robot-domain evidence
- the suite has one data authority for capture, quality, curation, and export

First implementation:

- `MoonDataCatalog` lives under `indexes/catalog.json` and is the compact index
  over canonical datasets, curated datasets, episodes, quality runs,
  transforms, versions, lineage, annotations, replay artifacts, exports, repair
  runs, repair receipts, and handoff dossiers
- `src/moondata_api` exposes read-only status and context projections from that
  catalog, including first-class artifact counts, current validation-report
  status, finding counts, and repair work pressure for handoff readiness;
  readiness requires the latest durable validation report to cover the current
  catalog by report timestamp and catalog-entry count, and requires open,
  applied-unvalidated, failed, and pending repair work counts to be clear
- `cmd/moondata status` and `cmd/moondata context` prove suite consumers can
  read bounded refs and validation readiness without reaching into raw storage
  folders
- `src/moondata_api` and `cmd/moondata handoff` compose status, context,
  artifact inventory, lineage, optional dataset-version slice, validation
  identity, validation coverage, aggregate output verification evidence,
  validation finding counts, repair work pressure, latest validation findings,
  and explicit readiness into a single suite handoff dossier
- `src/moondata_handoff` and `cmd/moondata publish-handoff` persist a bounded
  handoff dossier as a cataloged MoonData artifact, including the source repair
  pressure snapshot, and validate the root after the dossier is written, so
  downstream tools can cite a durable data-plane handoff id
- `src/moondata_api` and `cmd/moondata handoffs` expose filtered stored
  handoff dossiers by version, readiness, validation report, or referenced
  artifact with aggregate output, ref, and repair-pressure evidence
- `src/moondata_api` and `cmd/moondata slice` expose a bounded dataset-version
  handoff with accepted episode ids, quality gates, annotation sets, annotation
  target indexes, replay artifacts, export output refs, aggregate output
  verification evidence, manifest refs, and current validation readiness for
  downstream evaluation or training consumers; local slice readiness fails
  closed as `pending-replay` until replay artifacts with generated payload refs
  are present for the accepted version
- `src/moondata_api` and `cmd/moondata artifacts` expose catalog discovery by
  artifact kind, status, id substring, or summary substring so suite tools use
  MoonData as the artifact inventory instead of walking storage folders
- `src/moondata_store`, `src/moondata_api`, and `cmd/moondata sources` expose
  data-source inventory by id, kind, robot, bridge, origin URI, label, or
  source-ref kind, with aggregate source-ref counts, byte totals, checksums,
  and latest-source evidence so raw origins remain first-class MoonData
  artifacts
- `src/moondata_api` and `cmd/moondata data-refs` expose a unified data-ref
  inventory across source, dataset, capture, episode, frame, signal, replay,
  export, and handoff manifests, with aggregate byte totals, unique checksums,
  and local payload status counts so consumers discover missing, external,
  unsafe, non-payload, and present concrete refs through MoonData instead of
  manifest-specific scans
- `src/moondata_api` and `cmd/moondata payloads` expose a deduplicated payload
  inventory by URI with owner refs, payload roots, local status counts, and
  metadata conflict counts so data repair and cleaning tools work from unique
  payload identity rather than duplicated manifest references
- `src/moondata_repair` and `cmd/moondata repair-plan` expose a read-only
  repair plan from validation findings, categorizing routeable repair actions
  by operation kind and target ref for missing payloads, unmanaged payloads,
  metadata conflicts, unsafe/external/non-payload refs, and manifest-surface
  refs before handoff, including hidden URDF `moondata://` asset dependencies
  that must become declared robot-model refs or be removed
- `src/moondata_core`, `src/moondata_store`, `src/moondata_index`,
  `src/moondata_validate`, `src/moondata_repair`, and
  `cmd/moondata publish-repair-plan` persist cataloged `repair-run` manifests
  under `repairs/`, preserving validation-backed cleanup action lists as
  MoonData-owned repair evidence
- `src/moondata_api` and `cmd/moondata repairs` expose cataloged repair-run
  listings by validation report, status, operation kind, target ref, action
  category, severity, rule id, artifact kind, or artifact id, with aggregate
  action and category totals
- `src/moondata_api` and `cmd/moondata repair-work` expose the joined cleanup
  worklist across repair runs and latest receipts, with open, applied,
  applied-unvalidated, failed, and pending action counts; applied receipts only
  become closed applied work when their post-repair validation reports passed
  and cover the current catalog; the same pressure is also projected through
  `status`, `context`, and `handoff` so Moonrobo, MoonClaw, Moontown, Rabbita,
  and Moonstat can see cleanup pressure without issuing a repair-specific query
  first; uncleared repair pressure makes readiness `repair-pressure`
- `src/moondata_core`, `src/moondata_store`, `src/moondata_index`,
  `src/moondata_validate`, `src/moondata_repair`, `src/moondata_api`, and
  `cmd/moondata record-repair`/`repair-receipts` persist, validate, and list
  cataloged `repair-receipt` manifests under `repair_receipts/`, preserving
  append-only execution evidence for each routeable repair action; applied
  receipts that cite validation reports must cite a passed post-repair report
  that covers the current catalog
- `src/moondata_api` and `cmd/moondata datasets` expose filtered dataset
  listings by kind, status, source, capture, episode, or payload kind, with
  aggregate source, capture, episode, data-ref, byte-count, and latest-dataset
  evidence, so consumers use MoonData dataset ids as the unique data handle
- `src/moondata_api` and `cmd/moondata versions` expose filtered immutable
  dataset-version listings with aggregate accepted episode, parent version, and
  quality-gate evidence so accepted curation outputs are addressable through
  MoonData before export or handoff
- `src/moondata_api` and `cmd/moondata exports` expose filtered export-manifest
  listings so downstream training and evaluation consumers query durable output
  manifests and aggregate output verification evidence through MoonData
- `src/moondata_api` and `cmd/moondata captures` expose filtered capture-session
  listings with aggregate data-ref, receipt, stopped-capture, byte-count, and
  latest-capture evidence so robot, bridge, and sidecar capture inventory is
  queryable through the data plane
- `src/moondata_api` and `cmd/moondata episodes` / `cmd/moondata frames`
  expose filtered episode and frame listings, with aggregate episode-level
  frame, receipt, data-ref, byte-count, stopped-episode, and latest-episode
  evidence plus frame-level payload, signal, media, data-ref, byte-count, and
  latest-frame evidence, so downstream tools can traverse dataset contents
  without parsing storage folders
- `src/moondata_api` and `cmd/moondata lineage` expose a bounded lineage graph
  view over cataloged lineage manifests for provenance, regeneration, and
  review tools
- `src/moondata_api` and `cmd/moondata signals` expose filtered signal-series
  listings so telemetry, command-feedback, and imported raw streams are
  discoverable and verifiable through MoonData refs rather than storage-folder
  scans
- `src/moondata_api` and `cmd/moondata robot-models` expose filtered
  robot-model listings so URDF, mesh/material, and derived kinematic evidence
  are resolved through MoonData refs before runtime, replay, simulation, or
  annotation code consumes them
- `src/moondata_robot_model` and `cmd/moondata import-robot-model` provide the
  durable producer boundary for URDF packages: copy payloads into MoonData,
  rewrite simple package mesh URIs, write the robot-model manifest, require
  embedded URDF asset refs to be declared by that manifest, rebuild the catalog,
  and validate the root
- `src/moondata_api` and `cmd/moondata quality-runs` expose filtered quality
  run listings with aggregate finding counts and latest quality status so
  curation, handoff, and review tools can resolve quality status and findings
  through MoonData rather than a side ledger
- `src/moondata_api` and `cmd/moondata annotations` expose filtered annotation
  listings with aggregate label, target-ref, evidence-ref, and
  latest-annotation evidence so review queues and dataset curation tools read
  MoonData, not a side ledger
- `src/moondata_review` and `cmd/moondata review` materialize review
  annotation sets and target indexes from accepted versions as durable
  producer outputs
- `src/moondata_store`, `src/moondata_api`, and `cmd/moondata annotation-targets`
  expose persisted annotation target indexes so review queues can query target
  coverage through MoonData without reverse-scanning annotation manifests
- `src/moondata_api` and `cmd/moondata replays` expose filtered replay listings
  with aggregate episode, source-ref, generated-ref, byte-count, checksum, and
  latest-replay evidence so replay routes and review tools can query MoonData
  replay artifacts directly
- `src/moondata_index` and `cmd/moondata rebuild-catalog` regenerate the
  catalog directly from MoonData-owned manifests, making the catalog a
  recoverable index rather than hand-written state
- `src/moondata_index` and `cmd/moondata rebuild-annotation-targets` regenerate
  annotation target indexes directly from annotation set manifests, making
  target lookup a recoverable MoonData projection rather than a side ledger
- `src/moondata_capture` and `cmd/moondata register-capture` persist
  sidecar-style source, capture, dataset, episode, and frame manifests with a
  refreshed catalog and validation-backed CLI envelope, rejecting path-unsafe
  ids, non-MoonData frame payload refs, missing payload files, and mismatched
  byte/checksum metadata before writing so high-volume robot captures enter
  MoonData through a durable data-plane boundary
- `src/moondata_import` and `cmd/moondata import-files` materialize local raw
  text payloads under `media/imports/`, register source/capture/dataset/episode
  and frame manifests, reject path-unsafe dataset ids before writing, close the
  completed imported episode, and rebuild the catalog from MoonData-owned state
- `src/moondata_normalize` and `cmd/moondata normalize` promote raw imported
  datasets into canonical dataset identity with explicit transform and lineage
  manifests
- `src/moondata_assess` and `cmd/moondata quality` persist quality runs for
  canonical datasets and make the result visible through the catalog
- `src/moondata_curate` and `cmd/moondata curate` gate curation on a passed
  quality run and persist the curated dataset, version, transform, and lineage
- `src/moondata_publish` and `cmd/moondata export` publish durable export
  payloads and manifests from accepted versions while preserving inherited
  quality gates
- `src/moondata_replay` and `cmd/moondata replay` publish durable replay
  payloads and replay artifact manifests from accepted versions, giving
  standalone export flows the replay coverage required by validation
- `cmd/moondata import-files`, `normalize`, `quality`, `curate`, `replay`,
  `review`, `publish-handoff`, and `export` return validation-backed or
  validation-result envelopes, so each durable producer command can be used as
  a standalone data-plane boundary
- `src/moondata_pipeline` and `cmd/moondata prepare-files` compose the local
  file path into review annotation, rebuilt annotation target index, replay
  payload, replay artifact, quality-gated export manifest, durable passed
  validation report, and explicit readiness flag
- `src/moondata_validate` and `cmd/moondata validate` provide a hard integrity
  gate over catalog rebuild equivalence, catalog counts, duplicate artifact
  ids, required fields, local manifest existence, local payload ref existence,
  signal storage ref existence, required one-to-one annotation target index
  closure and consistency, replay generated payload ref existence, export
  output ref existence, handoff dossier ref closure, concrete handoff output ref
  payload existence and consistency, source-validation snapshot consistency,
  cross-manifest payload metadata consistency, unmanaged local payload
  detection, external DataRef URIs, DataRefs outside payload roots, DataRefs
  that point at manifest surfaces, ready-export replay coverage, payload
  byte-count/checksum integrity, manifest id consistency, count consistency,
  cross-manifest reference closure, and same-dataset graph consistency, with
  durable validation reports under `validations/`
- `src/moondata_api` and `cmd/moondata validations` expose filtered validation
  report inventory by status, finding severity, rule id, and affected artifact
  with aggregate finding counts and latest-report coverage so suite handoff
  readiness can be inspected through MoonData
- `src/moondata_boundaries` keeps MoonData standalone by testing dependency
  direction, ratcheting the explicit MoonData package list, and rejecting
  imports or stale source residue from robot control, memory, gateway, and
  reference-product packages
