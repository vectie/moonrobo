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
  quality_run_count : Int
  catalog_path : String
  catalog_entry_count : Int
  manifest : @moondata_core.ExportManifest
} derive(Debug, Eq, ToJson, FromJson)

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
    "moondata://exports/\{export_id}.\{target_format}"
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
  let output = @moondata_core.data_ref(
    "output-\{request.export_manifest_id}",
    "export-\{request.target_format}",
    request.output_uri,
    content_type=content_type(request.target_format),
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
    quality_run_count: version.quality_run_ids.length(),
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    manifest,
  })
}
