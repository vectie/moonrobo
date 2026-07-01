///|
pub(all) struct StoredExportRequest {
  root : String
  version_id : @moondata_core.DatasetVersionId
  export_manifest_id : @moondata_core.ExportManifestId
  target_format : String
  field_mapping : String
  output_uri : String
  created_at_ms : Int64
  report : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StoredExportResult {
  root : String
  version_id : @moondata_core.DatasetVersionId
  dataset_id : @moondata_core.DatasetId
  export_manifest_id : @moondata_core.ExportManifestId
  target_format : String
  output_uri : String
  output_path : String
  output_record_count : Int
  output_byte_count : Int64
  output_checksum : String
  quality_run_count : Int
  catalog_path : String
  catalog_entry_count : Int
  manifest : @moondata_core.ExportManifest
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct ExportFrameRecord {
  version_id : @moondata_core.DatasetVersionId
  dataset_id : @moondata_core.DatasetId
  episode_id : @moondata_core.EpisodeId
  frame_id : @moondata_core.FrameId
  sequence_index : Int
  captured_at_ms : Int64
  payload_ref : @moondata_core.DataRef?
} derive(ToJson)

///|
pub fn stored_export_request(
  root : String,
  version_id : @moondata_core.DatasetVersionId,
  created_at_ms : Int64,
  export_manifest_id? : @moondata_core.ExportManifestId = "",
  target_format? : String = "jsonl",
  field_mapping? : String = "{\"dataset_id\":\"version.dataset_id\",\"episodes\":\"version.accepted_episode_ids\"}",
  output_uri? : String = "",
  report? : String = "stored MoonData export manifest",
) -> StoredExportRequest {
  let export_id = if export_manifest_id == "" {
    "export-\{version_id}"
  } else {
    export_manifest_id
  }
  let output = if output_uri == "" {
    @moondata_core.moondata_uri("exports/\{export_id}.\{target_format}")
  } else {
    output_uri
  }
  {
    root,
    version_id,
    export_manifest_id: export_id,
    target_format,
    field_mapping,
    output_uri: output,
    created_at_ms,
    report,
  }
}

///|
fn issue(
  code : String,
  path : String,
  message : String,
) -> @moondata_store.MoonDataStoreIssue {
  { code, path, message }
}

///|
fn contains_episode(
  ids : Array[@moondata_core.EpisodeId],
  episode_id : @moondata_core.EpisodeId,
) -> Bool {
  for id in ids {
    if id == episode_id {
      return true
    }
  }
  false
}

///|
fn content_type(target_format : String) -> String {
  match target_format {
    "jsonl" => "application/jsonl"
    "json" => "application/json"
    "csv" => "text/csv"
    "parquet" => "application/vnd.apache.parquet"
    _ => "application/octet-stream"
  }
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
fn output_path(
  root : String,
  output_uri : String,
) -> Result[String, @moondata_store.MoonDataStoreIssue] {
  match output_uri.strip_prefix("moondata://exports/") {
    Some(relative) => {
      let name = relative.to_owned()
      if name == "" || name.contains("/") {
        return Err(
          issue(
            "export-output-path-unsupported", output_uri, "export output uri must point to a direct child of moondata://exports/",
          ),
        )
      }
      Ok(join(root, "exports/\{name}"))
    }
    None =>
      Err(
        issue(
          "export-output-nonlocal", output_uri, "export output uri must stay inside the MoonData root",
        ),
      )
  }
}

///|
fn verify_version(
  root : String,
  version_id : @moondata_core.DatasetVersionId,
) -> Result[@moondata_core.DatasetVersion, @moondata_store.MoonDataStoreIssue] {
  let version = match @moondata_store.read_dataset_version(root, version_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if version.status != "accepted" {
    return Err(
      issue(
        "export-version-not-accepted",
        @moondata_store.dataset_version_path(root, version.version_id),
        "export input version status is \{version.status}, expected accepted",
      ),
    )
  }
  if version.accepted_episode_ids.length() == 0 {
    return Err(
      issue(
        "export-version-empty",
        @moondata_store.dataset_version_path(root, version.version_id),
        "export input version has no accepted episodes",
      ),
    )
  }
  if version.quality_run_ids.length() == 0 {
    return Err(
      issue(
        "export-version-missing-quality",
        @moondata_store.dataset_version_path(root, version.version_id),
        "export input version has no quality gate",
      ),
    )
  }
  Ok(version)
}

///|
fn verify_curated_dataset(
  root : String,
  version : @moondata_core.DatasetVersion,
) -> Result[@moondata_core.DatasetManifest, @moondata_store.MoonDataStoreIssue] {
  let dataset = match
    @moondata_store.read_curated_dataset(root, version.dataset_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if dataset.kind != "curated" {
    return Err(
      issue(
        "export-dataset-not-curated",
        @moondata_store.dataset_kind_path(
          root,
          dataset.kind,
          dataset.dataset_id,
        ),
        "export input dataset must be curated",
      ),
    )
  }
  for episode_id in version.accepted_episode_ids {
    if !contains_episode(dataset.episode_ids, episode_id) {
      return Err(
        issue(
          "export-version-dataset-episode-mismatch",
          @moondata_store.dataset_version_path(root, version.version_id),
          "accepted episode \{episode_id} is not in curated dataset",
        ),
      )
    }
  }
  Ok(dataset)
}

///|
fn verify_quality_runs(
  root : String,
  version : @moondata_core.DatasetVersion,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  for quality_run_id in version.quality_run_ids {
    let quality = match @moondata_store.read_quality_run(root, quality_run_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if quality.status != "passed" {
      return Err(
        issue(
          "export-quality-not-passed",
          @moondata_store.quality_run_path(root, quality.quality_run_id),
          "quality run status is \{quality.status}, expected passed",
        ),
      )
    }
  }
  for episode_id in version.accepted_episode_ids {
    let mut covered = false
    for quality_run_id in version.quality_run_ids {
      let quality = match
        @moondata_store.read_quality_run(root, quality_run_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if contains_episode(quality.episode_ids, episode_id) {
        covered = true
      }
    }
    if !covered {
      return Err(
        issue(
          "export-quality-episode-missing",
          @moondata_store.dataset_version_path(root, version.version_id),
          "accepted episode \{episode_id} is not covered by a quality run",
        ),
      )
    }
  }
  Ok(())
}

///|
fn export_records(
  root : String,
  version : @moondata_core.DatasetVersion,
) -> Result[Array[ExportFrameRecord], @moondata_store.MoonDataStoreIssue] {
  let records : Array[ExportFrameRecord] = []
  for episode_id in version.accepted_episode_ids {
    let episode = match @moondata_store.read_episode(root, episode_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    for frame_id in episode.frame_ids {
      let frame = match @moondata_store.read_frame(root, frame_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      records.push({
        version_id: version.version_id,
        dataset_id: version.dataset_id,
        episode_id: episode.episode_id,
        frame_id: frame.frame_id,
        sequence_index: frame.sequence_index,
        captured_at_ms: frame.captured_at_ms,
        payload_ref: frame.payload_ref,
      })
    }
  }
  Ok(records)
}

///|
fn jsonl_body(records : Array[ExportFrameRecord]) -> String {
  let buffer = StringBuilder()
  for record in records {
    buffer.write_string(record.to_json().stringify())
    buffer.write_char('\n')
  }
  buffer.to_string()
}

///|
fn csv_escape(text : String) -> String {
  if text.contains(",") || text.contains("\"") || text.contains("\n") {
    let buffer = StringBuilder()
    buffer.write_char('"')
    for char in text {
      if char == '"' {
        buffer.write_string("\"\"")
      } else {
        buffer.write_char(char)
      }
    }
    buffer.write_char('"')
    buffer.to_string()
  } else {
    text
  }
}

///|
fn payload_uri(payload_ref : @moondata_core.DataRef?) -> String {
  match payload_ref {
    Some(value) => value.uri
    None => ""
  }
}

///|
fn csv_body(records : Array[ExportFrameRecord]) -> String {
  let buffer = StringBuilder()
  buffer.write_string(
    "version_id,dataset_id,episode_id,frame_id,sequence_index,captured_at_ms,payload_uri\n",
  )
  for record in records {
    buffer.write_string(csv_escape(record.version_id))
    buffer.write_char(',')
    buffer.write_string(csv_escape(record.dataset_id))
    buffer.write_char(',')
    buffer.write_string(csv_escape(record.episode_id))
    buffer.write_char(',')
    buffer.write_string(csv_escape(record.frame_id))
    buffer.write_char(',')
    buffer.write_string("\{record.sequence_index}")
    buffer.write_char(',')
    buffer.write_string("\{record.captured_at_ms}")
    buffer.write_char(',')
    buffer.write_string(csv_escape(payload_uri(record.payload_ref)))
    buffer.write_char('\n')
  }
  buffer.to_string()
}

///|
fn export_body(
  target_format : String,
  records : Array[ExportFrameRecord],
) -> Result[String, @moondata_store.MoonDataStoreIssue] {
  match target_format {
    "jsonl" => Ok(jsonl_body(records))
    "csv" => Ok(csv_body(records))
    _ =>
      Err(
        issue(
          "export-target-unsupported", target_format, "stored export materialization currently supports jsonl and csv",
        ),
      )
  }
}

///|
fn write_export_output(
  request : StoredExportRequest,
  body : String,
) -> Result[String, @moondata_store.MoonDataStoreIssue] {
  let path = match output_path(request.root, request.output_uri) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  @fsx.write_string_to_file(path, body) catch {
    _ =>
      return Err(
        issue(
          "write-export-output", path, "failed to write MoonData export output",
        ),
      )
  }
  Ok(path)
}

///|
pub fn publish_stored_export(
  request : StoredExportRequest,
) -> Result[StoredExportResult, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(request.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let version = match verify_version(request.root, request.version_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dataset = match verify_curated_dataset(request.root, version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match verify_quality_runs(request.root, version) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let records = match export_records(request.root, version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let body = match export_body(request.target_format, records) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let materialized_path = match write_export_output(request, body) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output = @moondata_core.data_ref(
    "output-\{request.export_manifest_id}",
    "export-\{request.target_format}",
    request.output_uri,
    content_type=content_type(request.target_format),
    byte_count=body.length().to_int64(),
    checksum=@moondata_core.text_checksum(body),
  )
  let manifest = @moondata_export.build_export_manifest(
    request.export_manifest_id,
    version,
    request.target_format,
    request.field_mapping,
    [output],
    request.created_at_ms,
    report=request.report,
  )
  match @moondata_store.write_export_manifest(request.root, manifest) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let rebuild = match
    @moondata_index.rebuild_catalog(request.root, request.created_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: request.root,
    version_id: version.version_id,
    dataset_id: dataset.dataset_id,
    export_manifest_id: manifest.export_manifest_id,
    target_format: manifest.target_format,
    output_uri: request.output_uri,
    output_path: materialized_path,
    output_record_count: records.length(),
    output_byte_count: body.length().to_int64(),
    output_checksum: output.checksum,
    quality_run_count: version.quality_run_ids.length(),
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    manifest,
  })
}
