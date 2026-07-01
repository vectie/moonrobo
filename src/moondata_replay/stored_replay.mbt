///|
pub(all) struct StoredReplayRequest {
  root : String
  version_id : @moondata_core.DatasetVersionId
  replay_artifact_id : @moondata_core.ReplayArtifactId
  viewer_profile : String
  created_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StoredReplayResult {
  root : String
  version_id : @moondata_core.DatasetVersionId
  dataset_id : @moondata_core.DatasetId
  replay_artifact_id : @moondata_core.ReplayArtifactId
  replay_payload_uri : String
  replay_payload_path : String
  replay_payload_byte_count : Int64
  replay_payload_checksum : String
  accepted_episode_count : Int
  frame_count : Int
  catalog_path : String
  catalog_entry_count : Int
  manifest : @moondata_core.ReplayArtifact
  replay_manifest : @moondata_store.PersistedManifest
  replay_payload_ref : @moondata_core.DataRef
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct ReplayPayloadFrame {
  episode_id : @moondata_core.EpisodeId
  frame_id : @moondata_core.FrameId
  sequence_index : Int
  captured_at_ms : Int64
  payload_ref : @moondata_core.DataRef?
} derive(ToJson)

///|
priv struct ReplayPayload {
  replay_artifact_id : @moondata_core.ReplayArtifactId
  dataset_id : @moondata_core.DatasetId
  version_id : @moondata_core.DatasetVersionId
  episode_ids : Array[@moondata_core.EpisodeId]
  frame_count : Int
  frames : Array[ReplayPayloadFrame]
} derive(ToJson)

///|
pub fn stored_replay_request(
  root : String,
  version_id : @moondata_core.DatasetVersionId,
  created_at_ms : Int64,
  replay_artifact_id? : @moondata_core.ReplayArtifactId = "",
  viewer_profile? : String = "moondata.replay.v1",
  summary? : String = "stored MoonData replay artifact",
) -> StoredReplayRequest {
  let replay_id = if replay_artifact_id == "" {
    "replay-\{version_id}"
  } else {
    replay_artifact_id
  }
  {
    root,
    version_id,
    replay_artifact_id: replay_id,
    viewer_profile,
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
fn join(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
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
fn moondata_ref(
  artifact_kind : String,
  artifact_id : String,
  manifest_path : String,
  summary : String,
) -> @moondata_core.MoonDataRef {
  @moondata_core.moondata_ref(
    artifact_kind, artifact_id, manifest_path, summary,
  )
}

///|
fn dataset_ref(
  root : String,
  dataset : @moondata_core.DatasetManifest,
) -> @moondata_core.MoonDataRef {
  moondata_ref(
    "dataset",
    dataset.dataset_id,
    @moondata_store.dataset_kind_path(root, dataset.kind, dataset.dataset_id),
    "\{dataset.kind} dataset",
  )
}

///|
fn version_ref(
  root : String,
  version : @moondata_core.DatasetVersion,
) -> @moondata_core.MoonDataRef {
  moondata_ref(
    "dataset-version",
    version.version_id,
    @moondata_store.dataset_version_path(root, version.version_id),
    "accepted dataset version",
  )
}

///|
fn episode_ref(
  root : String,
  episode_id : @moondata_core.EpisodeId,
) -> @moondata_core.MoonDataRef {
  moondata_ref(
    "episode",
    episode_id,
    @moondata_store.episode_path(root, episode_id),
    "accepted episode",
  )
}

///|
fn frame_ref(
  root : String,
  frame_id : @moondata_core.FrameId,
) -> @moondata_core.MoonDataRef {
  moondata_ref(
    "frame",
    frame_id,
    @moondata_store.frame_path(root, frame_id),
    "accepted frame",
  )
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
        "replay-version-not-accepted",
        @moondata_store.dataset_version_path(root, version.version_id),
        "replay input version status is \{version.status}, expected accepted",
      ),
    )
  }
  if version.accepted_episode_ids.length() == 0 {
    return Err(
      issue(
        "replay-version-empty",
        @moondata_store.dataset_version_path(root, version.version_id),
        "replay input version has no accepted episodes",
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
        "replay-dataset-not-curated",
        @moondata_store.dataset_kind_path(
          root,
          dataset.kind,
          dataset.dataset_id,
        ),
        "replay input dataset must be curated",
      ),
    )
  }
  for episode_id in version.accepted_episode_ids {
    if !contains_episode(dataset.episode_ids, episode_id) {
      return Err(
        issue(
          "replay-version-dataset-episode-mismatch",
          @moondata_store.dataset_version_path(root, version.version_id),
          "accepted episode \{episode_id} is not in curated dataset",
        ),
      )
    }
  }
  Ok(dataset)
}

///|
fn load_accepted_episodes(
  root : String,
  version : @moondata_core.DatasetVersion,
) -> Result[
  Array[@moondata_core.EpisodeManifest],
  @moondata_store.MoonDataStoreIssue,
] {
  let episodes : Array[@moondata_core.EpisodeManifest] = []
  for episode_id in version.accepted_episode_ids {
    let episode = match @moondata_store.read_episode(root, episode_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    episodes.push(episode)
  }
  Ok(episodes)
}

///|
fn replay_source_refs(
  root : String,
  dataset : @moondata_core.DatasetManifest,
  version : @moondata_core.DatasetVersion,
  episodes : Array[@moondata_core.EpisodeManifest],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = [
    dataset_ref(root, dataset),
    version_ref(root, version),
  ]
  for episode in episodes {
    refs.push(episode_ref(root, episode.episode_id))
    for frame_id in episode.frame_ids {
      refs.push(frame_ref(root, frame_id))
    }
  }
  refs
}

///|
fn replay_payload(
  root : String,
  request : StoredReplayRequest,
  version : @moondata_core.DatasetVersion,
  episodes : Array[@moondata_core.EpisodeManifest],
) -> Result[ReplayPayload, @moondata_store.MoonDataStoreIssue] {
  let frames : Array[ReplayPayloadFrame] = []
  for episode in episodes {
    for i in 0..<episode.frame_ids.length() {
      let frame_id = episode.frame_ids[i]
      let frame = match @moondata_store.read_frame(root, frame_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      frames.push({
        episode_id: episode.episode_id,
        frame_id,
        sequence_index: frame.sequence_index,
        captured_at_ms: frame.captured_at_ms,
        payload_ref: frame.payload_ref,
      })
    }
  }
  Ok({
    replay_artifact_id: request.replay_artifact_id,
    dataset_id: version.dataset_id,
    version_id: version.version_id,
    episode_ids: version.accepted_episode_ids,
    frame_count: frames.length(),
    frames,
  })
}

///|
fn replay_payload_uri(
  replay_artifact_id : @moondata_core.ReplayArtifactId,
) -> String {
  "moondata://media/replays/\{replay_artifact_id}.json"
}

///|
fn replay_payload_path(
  root : String,
  replay_artifact_id : @moondata_core.ReplayArtifactId,
) -> String {
  join(root, "media/replays/\{replay_artifact_id}.json")
}

///|
fn ensure_replay_payload_dir(
  root : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  let dir = join(root, "media/replays")
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          issue(
            "create-replay-payload-dir", dir, "failed to create MoonData replay payload directory",
          ),
        )
    }
  }
  Ok(())
}

///|
fn write_replay_payload(
  request : StoredReplayRequest,
  payload : ReplayPayload,
) -> Result[
  (@moondata_core.DataRef, String),
  @moondata_store.MoonDataStoreIssue,
] {
  match ensure_replay_payload_dir(request.root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let body = payload.to_json().stringify(indent=2)
  let path = replay_payload_path(request.root, request.replay_artifact_id)
  @fsx.write_string_to_file(path, body) catch {
    _ =>
      return Err(
        issue(
          "write-replay-payload", path, "failed to write MoonData replay payload",
        ),
      )
  }
  Ok(
    (
      @moondata_core.data_ref(
        "payload-\{request.replay_artifact_id}",
        "replay-payload",
        replay_payload_uri(request.replay_artifact_id),
        content_type="application/json",
        byte_count=body.length().to_int64(),
        checksum=@moondata_core.text_checksum(body),
      ),
      path,
    ),
  )
}

///|
pub fn materialize_stored_replay(
  request : StoredReplayRequest,
) -> Result[StoredReplayResult, @moondata_store.MoonDataStoreIssue] {
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
  let episodes = match load_accepted_episodes(request.root, version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let payload = match replay_payload(request.root, request, version, episodes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let frame_count = payload.frame_count
  let (payload_ref, payload_path) = match
    write_replay_payload(request, payload) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let manifest = @moondata_core.replay_artifact(
    request.replay_artifact_id,
    version.dataset_id,
    version.accepted_episode_ids,
    request.created_at_ms,
    source_refs=replay_source_refs(request.root, dataset, version, episodes),
    generated_refs=[payload_ref],
    viewer_profile=request.viewer_profile,
    summary=request.summary,
  )
  let replay_manifest = match
    @moondata_store.write_replay_artifact(request.root, manifest) {
    Ok(value) => value
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
    replay_artifact_id: manifest.replay_artifact_id,
    replay_payload_uri: payload_ref.uri,
    replay_payload_path: payload_path,
    replay_payload_byte_count: payload_ref.byte_count,
    replay_payload_checksum: payload_ref.checksum,
    accepted_episode_count: version.accepted_episode_ids.length(),
    frame_count,
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    manifest,
    replay_manifest,
    replay_payload_ref: payload_ref,
  })
}
