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
  for episode in episodes {
    target_refs.push(episode_ref(root, episode.episode_id))
    for frame_id in episode.frame_ids {
      target_refs.push(frame_ref(root, frame_id))
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
  let replay = match
    @moondata_replay.materialize_stored_replay(
      @moondata_replay.stored_replay_request(
        root,
        curated.version.version_id,
        request.generated_at_ms + 4L,
        replay_artifact_id=request.replay_artifact_id,
        summary="replayable local-file data product",
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    annotation_set_id: request.annotation_set_id,
    annotation_index_id: request.annotation_index_id,
    replay_artifact_id: request.replay_artifact_id,
    annotation_manifest,
    annotation_index_manifest,
    replay_manifest: replay.replay_manifest,
    replay_payload_ref: replay.replay_payload_ref,
  })
}
