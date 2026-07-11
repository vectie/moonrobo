///|
pub(all) struct NormalizeRequest {
  root : String
  raw_dataset_id : @moondata_core.DatasetId
  canonical_dataset_id : @moondata_core.DatasetId
  transform_run_id : @moondata_core.TransformRunId
  lineage_id : String
  normalized_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NormalizeResult {
  root : String
  raw_dataset_id : @moondata_core.DatasetId
  canonical_dataset_id : @moondata_core.DatasetId
  episode_count : Int
  frame_count : Int
  catalog_path : String
  catalog_entry_count : Int
  dataset : @moondata_core.DatasetManifest
  transform : @moondata_core.TransformRun
  lineage : @moondata_core.LineageManifest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn normalize_request(
  root : String,
  raw_dataset_id : @moondata_core.DatasetId,
  canonical_dataset_id : @moondata_core.DatasetId,
  normalized_at_ms : Int64,
  transform_run_id? : @moondata_core.TransformRunId = "",
  lineage_id? : String = "",
  summary? : String = "normalized raw dataset",
) -> NormalizeRequest {
  let transform = if transform_run_id == "" {
    "norm-\{raw_dataset_id}"
  } else {
    transform_run_id
  }
  let lineage = if lineage_id == "" {
    "lineage-\{canonical_dataset_id}"
  } else {
    lineage_id
  }
  {
    root,
    raw_dataset_id,
    canonical_dataset_id,
    transform_run_id: transform,
    lineage_id: lineage,
    normalized_at_ms,
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
fn verify_raw_dataset(
  request : NormalizeRequest,
) -> Result[@moondata_core.DatasetManifest, @moondata_store.MoonDataStoreIssue] {
  let dataset = match
    @moondata_store.read_raw_dataset(request.root, request.raw_dataset_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if dataset.kind != "raw" {
    return Err(
      issue(
        "normalize-input-not-raw",
        @moondata_store.dataset_kind_path(
          request.root,
          dataset.kind,
          dataset.dataset_id,
        ),
        "normalization input must be a raw dataset",
      ),
    )
  }
  if dataset.episode_ids.length() == 0 {
    return Err(
      issue(
        "normalize-input-empty",
        @moondata_store.dataset_kind_path(
          request.root,
          "raw",
          dataset.dataset_id,
        ),
        "normalization input has no episodes",
      ),
    )
  }
  Ok(dataset)
}

///|
fn count_verified_frames(
  root : String,
  dataset : @moondata_core.DatasetManifest,
) -> Result[Int, @moondata_store.MoonDataStoreIssue] {
  let mut count = 0
  for episode_id in dataset.episode_ids {
    let episode = match @moondata_store.read_episode(root, episode_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if episode.dataset_id != dataset.dataset_id {
      return Err(
        issue(
          "normalize-episode-dataset-mismatch",
          @moondata_store.episode_path(root, episode_id),
          "episode does not point back to normalization input dataset",
        ),
      )
    }
    for frame_id in episode.frame_ids {
      let frame = match @moondata_store.read_frame(root, frame_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if frame.episode_id != episode.episode_id {
        return Err(
          issue(
            "normalize-frame-episode-mismatch",
            @moondata_store.frame_path(root, frame_id),
            "frame does not point back to normalization input episode",
          ),
        )
      }
      count += 1
    }
  }
  Ok(count)
}

///|
fn normalized_dataset(
  request : NormalizeRequest,
  raw : @moondata_core.DatasetManifest,
) -> @moondata_core.DatasetManifest {
  @moondata_core.dataset_manifest(
    request.canonical_dataset_id,
    "canonical",
    "active",
    request.normalized_at_ms,
    source_ids=raw.source_ids,
    capture_ids=raw.capture_ids,
    episode_ids=raw.episode_ids,
    lineage_id=request.lineage_id,
    data_refs=raw.data_refs,
    schema_version=raw.schema_version,
  )
}

///|
fn normalization_transform(
  request : NormalizeRequest,
) -> @moondata_core.TransformRun {
  @moondata_core.transform_run(
    request.transform_run_id,
    request.raw_dataset_id,
    request.canonical_dataset_id,
    request.normalized_at_ms,
    [
      @moondata_core.transform_step(
        "raw-to-canonical-schema",
        "normalize",
        "{\"mode\":\"preserve-refs\",\"schema\":\"moondata.canonical.v1\"}",
        summary="promote raw refs into canonical dataset identity",
      ),
    ],
    lineage_id=request.lineage_id,
    summary=request.summary,
  )
}

///|
fn normalization_lineage(
  request : NormalizeRequest,
) -> @moondata_core.LineageManifest {
  @moondata_core.lineage_manifest(
    request.lineage_id,
    request.raw_dataset_id,
    request.normalized_at_ms,
    edges=[
      @moondata_core.lineage_edge(
        request.raw_dataset_id,
        request.canonical_dataset_id,
        "normalized-from",
      ),
      @moondata_core.lineage_edge(
        request.transform_run_id,
        request.canonical_dataset_id,
        "produced",
      ),
    ],
  )
}

///|
pub fn normalize_raw_dataset(
  request : NormalizeRequest,
) -> Result[NormalizeResult, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(request.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let raw = match verify_raw_dataset(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let frame_count = match count_verified_frames(request.root, raw) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dataset = normalized_dataset(request, raw)
  let transform = normalization_transform(request)
  let lineage = normalization_lineage(request)
  match @moondata_store.write_dataset(request.root, dataset) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_transform_run(request.root, transform) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @moondata_store.write_lineage_manifest(request.root, lineage) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let rebuild = match
    @moondata_index.rebuild_catalog(request.root, request.normalized_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: request.root,
    raw_dataset_id: request.raw_dataset_id,
    canonical_dataset_id: request.canonical_dataset_id,
    episode_count: raw.episode_ids.length(),
    frame_count,
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    dataset,
    transform,
    lineage,
  })
}
