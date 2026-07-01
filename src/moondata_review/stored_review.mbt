///|
pub(all) struct StoredReviewRequest {
  root : String
  version_id : @moondata_core.DatasetVersionId
  annotation_set_id : @moondata_core.AnnotationSetId
  reviewer : String
  status : String
  labels : Array[@moondata_core.AnnotationLabel]
  created_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct StoredReviewResult {
  root : String
  version_id : @moondata_core.DatasetVersionId
  dataset_id : @moondata_core.DatasetId
  annotation_set_id : @moondata_core.AnnotationSetId
  annotation_index_id : @moondata_core.AnnotationTargetIndexId
  target_ref_count : Int
  label_count : Int
  evidence_ref_count : Int
  catalog_path : String
  catalog_entry_count : Int
  annotation : @moondata_core.AnnotationSet
  annotation_index : @moondata_core.AnnotationTargetIndex
  annotation_manifest : @moondata_store.PersistedManifest
  annotation_index_manifest : @moondata_store.PersistedManifest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn stored_review_request(
  root : String,
  version_id : @moondata_core.DatasetVersionId,
  reviewer : String,
  created_at_ms : Int64,
  annotation_set_id? : @moondata_core.AnnotationSetId = "",
  labels? : Array[@moondata_core.AnnotationLabel] = [],
  status? : String = "accepted",
  summary? : String = "stored MoonData review annotation",
) -> StoredReviewRequest {
  let annotation_id = if annotation_set_id == "" {
    "annotation-\{version_id}"
  } else {
    annotation_set_id
  }
  let label_values = if labels.length() == 0 {
    [@moondata_core.annotation_label("curation", "accepted", source=reviewer)]
  } else {
    labels
  }
  {
    root,
    version_id,
    annotation_set_id: annotation_id,
    reviewer,
    status,
    labels: label_values,
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
        "review-version-not-accepted",
        @moondata_store.dataset_version_path(root, version.version_id),
        "review input version status is \{version.status}, expected accepted",
      ),
    )
  }
  if version.accepted_episode_ids.length() == 0 {
    return Err(
      issue(
        "review-version-empty",
        @moondata_store.dataset_version_path(root, version.version_id),
        "review input version has no accepted episodes",
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
        "review-dataset-not-curated",
        @moondata_store.dataset_kind_path(
          root,
          dataset.kind,
          dataset.dataset_id,
        ),
        "review input dataset must be curated",
      ),
    )
  }
  for episode_id in version.accepted_episode_ids {
    if !contains_episode(dataset.episode_ids, episode_id) {
      return Err(
        issue(
          "review-version-dataset-episode-mismatch",
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
fn review_target_refs(
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
fn review_evidence_refs(
  root : String,
  version : @moondata_core.DatasetVersion,
) -> Result[
  Array[@moondata_core.MoonDataRef],
  @moondata_store.MoonDataStoreIssue,
] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for quality_run_id in version.quality_run_ids {
    let quality = match @moondata_store.read_quality_run(root, quality_run_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if quality.status != "passed" {
      return Err(
        issue(
          "review-quality-not-passed",
          @moondata_store.quality_run_path(root, quality.quality_run_id),
          "review quality evidence status is \{quality.status}, expected passed",
        ),
      )
    }
    refs.push(quality_ref(root, quality_run_id))
  }
  Ok(refs)
}

///|
fn verify_frames(
  root : String,
  episodes : Array[@moondata_core.EpisodeManifest],
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  for episode in episodes {
    for frame_id in episode.frame_ids {
      match @moondata_store.read_frame(root, frame_id) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
  }
  Ok(())
}

///|
pub fn materialize_stored_review(
  request : StoredReviewRequest,
) -> Result[StoredReviewResult, @moondata_store.MoonDataStoreIssue] {
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
  match verify_frames(request.root, episodes) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let target_refs = review_target_refs(request.root, dataset, version, episodes)
  let evidence_refs = match review_evidence_refs(request.root, version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let annotation = @moondata_annotation.review_annotation_set(
    request.annotation_set_id,
    target_refs,
    request.labels,
    request.reviewer,
    request.created_at_ms,
    status=request.status,
    evidence_refs~,
    summary=request.summary,
  )
  let annotation_manifest = match
    @moondata_store.write_annotation_set(request.root, annotation) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let annotation_index = @moondata_annotation.review_target_index(
    @moondata_annotation.annotation_target_index_id(
      annotation.annotation_set_id,
    ),
    annotation,
  )
  let annotation_index_manifest = match
    @moondata_store.write_annotation_target_index(
      request.root,
      annotation_index,
    ) {
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
    annotation_set_id: annotation.annotation_set_id,
    annotation_index_id: annotation_index.annotation_index_id,
    target_ref_count: annotation.target_refs.length(),
    label_count: annotation.labels.length(),
    evidence_ref_count: annotation.evidence_refs.length(),
    catalog_path: rebuild.catalog_path,
    catalog_entry_count: rebuild.entry_count,
    annotation,
    annotation_index,
    annotation_manifest,
    annotation_index_manifest,
  })
}
