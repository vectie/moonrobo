# MoonData Data Plane

MoonData is the Moon suite's robot data plane. It is the unique source of
truth for raw robot data, cleaned data, dataset identity, episode/frame
indexes, quality findings, annotations, replay artifacts, lineage, and export
manifests.

MoonData is not a wrapper around another product. It should be built as a
fresh Moon-suite layer with MoonBit-first contracts, local-first storage, and a
small API surface that Moonrobo, RoboBook, MoonClaw, Rabbita, Moontown, and
Moonstat can all read without inventing separate data ledgers.

## Boundary

MoonData owns:

- raw captures from robots, simulators, SDK sidecars, and imports
- canonical robot data schemas
- dataset, episode, frame, signal, and media identities
- immutable manifests, checksums, and lineage graphs
- quality findings and quality-run reports
- non-destructive cleaning and transformation runs
- manual and agent annotations over episode/frame references
- replay artifacts derived from canonical data
- curated dataset versions and downstream export manifests

MoonData does not own:

- physical command execution
- safety gates, approvals, emergency stop, or bridge dispatch
- robot routine policy or agent planning
- durable conversation, recall, or accepted semantic memory
- robot identity, bridge configuration, safety policy, or calibration authority

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
  media/
    imports/
  indexes/
  quality/
  annotations/
  transforms/
  versions/
  replays/
  exports/
  lineage/
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
rather than a second ledger maintained by external tools.
Before an export or suite handoff, MoonData validation should check that the
catalog entry count matches the entries, artifact ids are unique, required
fields are present, every local manifest path exists, and every local
`moondata://...` payload ref still resolves under the selected MoonData root.

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

MoonData should start with small, serializable contracts.

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

ReplayArtifact
  replay id, source dataset/episode refs, generated files, viewer metadata

ExportManifest
  export id, input version, target format, field mapping, output refs, report
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
  lineage.mbt
  transform.mbt
  annotation.mbt
  replay.mbt
  export.mbt

src/moondata_store/
  store.mbt

src/moondata_ingest/
  capture_registration.mbt

src/moondata_quality/
  deterministic.mbt

src/moondata_transform/
  curation.mbt

src/moondata_annotation/
  review.mbt

src/moondata_export/
  export_builder.mbt

src/moondata_index/
  index.mbt

src/moondata_import/
  local_files.mbt

src/moondata_api/
  status.mbt
  context.mbt

src/moondata_validate/
  validation.mbt

src/moondata_boundaries/
  moondata_boundaries_test.mbt

cmd/moondata/
  init
  register-sample
  curate-sample
  import-files
  rebuild-catalog
  status
  context
  validate
```

The current implementation lands the core, store, ingest, deterministic
quality, transform/curation, annotation, export, index, import, and API
projection packages.
`curate-sample` is the first end-to-end local proof: it writes a canonical
capture, quality run, curated dataset, immutable dataset version, transform
run, lineage graph, annotation set, replay artifact, export manifest, and
catalog under one MoonData root. `import-files` is the first real raw intake
lane: it copies local text/JSON/CSV/log payloads into `media/imports/`, writes
raw dataset, source, capture, episode, and frame manifests, then rebuilds the
catalog. `status` and `context` read only the catalog and return compact
suite-facing projections. `rebuild-catalog` scans persisted MoonData manifests
and rewrites `indexes/catalog.json`, which lets a MoonData root recover its
suite-facing index without rerunning sample generation. `validate` checks the
catalog, local manifests, and local payload refs before downstream export or
suite handoff.
`moondata_boundaries` is the architecture guard: MoonData packages may depend
on MoonData packages and MoonBit core/x libraries, but they must not import
Moonrobo runtime, bridge, RoboBook/MoonBook, replay, annotation, host API, or
SDK implementation packages.

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

### Phase 3: Canonical Robot Data Schema

Normalize Moonrobo telemetry, command feedback, replay frames, imported files,
and task execution snapshots into one canonical dataset/episode/frame model.

Exit criteria:

- telemetry and command-feedback data share a common timebase model
- frame refs can point to inline JSON, chunked files, media, or signal storage
- robot id, bridge id, receipt id, and task id lineage are preserved

### Phase 4: Quality Authority

Move durable dataset quality into MoonData. Start with deterministic checks:
missing frames, timestamp gaps, stale telemetry, identity mismatch, command echo
mismatch, frame-count thresholds, bridge errors, unsafe outliers, and missing
annotations.

Exit criteria:

- MoonData owns quality findings and quality-run summaries
- Moonrobo readiness can read MoonData quality status
- RoboBook memory can reference an accepted quality report id

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
- `src/moondata_store` persists curated datasets under `datasets/curated/`,
  versions under `versions/`, transforms under `transforms/`, and lineage under
  `lineage/`
- `cmd/moondata curate-sample` exercises this path without touching RoboBook

### Phase 6: Annotation And Replay

Attach annotations to MoonData episode/frame refs and generate replay artifacts
from MoonData, not from RoboBook-only file paths.

Exit criteria:

- replay artifacts carry MoonData source refs
- annotation sets can be listed by dataset, episode, frame, task, or reviewer
- Moonrobo replay routes can become projections over MoonData refs

First implementation:

- `src/moondata_core` defines `AnnotationSet`, `AnnotationLabel`, and
  `ReplayArtifact`
- `src/moondata_annotation` creates review annotation sets and target indexes
- `cmd/moondata curate-sample` writes both annotation and replay manifests

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
- `cmd/moondata curate-sample` writes an export manifest that points back to the
  curated version and its quality run

### Phase 8: Suite Integration

Expose MoonData status through Moonrobo readiness, MoonClaw context, Rabbita
cockpit links, Moontown platform queue, MoonBook memory cards, and Moonstat
observability.

Exit criteria:

- every high-volume robot data artifact has a MoonData id
- RoboBook contains only refs, summaries, receipts, and robot-domain evidence
- the suite has one data authority for capture, quality, curation, and export

First implementation:

- `MoonDataCatalog` lives under `indexes/catalog.json` and is the compact index
  over canonical datasets, curated datasets, episodes, quality runs,
  transforms, versions, lineage, annotations, replay artifacts, and exports
- `src/moondata_api` exposes read-only status and context projections from that
  catalog
- `cmd/moondata status` and `cmd/moondata context` prove suite consumers can
  read bounded refs without reaching into raw storage folders
- `src/moondata_index` and `cmd/moondata rebuild-catalog` regenerate the
  catalog directly from MoonData-owned manifests, making the catalog a
  recoverable index rather than hand-written state
- `src/moondata_import` and `cmd/moondata import-files` materialize local raw
  text payloads under `media/imports/`, register source/capture/dataset/episode
  and frame manifests, and rebuild the catalog from MoonData-owned state
- `src/moondata_validate` and `cmd/moondata validate` provide a hard integrity
  gate over catalog counts, duplicate artifact ids, required fields, local
  manifest existence, and local payload ref existence
- `src/moondata_boundaries` keeps MoonData standalone by testing dependency
  direction and rejecting imports from robot control, memory, and gateway
  packages
