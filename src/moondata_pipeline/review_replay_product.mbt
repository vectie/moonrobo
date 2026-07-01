///|
priv struct ReplayPayloadFrame {
  episode_id : @moondata_core.EpisodeId
  frame_id : @moondata_core.FrameId
  sequence_index : Int
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
priv struct ReviewReplayResult {
  annotation_set_id : @moondata_core.AnnotationSetId
  annotation_index_id : @moondata_core.AnnotationTargetIndexId
  replay_artifact_id : @moondata_core.ReplayArtifactId
  annotation_manifest : @moondata_store.PersistedManifest
  annotation_index_manifest : @moondata_store.PersistedManifest
  replay_manifest : @moondata_store.PersistedManifest
  replay_payload_ref : @moondata_core.DataRef
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
fn quality_ref(
  root : String,
  quality_run_id : @moondata_core.QualityRunId,
) -> @moondata_core.MoonDataRef {
  moondata_ref(
    "quality-run",
    quality_run_id,
    @moondata_store.quality_run_path(root, quality_run_id),
    "quality gate evidence",
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
fn build_replay_payload(
  root : String,
  replay_artifact_id : @moondata_core.ReplayArtifactId,
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
        sequence_index: i,
        payload_ref: frame.payload_ref,
      })
    }
  }
  Ok({
    replay_artifact_id,
    dataset_id: version.dataset_id,
    version_id: version.version_id,
    episode_ids: version.accepted_episode_ids,
    frame_count: frames.length(),
    frames,
  })
}

///|
fn write_replay_payload(
  root : String,
  replay_artifact_id : @moondata_core.ReplayArtifactId,
  payload : ReplayPayload,
) -> Result[@moondata_core.DataRef, @moondata_store.MoonDataStoreIssue] {
  match ensure_replay_payload_dir(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let body = payload.to_json().stringify(indent=2)
  let path = replay_payload_path(root, replay_artifact_id)
  @fsx.write_string_to_file(path, body) catch {
    _ =>
      return Err(
        issue(
          "write-replay-payload", path, "failed to write MoonData replay payload",
        ),
      )
  }
  Ok(
    @moondata_core.data_ref(
      "payload-\{replay_artifact_id}",
      "replay-payload",
      replay_payload_uri(replay_artifact_id),
      content_type="application/json",
      byte_count=body.length().to_int64(),
      checksum=@moondata_core.text_checksum(body),
    ),
  )
}

///|
fn write_review_replay(
  request : LocalFileProductRequest,
  curated : @moondata_curate.StoredCurationResult,
) -> Result[ReviewReplayResult, @moondata_store.MoonDataStoreIssue] {
  let root = request.root
  let episodes = match load_accepted_episodes(root, curated.version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let target_refs : Array[@moondata_core.MoonDataRef] = [
    dataset_ref(root, curated.dataset),
    version_ref(root, curated.version),
  ]
  let replay_source_refs : Array[@moondata_core.MoonDataRef] = [
    dataset_ref(root, curated.dataset),
    version_ref(root, curated.version),
  ]
  for episode in episodes {
    target_refs.push(episode_ref(root, episode.episode_id))
    replay_source_refs.push(episode_ref(root, episode.episode_id))
    for frame_id in episode.frame_ids {
      target_refs.push(frame_ref(root, frame_id))
      replay_source_refs.push(frame_ref(root, frame_id))
    }
  }
  let annotation = @moondata_annotation.review_annotation_set(
    request.annotation_set_id,
    target_refs,
    [
      @moondata_core.annotation_label(
        "curation",
        "accepted",
        source="moondata.pipeline",
      ),
      @moondata_core.annotation_label(
        "split",
        "train",
        confidence=0.95,
        source="moondata.pipeline",
      ),
    ],
    "moondata.pipeline",
    request.generated_at_ms + 4L,
    evidence_refs=[quality_ref(root, request.quality_run_id)],
    summary="accepted local-file data product",
  )
  let annotation_manifest = match
    @moondata_store.write_annotation_set(root, annotation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let annotation_index = @moondata_annotation.review_target_index(
    request.annotation_index_id,
    annotation,
  )
  let annotation_index_manifest = match
    @moondata_store.write_annotation_target_index(root, annotation_index) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let payload = match
    build_replay_payload(
      root,
      request.replay_artifact_id,
      curated.version,
      episodes,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let payload_ref = match
    write_replay_payload(root, request.replay_artifact_id, payload) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let replay = @moondata_core.replay_artifact(
    request.replay_artifact_id,
    curated.version.dataset_id,
    curated.version.accepted_episode_ids,
    request.generated_at_ms + 4L,
    source_refs=replay_source_refs,
    generated_refs=[payload_ref],
    summary="replayable local-file data product",
  )
  let replay_manifest = match
    @moondata_store.write_replay_artifact(root, replay) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    annotation_set_id: request.annotation_set_id,
    annotation_index_id: request.annotation_index_id,
    replay_artifact_id: request.replay_artifact_id,
    annotation_manifest,
    annotation_index_manifest,
    replay_manifest,
    replay_payload_ref: payload_ref,
  })
}
