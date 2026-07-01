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
  join(root, "datasets/canonical/\{dataset_id}.json")
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
    "datasets/curated", "episodes", "frames", "signals", "media", "indexes", "quality",
    "annotations", "transforms", "versions", "replays", "exports", "lineage",
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
    dataset_path(root, dataset.dataset_id),
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
pub fn read_dataset(
  root : String,
  dataset_id : @moondata_core.DatasetId,
) -> Result[@moondata_core.DatasetManifest, MoonDataStoreIssue] {
  let path = dataset_path(root, dataset_id)
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
