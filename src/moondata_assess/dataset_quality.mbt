///|
pub(all) struct DatasetQualityRequest {
  root : String
  dataset_id : @moondata_core.DatasetId
  quality_run_id : @moondata_core.QualityRunId
  expected_robot_id : String
  expected_bridge_id : String
  generated_at_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DatasetQualityResult {
  root : String
  dataset_id : @moondata_core.DatasetId
  quality_run_id : @moondata_core.QualityRunId
  episode_count : Int
  frame_count : Int
  catalog_path : String
  catalog_entry_count : Int
  quality : @moondata_core.QualityRun
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn dataset_quality_request(
  root : String,
  dataset_id : @moondata_core.DatasetId,
  generated_at_ms : Int64,
  quality_run_id? : @moondata_core.QualityRunId = "",
  expected_robot_id? : String = "",
  expected_bridge_id? : String = "",
) -> DatasetQualityRequest {
  let run_id = if quality_run_id == "" {
    "qr-\{dataset_id}"
  } else {
    quality_run_id
  }
  {
    root,
    dataset_id,
    quality_run_id: run_id,
    expected_robot_id,
    expected_bridge_id,
    generated_at_ms,
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
fn verify_dataset(
  request : DatasetQualityRequest,
) -> Result[@moondata_core.DatasetManifest, @moondata_store.MoonDataStoreIssue] {
  let dataset = match
    @moondata_store.read_dataset(request.root, request.dataset_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if dataset.kind != "canonical" {
    return Err(
      issue(
        "quality-input-not-canonical",
        @moondata_store.dataset_kind_path(
          request.root,
          dataset.kind,
          dataset.dataset_id,
        ),
        "dataset quality runs require canonical dataset input",
      ),
    )
  }
  if dataset.episode_ids.length() == 0 {
    return Err(
      issue(
        "quality-input-empty",
        @moondata_store.dataset_path(request.root, dataset.dataset_id),
        "dataset quality input has no episodes",
      ),
    )
  }
  Ok(dataset)
}

///|
fn read_episode_frames(
  root : String,
  episode : @moondata_core.EpisodeManifest,
) -> Result[Array[@moondata_core.FrameRef], @moondata_store.MoonDataStoreIssue] {
  let frames : Array[@moondata_core.FrameRef] = []
  for frame_id in episode.frame_ids {
    let frame = match @moondata_store.read_frame(root, frame_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    frames.push(frame)
  }
  Ok(frames)
}

///|
fn scoped_finding(
  quality_run_id : @moondata_core.QualityRunId,
  episode_id : @moondata_core.EpisodeId,
  finding : @moondata_core.QualityFinding,
) -> @moondata_core.QualityFinding {
  {
    finding_id: "\{quality_run_id}-\{episode_id}-\{finding.finding_id}",
    rule_id: finding.rule_id,
    severity: finding.severity,
    target_kind: finding.target_kind,
    target_id: finding.target_id,
    message: finding.message,
    evidence_refs: finding.evidence_refs,
    recommendation: finding.recommendation,
  }
}

///|
pub fn run_dataset_quality(
  request : DatasetQualityRequest,
) -> Result[DatasetQualityResult, @moondata_store.MoonDataStoreIssue] {
  match @moondata_store.initialize_root(request.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let dataset = match verify_dataset(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let episode_ids : Array[@moondata_core.EpisodeId] = []
  let findings : Array[@moondata_core.QualityFinding] = []
  let mut frame_count = 0
  for episode_id in dataset.episode_ids {
    let episode = match @moondata_store.read_episode(request.root, episode_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let frames = match read_episode_frames(request.root, episode) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    frame_count += frames.length()
    episode_ids.push(episode.episode_id)
    let run = @moondata_quality.evaluate_episode(
      request.quality_run_id,
      dataset.dataset_id,
      episode,
      frames,
      request.generated_at_ms,
      config=@moondata_quality.default_quality_config(
        expected_robot_id=request.expected_robot_id,
        expected_bridge_id=request.expected_bridge_id,
      ),
    )
    for finding in run.findings {
      findings.push(
        scoped_finding(request.quality_run_id, episode.episode_id, finding),
      )
    }
  }
  let quality = @moondata_core.quality_run(
    request.quality_run_id,
    dataset.dataset_id,
    episode_ids,
    request.generated_at_ms,
    findings,
  )
  match @moondata_store.write_quality_run(request.root, quality) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let rebuild = match
    @moondata_index.rebuild_catalog(request.root, request.generated_at_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    root: request.root,
    dataset_id: dataset.dataset_id,
    quality_run_id: quality.quality_run_id,
    episode_count: episode_ids.length(),
    frame_count,
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    quality,
  })
}
