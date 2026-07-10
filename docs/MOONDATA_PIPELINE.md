# MoonData Production Pipeline

MoonData is the unique authority for robot-data identity, payload ownership,
quality decisions, lineage, versions, and downstream handoff. This does not
mean every byte must be in one directory. Large payloads may live in local or
object storage, but they remain addressed by MoonData ids and governed by
MoonData manifests.

This document is the delivery plan for turning the existing local artifact
flow into an unattended, recoverable robot-data pipeline.

## Current Product State

MoonData already has broad domain coverage:

- source, capture, dataset, episode, frame, signal, and robot-model contracts
- local file and robot-model import
- canonical, quality, curation, annotation, replay, export, and validation
  artifacts
- catalog, query, repair, and handoff projections
- a bounded read-only cockpit status surface

The original local-file path was a synchronous operation. The first production
foundation now records durable run and stage state and exposes submit, status,
resume, retry, cancel, and list operations. Normalization still preserves refs
instead of decoding and aligning modalities, quality rules remain mostly
structural, and training exports are still JSONL or CSV.

The capture foundation can also seal one finalized MCAP file into immutable,
SHA-256-addressed blob storage and register it as a raw MoonData capture. Live
recorder supervision, rotation, message-loss metrics, recovery tooling, and
remote upload remain Phase B work.

The immediate product objective is therefore operational correctness, not more
artifact vocabulary.

## Pipeline Contract

```text
robot / simulator / file source
  -> capture or import
  -> seal raw payloads
  -> register immutable source
  -> decode and normalize
  -> schema and quality gates
  -> quarantine, repair, or review
  -> curate and version
  -> replay, indexes, and statistics
  -> training/evaluation export
  -> deployment outcome and recollection feedback
```

Every execution is a `PipelineRun`. Each stage is a `PipelineStageRun` with a
stable id, status, attempt count, timestamps, and failure evidence. Run state
is persisted before and after stage execution.

Required behavior:

- submitting the same run id is idempotent
- completed stages are checkpoints and are not repeated during resume
- a failed run can be retried from its first incomplete stage
- cancellation is durable and checked between stages
- stage failure records the store issue code, path, and message
- a process restart can recover state using only the MoonData root and run id
- artifact ids are derived before execution and remain stable across attempts
- a run is complete only after root validation passes

Pipeline run files are control metadata, not cataloged dataset artifacts. They
live under `runs/pipelines/` and point to canonical MoonData artifact ids.

## Storage Direction

The production storage boundary has two responsibilities:

- `BlobStore`: immutable payload bytes, cryptographic content ids, local and
  S3-compatible implementations, range reads, resumable upload, and retention
- `MetadataStore`: pipeline runs, manifests, revisions, indexes, atomic commit,
  migration, and concurrent-writer protection

The first release remains local-first and uses durable run manifests. The
interfaces and directory ownership must permit a transactional metadata
backend and remote blob store without changing domain contracts.

All new metadata writes must move toward temporary-write plus atomic-replace
semantics. Payload identity must move from the current rolling checksum to a
cryptographic digest before remote deduplication or untrusted transfer is
enabled.

## Product Workflows

The command-line workflow is the first operational surface:

```text
moondata pipeline-submit <root> <input> <dataset> <robot> <bridge> <run-id>
moondata pipeline-status <root> <run-id>
moondata pipeline-resume <root> <run-id>
moondata pipeline-retry <root> <run-id>
moondata pipeline-cancel <root> <run-id>
moondata pipeline-runs <root>
```

The cockpit should later expose the same model through five task-oriented
views:

- **Runs**: active, blocked, failed, and completed work with resume/retry/cancel
- **Captures**: recorder health, message loss, disk pressure, sealing, upload
- **Datasets**: versions, modality coverage, quality, splits, and lineage
- **Review**: synchronized replay, findings, quarantine, approve/reject
- **Exports**: target format, progress, verification, and training handoff

The default MoonData screen should answer: "What data work needs attention
now?" Raw inventory remains a secondary inspection tool.

## Delivery Phases

### Phase A: Durable Local Engine

Deliver:

- persisted pipeline and stage runs
- submit, status, list, resume, retry, and cancel operations
- stable stage ids and deterministic artifact ids
- checkpointed local-file product execution
- failure evidence and validation-gated completion

Exit: terminate a run between stages, restart the command, and complete without
repeating successful stages.

### Phase B: Capture And Sealing

Deliver:

- MCAP/ROS 2 source connector and robot-side capture agent
- bounded buffering, rotation, disk-pressure policy, and message-loss metrics
- chunk recovery, finalization, cryptographic checksums, and resumable upload
- local and S3-compatible blob-store implementations

Exit: an interrupted robot recording is recoverable, registered once, and
traceable from capture through immutable raw refs.

Current implementation:

- `src/moondata_blob` stores immutable payloads under sharded
  `blobs/sha256/` paths, hashes files in bounded chunks, stages and syncs local
  copies before publication, verifies the stored digest, and deduplicates by
  digest
- `src/moondata_capture` reads only the opening and closing MCAP ranges before
  sealing, then streams the recording into blob storage
- `cmd/moondata seal-mcap` registers one finalized recording as a raw source,
  capture, dataset, episode, and frame graph, then runs root validation

### Phase C: Canonical Multimodal Data

Deliver:

- typed image, depth, audio, state, action, command, and event modalities
- decoding, units, coordinate frames, clock domains, synchronization, and
  resampling
- calibration and robot-model version binding
- explicit terminal, truncated, success, failure, and intervention semantics

Exit: one episode can be replayed and consumed as aligned observation/action
steps without source-specific interpretation.

### Phase D: Quality And Review

Deliver:

- modality profiles for rate, jitter, dropout, decode, dimensions, ranges,
  stuck values, duplicates, action/state lag, and calibration validity
- quarantine and repair transitions
- review assignment, decision, audit, and synchronized replay UI

Exit: blocked episodes expose an actionable rule and cannot enter an accepted
version until repaired or explicitly reviewed.

### Phase E: Training And Closed Loop

Deliver:

- LeRobot v3 materialization with Parquet, MP4, metadata, tasks, statistics,
  deterministic splits, and verification
- RLDS-compatible episode/step projection
- deployment links for policy version, task, outcome, intervention, and failure
- recollection and active-learning queues

Exit: a validated MoonData version can produce a reproducible training dataset,
and deployment outcomes can select the next collection work.

## External Reference Points

- [ROS 2 bag recording](https://docs.ros.org/en/kilted/Tutorials/Beginner-CLI-Tools/Recording-And-Playing-Back-Data/Recording-And-Playing-Back-Data.html)
  and [MCAP](https://mcap.dev/guides/cli) define the expected capture, split,
  indexing, compression, and recovery behavior.
- [LeRobot Dataset v3](https://huggingface.co/docs/lerobot/en/lerobot-dataset-v3)
  is the first training-native output target.
- [RLDS](https://github.com/google-research/rlds) provides explicit episode
  and step semantics.
- [Open X-Embodiment](https://arxiv.org/abs/2310.08864) and
  [DROID](https://arxiv.org/abs/2403.12945) demonstrate the need for cross-robot
  schemas, calibration, synchronized camera views, task language, and outcome
  metadata.
- [OpenLineage](https://openlineage.io/apidocs/openapi/) provides a useful
  interoperability model for run, job, and dataset events.

These are reference points for architecture and contracts. MoonData remains an
independent implementation and does not make any of these systems its source of
truth.
