///|
pub(all) struct StoredCurationRequest {
  root : String
  input_dataset_id : @moondata_core.DatasetId
  quality_run_id : @moondata_core.QualityRunId
  output_dataset_id : @moondata_core.DatasetId
  version_id : @moondata_core.DatasetVersionId
  transform_run_id : @moondata_core.TransformRunId
  lineage_id : String
  created_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StoredCurationResult {
  root : String
  input_dataset_id : @moondata_core.DatasetId
  curated_dataset_id : @moondata_core.DatasetId
  version_id : @moondata_core.DatasetVersionId
  quality_run_id : @moondata_core.QualityRunId
  accepted_episode_count : Int
  catalog_path : String
  catalog_entry_count : Int
  dataset : @moondata_core.DatasetManifest
  version : @moondata_core.DatasetVersion
  transform : @moondata_core.TransformRun
  lineage : @moondata_core.LineageManifest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn stored_curation_request(
  root : String,
  input_dataset_id : @moondata_core.DatasetId,
  quality_run_id : @moondata_core.QualityRunId,
  created_at_ms : Int64,
  output_dataset_id? : @moondata_core.DatasetId = "",
  version_id? : @moondata_core.DatasetVersionId = "",
  transform_run_id? : @moondata_core.TransformRunId = "",
  lineage_id? : String = "",
  summary? : String = "curated accepted dataset",
) -> StoredCurationRequest {
  let output_id = if output_dataset_id == "" {
    "\{input_dataset_id}-curated"
  } else {
    output_dataset_id
  }
  let version = if version_id == "" {
    "version-\{output_id}"
  } else {
    version_id
  }
  let transform = if transform_run_id == "" {
    "curate-\{input_dataset_id}"
  } else {
    transform_run_id
  }
  let lineage = if lineage_id == "" {
    "lineage-\{output_id}"
  } else {
    lineage_id
  }
  {
    root,
    input_dataset_id,
    quality_run_id,
    output_dataset_id: output_id,
    version_id: version,
    transform_run_id: transform,
    lineage_id: lineage,
    created_at_ms,
    summary,
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
fn verify_input_dataset(
  request : StoredCurationRequest,
) -> Result[@moondata_core.DatasetManifest, @moondata_store.MoonDataStoreIssue] {
  let dataset = match
    @moondata_store.read_dataset(request.root, request.input_dataset_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if dataset.kind != "canonical" {
    return Err(
      issue(
        "curate-input-not-canonical",
        @moondata_store.dataset_kind_path(
          request.root,
          dataset.kind,
          dataset.dataset_id,
        ),
        "stored curation requires canonical dataset input",
      ),
    )
  }
  if dataset.episode_ids.length() == 0 {
    return Err(
      issue(
        "curate-input-empty",
        @moondata_store.dataset_path(request.root, dataset.dataset_id),
        "stored curation input has no episodes",
      ),
    )
  }
  Ok(dataset)
}

///|
fn verify_quality_gate(
  request : StoredCurationRequest,
  dataset : @moondata_core.DatasetManifest,
) -> Result[@moondata_core.QualityRun, @moondata_store.MoonDataStoreIssue] {
  let quality = match
    @moondata_store.read_quality_run(request.root, request.quality_run_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if quality.dataset_id != dataset.dataset_id {
    return Err(
      issue(
        "curate-quality-dataset-mismatch",
        @moondata_store.quality_run_path(request.root, quality.quality_run_id),
        "quality run does not belong to curation input dataset",
      ),
    )
  }
  if quality.status != "passed" {
    return Err(
      issue(
        "curate-quality-not-passed",
        @moondata_store.quality_run_path(request.root, quality.quality_run_id),
        "quality run status is \{quality.status}, expected passed",
      ),
    )
  }
  if quality.episode_ids.length() == 0 {
    return Err(
      issue(
        "curate-quality-empty",
        @moondata_store.quality_run_path(request.root, quality.quality_run_id),
        "quality run has no accepted episodes",
      ),
    )
  }
  for episode_id in quality.episode_ids {
    if !contains_episode(dataset.episode_ids, episode_id) {
      return Err(
        issue(
          "curate-quality-episode-mismatch",
          @moondata_store.quality_run_path(request.root, quality.quality_run_id),
          "quality run episode \{episode_id} is not in curation input dataset",
        ),
      )
    }
  }
  Ok(quality)
}

///|
pub fn curate_stored_dataset(
  request : StoredCurationRequest,
) -> Result[StoredCurationResult, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(request.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let input = match verify_input_dataset(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let quality = match verify_quality_gate(request, input) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let curation = @moondata_transform.curate_dataset(
    @moondata_transform.curation_request(
      request.transform_run_id,
      request.output_dataset_id,
      request.version_id,
      request.lineage_id,
      input,
      quality.episode_ids,
      request.created_at_ms,
      quality_run_ids=[quality.quality_run_id],
      summary=request.summary,
    ),
  )
  match @moondata_store.write_dataset(request.root, curation.dataset) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_dataset_version(request.root, curation.version) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_transform_run(request.root, curation.transform) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_lineage_manifest(request.root, curation.lineage) {
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
    input_dataset_id: input.dataset_id,
    curated_dataset_id: curation.dataset.dataset_id,
    version_id: curation.version.version_id,
    quality_run_id: quality.quality_run_id,
    accepted_episode_count: curation.version.accepted_episode_ids.length(),
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    dataset: curation.dataset,
    version: curation.version,
    transform: curation.transform,
    lineage: curation.lineage,
  })
}
