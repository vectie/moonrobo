///|
pub(all) struct CatalogRebuild {
  root : String
  catalog_path : String
  generated_at_ms : Int64
  entry_count : Int
  catalog : @moondata_core.MoonDataCatalog
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AnnotationTargetIndexRebuild {
  root : String
  generated_at_ms : Int64
  annotation_count : Int
  annotation_index_count : Int
  indexes : Array[@moondata_store.PersistedManifest]
  catalog_path : String
  catalog_entry_count : Int
  catalog : @moondata_core.MoonDataCatalog
} derive(Debug, Eq, ToJson, FromJson)

///|
struct ManifestSpec {
  dir : String
  artifact_kind : String
} derive(Debug, Eq)

///|
fn issue(
  code : String,
  path : String,
  message : String,
) -> @moondata_store.MoonDataStoreIssue {
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
fn push_unique(values : Array[String], value : String) -> Unit {
  for candidate in values {
    if candidate == value {
      return
    }
  }
  values.push(value)
}

///|
fn label_keys(labels : Array[@moondata_core.AnnotationLabel]) -> Array[String] {
  let keys : Array[String] = []
  for label in labels {
    push_unique(keys, label.key)
  }
  keys
}

///|
fn label_values(
  labels : Array[@moondata_core.AnnotationLabel],
) -> Array[String] {
  let values : Array[String] = []
  for label in labels {
    push_unique(values, label.value)
  }
  values
}

///|
fn target_index_from_annotation(
  set : @moondata_core.AnnotationSet,
) -> @moondata_core.AnnotationTargetIndex {
  @moondata_core.annotation_target_index(
    @moondata_annotation.annotation_target_index_id(set.annotation_set_id),
    set.annotation_set_id,
    set.target_refs,
    set.reviewer,
    set.status,
    set.created_at_ms,
    label_keys=label_keys(set.labels),
    label_values=label_values(set.labels),
    summary=set.summary,
  )
}

///|
fn specs() -> Array[ManifestSpec] {
  [
    { dir: "sources", artifact_kind: "source" },
    { dir: "captures", artifact_kind: "capture" },
    { dir: "datasets/raw", artifact_kind: "dataset" },
    { dir: "datasets/canonical", artifact_kind: "dataset" },
    { dir: "datasets/curated", artifact_kind: "dataset" },
    { dir: "episodes", artifact_kind: "episode" },
    { dir: "frames", artifact_kind: "frame" },
    { dir: "signals", artifact_kind: "signal-series" },
    { dir: "quality", artifact_kind: "quality-run" },
    { dir: "transforms", artifact_kind: "transform-run" },
    { dir: "versions", artifact_kind: "dataset-version" },
    { dir: "annotations", artifact_kind: "annotation-set" },
    { dir: "annotation_indexes", artifact_kind: "annotation-target-index" },
    { dir: "replays", artifact_kind: "replay-artifact" },
    { dir: "exports", artifact_kind: "export-manifest" },
    { dir: "lineage", artifact_kind: "lineage" },
    { dir: "validations", artifact_kind: "validation-report" },
    { dir: "handoffs", artifact_kind: "handoff-dossier" },
  ]
}

///|
fn remove_annotation_index_files(
  root : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  let dir = join(root, "annotation_indexes")
  if !@fsx.path_exists(dir) {
    return Ok(())
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue(
          "read-annotation-index-dir", dir, "failed to read annotation target index directory",
        ),
      )
  }
  for name in names {
    if name.has_suffix(".json") {
      let path = join(dir, name)
      @fsx.remove_file(path) catch {
        _ =>
          return Err(
            issue(
              "remove-annotation-index", path, "failed to remove stale annotation target index",
            ),
          )
      }
    }
  }
  Ok(())
}

///|
fn read_annotation_sets(
  root : String,
) -> Result[
  Array[@moondata_core.AnnotationSet],
  @moondata_store.MoonDataStoreIssue,
] {
  let dir = join(root, "annotations")
  let annotations : Array[@moondata_core.AnnotationSet] = []
  if !@fsx.path_exists(dir) {
    return Ok(annotations)
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue("read-annotation-dir", dir, "failed to read annotation directory"),
      )
  }
  names.sort()
  for name in names {
    if name.has_suffix(".json") {
      let path = join(dir, name)
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
      annotations.push(set)
    }
  }
  Ok(annotations)
}

///|
fn read_json(path : String) -> Result[Json, @moondata_store.MoonDataStoreIssue] {
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
fn decode_source(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.DataSource = @json.from_json(json) catch {
    _ => return Err(issue("decode-source", path, "failed to decode source"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "source",
      value.source_id,
      path,
      status=value.kind,
      summary=value.label,
    ),
  )
}

///|
fn decode_capture(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.CaptureSession = @json.from_json(json) catch {
    _ => return Err(issue("decode-capture", path, "failed to decode capture"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "capture",
      value.capture_id,
      path,
      status=value.status,
      summary="\{value.robot_id}/\{value.bridge_id}",
    ),
  )
}

///|
fn decode_dataset(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.DatasetManifest = @json.from_json(json) catch {
    _ => return Err(issue("decode-dataset", path, "failed to decode dataset"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "dataset",
      value.dataset_id,
      path,
      status=value.status,
      summary="\{value.kind} dataset with \{value.episode_ids.length()} episode(s)",
    ),
  )
}

///|
fn decode_episode(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.EpisodeManifest = @json.from_json(json) catch {
    _ => return Err(issue("decode-episode", path, "failed to decode episode"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "episode",
      value.episode_id,
      path,
      status=value.status,
      summary="\{value.robot_id} episode with \{value.frame_count} frame(s)",
    ),
  )
}

///|
fn decode_frame(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.FrameRef = @json.from_json(json) catch {
    _ => return Err(issue("decode-frame", path, "failed to decode frame"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "frame",
      value.frame_id,
      path,
      summary="episode \{value.episode_id} frame \{value.sequence_index}",
    ),
  )
}

///|
fn decode_signal(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.SignalSeries = @json.from_json(json) catch {
    _ => return Err(issue("decode-signal", path, "failed to decode signal"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "signal-series",
      value.series_id,
      path,
      summary="\{value.field_path} \{value.sample_count} sample(s)",
    ),
  )
}

///|
fn decode_quality(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.QualityRun = @json.from_json(json) catch {
    _ =>
      return Err(issue("decode-quality", path, "failed to decode quality run"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "quality-run",
      value.quality_run_id,
      path,
      status=value.status,
      summary="\{value.finding_count} finding(s)",
    ),
  )
}

///|
fn decode_transform(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.TransformRun = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-transform", path, "failed to decode transform run"),
      )
  }
  Ok(
    @moondata_core.catalog_entry(
      "transform-run",
      value.transform_run_id,
      path,
      status=value.status,
      summary=value.summary,
    ),
  )
}

///|
fn decode_version(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.DatasetVersion = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-version", path, "failed to decode dataset version"),
      )
  }
  Ok(
    @moondata_core.catalog_entry(
      "dataset-version",
      value.version_id,
      path,
      status=value.status,
      summary=value.summary,
    ),
  )
}

///|
fn decode_annotation(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.AnnotationSet = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-annotation", path, "failed to decode annotation set"),
      )
  }
  Ok(
    @moondata_core.catalog_entry(
      "annotation-set",
      value.annotation_set_id,
      path,
      status=value.status,
      summary=value.summary,
    ),
  )
}

///|
fn decode_annotation_target_index(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.AnnotationTargetIndex = @json.from_json(json) catch {
    _ =>
      return Err(
        issue(
          "decode-annotation-target-index", path, "failed to decode annotation target index",
        ),
      )
  }
  Ok(
    @moondata_core.catalog_entry(
      "annotation-target-index",
      value.annotation_index_id,
      path,
      status=value.status,
      summary=value.summary,
    ),
  )
}

///|
fn decode_replay(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.ReplayArtifact = @json.from_json(json) catch {
    _ => return Err(issue("decode-replay", path, "failed to decode replay"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "replay-artifact",
      value.replay_artifact_id,
      path,
      summary=value.summary,
    ),
  )
}

///|
fn decode_export(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.ExportManifest = @json.from_json(json) catch {
    _ => return Err(issue("decode-export", path, "failed to decode export"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "export-manifest",
      value.export_manifest_id,
      path,
      status=value.status,
      summary=value.report,
    ),
  )
}

///|
fn decode_lineage(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.LineageManifest = @json.from_json(json) catch {
    _ => return Err(issue("decode-lineage", path, "failed to decode lineage"))
  }
  Ok(
    @moondata_core.catalog_entry(
      "lineage",
      value.lineage_id,
      path,
      summary="root dataset \{value.root_dataset_id}",
    ),
  )
}

///|
fn decode_validation(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.ValidationReport = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-validation", path, "failed to decode validation report"),
      )
  }
  Ok(
    @moondata_core.catalog_entry(
      "validation-report",
      value.validation_report_id,
      path,
      status=value.status,
      summary="\{value.finding_count} validation finding(s)",
    ),
  )
}

///|
fn decode_handoff(
  path : String,
  json : Json,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let value : @moondata_core.HandoffDossier = @json.from_json(json) catch {
    _ =>
      return Err(
        issue("decode-handoff", path, "failed to decode handoff dossier"),
      )
  }
  Ok(
    @moondata_core.catalog_entry(
      "handoff-dossier",
      value.handoff_dossier_id,
      path,
      status=value.source_readiness_status,
      summary=value.summary,
    ),
  )
}

///|
fn decode_entry(
  artifact_kind : String,
  path : String,
) -> Result[@moondata_core.CatalogEntry, @moondata_store.MoonDataStoreIssue] {
  let json = match read_json(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match artifact_kind {
    "source" => decode_source(path, json)
    "capture" => decode_capture(path, json)
    "dataset" => decode_dataset(path, json)
    "episode" => decode_episode(path, json)
    "frame" => decode_frame(path, json)
    "signal-series" => decode_signal(path, json)
    "quality-run" => decode_quality(path, json)
    "transform-run" => decode_transform(path, json)
    "dataset-version" => decode_version(path, json)
    "annotation-set" => decode_annotation(path, json)
    "annotation-target-index" => decode_annotation_target_index(path, json)
    "replay-artifact" => decode_replay(path, json)
    "export-manifest" => decode_export(path, json)
    "lineage" => decode_lineage(path, json)
    "validation-report" => decode_validation(path, json)
    "handoff-dossier" => decode_handoff(path, json)
    _ =>
      Err(
        issue(
          "unknown-artifact-kind",
          path,
          "cannot rebuild catalog entry for artifact kind \{artifact_kind}",
        ),
      )
  }
}

///|
fn append_dir_entries(
  entries : Array[@moondata_core.CatalogEntry],
  root : String,
  spec : ManifestSpec,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  let dir = join(root, spec.dir)
  if !@fsx.path_exists(dir) {
    return Ok(())
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        issue("read-manifest-dir", dir, "failed to read manifest directory"),
      )
  }
  names.sort()
  for name in names {
    if name.has_suffix(".json") {
      let entry = match decode_entry(spec.artifact_kind, join(dir, name)) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      entries.push(entry)
    }
  }
  Ok(())
}

///|
pub fn build_catalog(
  root : String,
  generated_at_ms : Int64,
) -> Result[@moondata_core.MoonDataCatalog, @moondata_store.MoonDataStoreIssue] {
  let entries : Array[@moondata_core.CatalogEntry] = []
  for spec in specs() {
    match append_dir_entries(entries, root, spec) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(@moondata_core.moondata_catalog(root, generated_at_ms, entries))
}

///|
pub fn rebuild_catalog(
  root : String,
  generated_at_ms : Int64,
) -> Result[CatalogRebuild, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let catalog = match build_catalog(root, generated_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let persisted = match @moondata_store.write_catalog(root, catalog) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root,
    catalog_path: persisted.path,
    generated_at_ms,
    entry_count: catalog.entry_count,
    catalog,
  })
}

///|
pub fn rebuild_annotation_target_indexes(
  root : String,
  generated_at_ms : Int64,
) -> Result[AnnotationTargetIndexRebuild, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match remove_annotation_index_files(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let annotations = match read_annotation_sets(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let persisted_indexes : Array[@moondata_store.PersistedManifest] = []
  for annotation in annotations {
    let index = target_index_from_annotation(annotation)
    let persisted = match
      @moondata_store.write_annotation_target_index(root, index) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    persisted_indexes.push(persisted)
  }
  let catalog_rebuild = match rebuild_catalog(root, generated_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root,
    generated_at_ms,
    annotation_count: annotations.length(),
    annotation_index_count: persisted_indexes.length(),
    indexes: persisted_indexes,
    catalog_path: catalog_rebuild.catalog_path,
    catalog_entry_count: catalog_rebuild.entry_count,
    catalog: catalog_rebuild.catalog,
  })
}
