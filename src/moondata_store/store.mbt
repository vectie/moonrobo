///|
pub(all) struct MoonDataStoreIssue {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataStoreInit {
  root : String
  created_dir_count : Int
  directories : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PersistedManifest {
  artifact_kind : String
  artifact_id : String
  path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(code : String, path : String, message : String) -> MoonDataStoreIssue {
  { code, path, message }
}

///|
fn join(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
pub fn source_path(
  root : String,
  source_id : @moondata_core.SourceId,
) -> String {
  join(root, "sources/\{source_id}.json")
}

///|
pub fn capture_path(
  root : String,
  capture_id : @moondata_core.CaptureId,
) -> String {
  join(root, "captures/\{capture_id}.json")
}

///|
pub fn dataset_path(
  root : String,
  dataset_id : @moondata_core.DatasetId,
) -> String {
  dataset_kind_path(root, "canonical", dataset_id)
}

///|
pub fn dataset_kind_path(
  root : String,
  kind : String,
  dataset_id : @moondata_core.DatasetId,
) -> String {
  let folder = match kind {
    "raw" => "raw"
    "curated" => "curated"
    _ => "canonical"
  }
  join(root, "datasets/\{folder}/\{dataset_id}.json")
}

///|
pub fn episode_path(
  root : String,
  episode_id : @moondata_core.EpisodeId,
) -> String {
  join(root, "episodes/\{episode_id}.json")
}

///|
pub fn frame_path(root : String, frame_id : @moondata_core.FrameId) -> String {
  join(root, "frames/\{frame_id}.json")
}

///|
pub fn signal_path(root : String, series_id : String) -> String {
  join(root, "signals/\{series_id}.json")
}

///|
pub fn robot_model_path(
  root : String,
  model_id : @moondata_core.RobotModelId,
) -> String {
  join(root, "robot_models/\{model_id}.json")
}

///|
pub fn quality_run_path(
  root : String,
  quality_run_id : @moondata_core.QualityRunId,
) -> String {
  join(root, "quality/\{quality_run_id}.json")
}

///|
pub fn lineage_path(root : String, lineage_id : String) -> String {
  join(root, "lineage/\{lineage_id}.json")
}

///|
pub fn transform_run_path(
  root : String,
  transform_run_id : @moondata_core.TransformRunId,
) -> String {
  join(root, "transforms/\{transform_run_id}.json")
}

///|
pub fn dataset_version_path(
  root : String,
  version_id : @moondata_core.DatasetVersionId,
) -> String {
  join(root, "versions/\{version_id}.json")
}

///|
pub fn annotation_set_path(
  root : String,
  annotation_set_id : @moondata_core.AnnotationSetId,
) -> String {
  join(root, "annotations/\{annotation_set_id}.json")
}

///|
pub fn annotation_target_index_path(
  root : String,
  annotation_index_id : @moondata_core.AnnotationTargetIndexId,
) -> String {
  join(root, "annotation_indexes/\{annotation_index_id}.json")
}

///|
pub fn replay_artifact_path(
  root : String,
  replay_artifact_id : @moondata_core.ReplayArtifactId,
) -> String {
  join(root, "replays/\{replay_artifact_id}.json")
}

///|
pub fn export_manifest_path(
  root : String,
  export_manifest_id : @moondata_core.ExportManifestId,
) -> String {
  join(root, "exports/\{export_manifest_id}.json")
}

///|
pub fn validation_report_path(
  root : String,
  validation_report_id : String,
) -> String {
  join(root, "validations/\{validation_report_id}.json")
}

///|
pub fn handoff_dossier_path(
  root : String,
  handoff_dossier_id : @moondata_core.HandoffDossierId,
) -> String {
  join(root, "handoffs/\{handoff_dossier_id}.json")
}

///|
pub fn repair_run_path(
  root : String,
  repair_run_id : @moondata_core.RepairRunId,
) -> String {
  join(root, "repairs/\{repair_run_id}.json")
}

///|
pub fn repair_receipt_path(
  root : String,
  repair_receipt_id : @moondata_core.RepairReceiptId,
) -> String {
  join(root, "repair_receipts/\{repair_receipt_id}.json")
}

///|
pub fn catalog_path(root : String) -> String {
  join(root, "indexes/catalog.json")
}

///|
fn ensure_dir(path : String) -> Result[Bool, MoonDataStoreIssue] {
  if @fsx.path_exists(path) {
    Ok(false)
  } else {
    @fsx.create_dir(path) catch {
      _ =>
        return Err(
          issue("create-dir", path, "failed to create MoonData directory"),
        )
    }
    Ok(true)
  }
}

///|
pub fn initialize_root(
  root : String,
) -> Result[MoonDataStoreInit, MoonDataStoreIssue] {
  let dirs = [
    "", "sources", "captures", "datasets", "datasets/raw", "datasets/canonical",
    "datasets/curated", "episodes", "frames", "signals", "robot_models", "media",
    "media/imports", "media/robot_models", "indexes", "quality", "annotations", "annotation_indexes",
    "transforms", "versions", "replays", "exports", "lineage", "validations", "handoffs",
    "repairs", "repair_receipts", "runs", "runs/pipelines", "runs/recorders", "incoming",
    "logs", "logs/recorders", "blobs", "blobs/sha256",
  ]
  let created : Array[String] = []
  for relative in dirs {
    let path = if relative == "" { root } else { join(root, relative) }
    match ensure_dir(path) {
      Ok(value) => if value { created.push(path) }
      Err(error) => return Err(error)
    }
  }
  Ok({ root, created_dir_count: created.length(), directories: created })
}

///|
fn write_json(
  path : String,
  artifact_kind : String,
  artifact_id : String,
  body : Json,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  @fsx.write_string_to_file(path, body.stringify(indent=2)) catch {
    _ =>
      return Err(
        issue("write-manifest", path, "failed to write MoonData manifest"),
      )
  }
  Ok({ artifact_kind, artifact_id, path })
}

///|
fn read_json(path : String) -> Result[Json, MoonDataStoreIssue] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        issue("read-manifest", path, "failed to read MoonData manifest"),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        issue("parse-manifest", path, "failed to parse MoonData manifest"),
      )
  }
  Ok(json)
}

///|
pub fn read_source(
  root : String,
  source_id : @moondata_core.SourceId,
) -> Result[@moondata_core.DataSource, MoonDataStoreIssue] {
  let path = source_path(root, source_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source : @moondata_core.DataSource = @json.from_json(json) catch {
    _ =>
      return Err(issue("decode-source", path, "failed to decode data source"))
  }
  Ok(source)
}

///|
pub fn write_source(
  root : String,
  source : @moondata_core.DataSource,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    source_path(root, source.source_id),
    "source",
    source.source_id,
    source.to_json(),
  )
}

///|
pub fn write_capture(
  root : String,
  capture : @moondata_core.CaptureSession,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    capture_path(root, capture.capture_id),
    "capture",
    capture.capture_id,
    capture.to_json(),
  )
}

///|
pub fn write_dataset(
  root : String,
  dataset : @moondata_core.DatasetManifest,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    dataset_kind_path(root, dataset.kind, dataset.dataset_id),
    "dataset",
    dataset.dataset_id,
    dataset.to_json(),
  )
}

///|
pub fn write_episode(
  root : String,
  episode : @moondata_core.EpisodeManifest,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    episode_path(root, episode.episode_id),
    "episode",
    episode.episode_id,
    episode.to_json(),
  )
}

///|
pub fn write_frame(
  root : String,
  frame : @moondata_core.FrameRef,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    frame_path(root, frame.frame_id),
    "frame",
    frame.frame_id,
    frame.to_json(),
  )
}

///|
pub fn write_signal_series(
  root : String,
  series : @moondata_core.SignalSeries,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    signal_path(root, series.series_id),
    "signal-series",
    series.series_id,
    series.to_json(),
  )
}

///|
pub fn write_robot_model(
  root : String,
  model : @moondata_core.RobotModelManifest,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    robot_model_path(root, model.model_id),
    "robot-model",
    model.model_id,
    model.to_json(),
  )
}

///|
pub fn write_quality_run(
  root : String,
  run : @moondata_core.QualityRun,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    quality_run_path(root, run.quality_run_id),
    "quality-run",
    run.quality_run_id,
    run.to_json(),
  )
}

///|
pub fn write_lineage_manifest(
  root : String,
  lineage : @moondata_core.LineageManifest,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    lineage_path(root, lineage.lineage_id),
    "lineage",
    lineage.lineage_id,
    lineage.to_json(),
  )
}

///|
pub fn write_transform_run(
  root : String,
  run : @moondata_core.TransformRun,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    transform_run_path(root, run.transform_run_id),
    "transform-run",
    run.transform_run_id,
    run.to_json(),
  )
}

///|
pub fn write_dataset_version(
  root : String,
  version : @moondata_core.DatasetVersion,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    dataset_version_path(root, version.version_id),
    "dataset-version",
    version.version_id,
    version.to_json(),
  )
}

///|
pub fn write_annotation_set(
  root : String,
  set : @moondata_core.AnnotationSet,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    annotation_set_path(root, set.annotation_set_id),
    "annotation-set",
    set.annotation_set_id,
    set.to_json(),
  )
}

///|
pub fn write_annotation_target_index(
  root : String,
  index : @moondata_core.AnnotationTargetIndex,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    annotation_target_index_path(root, index.annotation_index_id),
    "annotation-target-index",
    index.annotation_index_id,
    index.to_json(),
  )
}

///|
pub fn write_replay_artifact(
  root : String,
  artifact : @moondata_core.ReplayArtifact,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    replay_artifact_path(root, artifact.replay_artifact_id),
    "replay-artifact",
    artifact.replay_artifact_id,
    artifact.to_json(),
  )
}

///|
pub fn write_export_manifest(
  root : String,
  manifest : @moondata_core.ExportManifest,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    export_manifest_path(root, manifest.export_manifest_id),
    "export-manifest",
    manifest.export_manifest_id,
    manifest.to_json(),
  )
}

///|
pub fn write_validation_report(
  root : String,
  report : @moondata_core.ValidationReport,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    validation_report_path(root, report.validation_report_id),
    "validation-report",
    report.validation_report_id,
    report.to_json(),
  )
}

///|
pub fn write_handoff_dossier(
  root : String,
  dossier : @moondata_core.HandoffDossier,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    handoff_dossier_path(root, dossier.handoff_dossier_id),
    "handoff-dossier",
    dossier.handoff_dossier_id,
    dossier.to_json(),
  )
}

///|
pub fn write_repair_run(
  root : String,
  run : @moondata_core.RepairRun,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    repair_run_path(root, run.repair_run_id),
    "repair-run",
    run.repair_run_id,
    run.to_json(),
  )
}

///|
pub fn write_repair_receipt(
  root : String,
  receipt : @moondata_core.RepairReceipt,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    repair_receipt_path(root, receipt.repair_receipt_id),
    "repair-receipt",
    receipt.repair_receipt_id,
    receipt.to_json(),
  )
}

///|
pub fn write_catalog(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
) -> Result[PersistedManifest, MoonDataStoreIssue] {
  write_json(
    catalog_path(root),
    "catalog",
    catalog.catalog_id,
    catalog.to_json(),
  )
}

///|
fn read_dataset_at(
  path : String,
) -> Result[@moondata_core.DatasetManifest, MoonDataStoreIssue] {
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dataset : @moondata_core.DatasetManifest = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-dataset", path, "failed to decode dataset manifest"),
      )
  }
  Ok(dataset)
}

///|
pub fn read_dataset(
  root : String,
  dataset_id : @moondata_core.DatasetId,
) -> Result[@moondata_core.DatasetManifest, MoonDataStoreIssue] {
  read_dataset_at(dataset_path(root, dataset_id))
}

///|
pub fn read_dataset_kind(
  root : String,
  kind : String,
  dataset_id : @moondata_core.DatasetId,
) -> Result[@moondata_core.DatasetManifest, MoonDataStoreIssue] {
  read_dataset_at(dataset_kind_path(root, kind, dataset_id))
}

///|
pub fn read_raw_dataset(
  root : String,
  dataset_id : @moondata_core.DatasetId,
) -> Result[@moondata_core.DatasetManifest, MoonDataStoreIssue] {
  read_dataset_kind(root, "raw", dataset_id)
}

///|
pub fn read_catalog(
  root : String,
) -> Result[@moondata_core.MoonDataCatalog, MoonDataStoreIssue] {
  let path = catalog_path(root)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let catalog : @moondata_core.MoonDataCatalog = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-catalog", path, "failed to decode MoonData catalog"),
      )
  }
  Ok(catalog)
}

///|
pub fn read_capture(
  root : String,
  capture_id : @moondata_core.CaptureId,
) -> Result[@moondata_core.CaptureSession, MoonDataStoreIssue] {
  let path = capture_path(root, capture_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let capture : @moondata_core.CaptureSession = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-capture", path, "failed to decode capture manifest"),
      )
  }
  Ok(capture)
}

///|
pub fn read_curated_dataset(
  root : String,
  dataset_id : @moondata_core.DatasetId,
) -> Result[@moondata_core.DatasetManifest, MoonDataStoreIssue] {
  let path = dataset_kind_path(root, "curated", dataset_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dataset : @moondata_core.DatasetManifest = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-dataset", path, "failed to decode dataset manifest"),
      )
  }
  Ok(dataset)
}

///|
pub fn read_episode(
  root : String,
  episode_id : @moondata_core.EpisodeId,
) -> Result[@moondata_core.EpisodeManifest, MoonDataStoreIssue] {
  let path = episode_path(root, episode_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let episode : @moondata_core.EpisodeManifest = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-episode", path, "failed to decode episode manifest"),
      )
  }
  Ok(episode)
}

///|
pub fn read_frame(
  root : String,
  frame_id : @moondata_core.FrameId,
) -> Result[@moondata_core.FrameRef, MoonDataStoreIssue] {
  let path = frame_path(root, frame_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let frame : @moondata_core.FrameRef = @json.from_json(json) catch {
    _ =>
      return Err(issue("decode-frame", path, "failed to decode frame manifest"))
  }
  Ok(frame)
}

///|
pub fn read_signal_series(
  root : String,
  series_id : String,
) -> Result[@moondata_core.SignalSeries, MoonDataStoreIssue] {
  let path = signal_path(root, series_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let series : @moondata_core.SignalSeries = @json.from_json(json) catch {
    _ =>
      return Err(issue("decode-signal", path, "failed to decode signal series"))
  }
  Ok(series)
}

///|
pub fn read_robot_model(
  root : String,
  model_id : @moondata_core.RobotModelId,
) -> Result[@moondata_core.RobotModelManifest, MoonDataStoreIssue] {
  let path = robot_model_path(root, model_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let model : @moondata_core.RobotModelManifest = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-robot-model", path, "failed to decode robot model manifest",
        ),
      )
  }
  Ok(model)
}

///|
pub fn read_quality_run(
  root : String,
  quality_run_id : @moondata_core.QualityRunId,
) -> Result[@moondata_core.QualityRun, MoonDataStoreIssue] {
  let path = quality_run_path(root, quality_run_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let run : @moondata_core.QualityRun = @json.from_json(json) catch {
    _ =>
      return Err(issue("decode-quality", path, "failed to decode quality run"))
  }
  Ok(run)
}

///|
pub fn read_lineage_manifest(
  root : String,
  lineage_id : String,
) -> Result[@moondata_core.LineageManifest, MoonDataStoreIssue] {
  let path = lineage_path(root, lineage_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lineage : @moondata_core.LineageManifest = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-lineage", path, "failed to decode lineage manifest"),
      )
  }
  Ok(lineage)
}

///|
pub fn read_transform_run(
  root : String,
  transform_run_id : @moondata_core.TransformRunId,
) -> Result[@moondata_core.TransformRun, MoonDataStoreIssue] {
  let path = transform_run_path(root, transform_run_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let run : @moondata_core.TransformRun = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-transform", path, "failed to decode transform run"),
      )
  }
  Ok(run)
}

///|
pub fn read_dataset_version(
  root : String,
  version_id : @moondata_core.DatasetVersionId,
) -> Result[@moondata_core.DatasetVersion, MoonDataStoreIssue] {
  let path = dataset_version_path(root, version_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let version : @moondata_core.DatasetVersion = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-version", path, "failed to decode dataset version"),
      )
  }
  Ok(version)
}

///|
pub fn read_annotation_set(
  root : String,
  annotation_set_id : @moondata_core.AnnotationSetId,
) -> Result[@moondata_core.AnnotationSet, MoonDataStoreIssue] {
  let path = annotation_set_path(root, annotation_set_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let set : @moondata_core.AnnotationSet = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-annotation", path, "failed to decode annotation set"),
      )
  }
  Ok(set)
}

///|
pub fn read_annotation_target_index(
  root : String,
  annotation_index_id : @moondata_core.AnnotationTargetIndexId,
) -> Result[@moondata_core.AnnotationTargetIndex, MoonDataStoreIssue] {
  let path = annotation_target_index_path(root, annotation_index_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let index : @moondata_core.AnnotationTargetIndex = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-annotation-target-index", path, "failed to decode annotation target index",
        ),
      )
  }
  Ok(index)
}

///|
pub fn read_replay_artifact(
  root : String,
  replay_artifact_id : @moondata_core.ReplayArtifactId,
) -> Result[@moondata_core.ReplayArtifact, MoonDataStoreIssue] {
  let path = replay_artifact_path(root, replay_artifact_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let artifact : @moondata_core.ReplayArtifact = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-replay", path, "failed to decode replay artifact"),
      )
  }
  Ok(artifact)
}

///|
pub fn read_export_manifest(
  root : String,
  export_manifest_id : @moondata_core.ExportManifestId,
) -> Result[@moondata_core.ExportManifest, MoonDataStoreIssue] {
  let path = export_manifest_path(root, export_manifest_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let manifest : @moondata_core.ExportManifest = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-export", path, "failed to decode export manifest"),
      )
  }
  Ok(manifest)
}

///|
pub fn read_validation_report(
  root : String,
  validation_report_id : String,
) -> Result[@moondata_core.ValidationReport, MoonDataStoreIssue] {
  let path = validation_report_path(root, validation_report_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let report : @moondata_core.ValidationReport = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-validation", path, "failed to decode validation report"),
      )
  }
  Ok(report)
}

///|
pub fn read_handoff_dossier(
  root : String,
  handoff_dossier_id : @moondata_core.HandoffDossierId,
) -> Result[@moondata_core.HandoffDossier, MoonDataStoreIssue] {
  let path = handoff_dossier_path(root, handoff_dossier_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dossier : @moondata_core.HandoffDossier = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-handoff", path, "failed to decode handoff dossier manifest",
        ),
      )
  }
  Ok(dossier)
}

///|
pub fn read_repair_run(
  root : String,
  repair_run_id : @moondata_core.RepairRunId,
) -> Result[@moondata_core.RepairRun, MoonDataStoreIssue] {
  let path = repair_run_path(root, repair_run_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let run : @moondata_core.RepairRun = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-repair", path, "failed to decode repair run manifest"),
      )
  }
  Ok(run)
}

///|
pub fn read_repair_receipt(
  root : String,
  repair_receipt_id : @moondata_core.RepairReceiptId,
) -> Result[@moondata_core.RepairReceipt, MoonDataStoreIssue] {
  let path = repair_receipt_path(root, repair_receipt_id)
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt : @moondata_core.RepairReceipt = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-repair-receipt", path, "failed to decode repair receipt manifest",
        ),
      )
  }
  Ok(receipt)
}
