///|
pub(all) struct MoonDataQualityGateView {
  quality_run_id : @moondata_core.QualityRunId
  status : String
  finding_count : Int
  blocker_count : Int
  warning_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataExportView {
  export_manifest_id : @moondata_core.ExportManifestId
  target_format : String
  status : String
  output_refs : Array[@moondata_core.DataRef]
  report : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataAnnotationView {
  annotation_set_id : @moondata_core.AnnotationSetId
  status : String
  reviewer : String
  labels : Array[@moondata_core.AnnotationLabel]
  target_refs : Array[@moondata_core.MoonDataRef]
  evidence_refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataReplayView {
  replay_artifact_id : @moondata_core.ReplayArtifactId
  viewer_profile : String
  episode_ids : Array[@moondata_core.EpisodeId]
  source_refs : Array[@moondata_core.MoonDataRef]
  generated_refs : Array[@moondata_core.DataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataDatasetSlice {
  root : String
  version_id : @moondata_core.DatasetVersionId
  dataset_id : @moondata_core.DatasetId
  status : String
  dataset_status : String
  accepted_episode_ids : Array[@moondata_core.EpisodeId]
  accepted_episode_count : Int
  quality_gates : Array[MoonDataQualityGateView]
  exports : Array[MoonDataExportView]
  annotations : Array[MoonDataAnnotationView]
  replays : Array[MoonDataReplayView]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn quality_gate_view(
  quality : @moondata_core.QualityRun,
) -> MoonDataQualityGateView {
  {
    quality_run_id: quality.quality_run_id,
    status: quality.status,
    finding_count: quality.finding_count,
    blocker_count: quality.blocker_count,
    warning_count: quality.warning_count,
  }
}

///|
fn export_view(manifest : @moondata_core.ExportManifest) -> MoonDataExportView {
  {
    export_manifest_id: manifest.export_manifest_id,
    target_format: manifest.target_format,
    status: manifest.status,
    output_refs: manifest.output_refs,
    report: manifest.report,
  }
}

///|
fn annotation_view(
  set : @moondata_core.AnnotationSet,
) -> MoonDataAnnotationView {
  {
    annotation_set_id: set.annotation_set_id,
    status: set.status,
    reviewer: set.reviewer,
    labels: set.labels,
    target_refs: set.target_refs,
    evidence_refs: set.evidence_refs,
    summary: set.summary,
  }
}

///|
fn replay_view(artifact : @moondata_core.ReplayArtifact) -> MoonDataReplayView {
  {
    replay_artifact_id: artifact.replay_artifact_id,
    viewer_profile: artifact.viewer_profile,
    episode_ids: artifact.episode_ids,
    source_refs: artifact.source_refs,
    generated_refs: artifact.generated_refs,
    summary: artifact.summary,
  }
}

///|
fn all_quality_passed(gates : Array[MoonDataQualityGateView]) -> Bool {
  if gates.length() == 0 {
    return false
  }
  for gate in gates {
    if gate.status != "passed" || gate.blocker_count > 0 {
      return false
    }
  }
  true
}

///|
fn slice_status(
  version : @moondata_core.DatasetVersion,
  gates : Array[MoonDataQualityGateView],
  exports : Array[MoonDataExportView],
) -> String {
  if version.status != "accepted" {
    "blocked"
  } else if !all_quality_passed(gates) {
    "blocked"
  } else if exports.length() == 0 {
    "pending-export"
  } else {
    "ready"
  }
}

///|
fn refs_for_slice(
  root : String,
  version : @moondata_core.DatasetVersion,
  gates : Array[MoonDataQualityGateView],
  exports : Array[MoonDataExportView],
  annotations : Array[MoonDataAnnotationView],
  replays : Array[MoonDataReplayView],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  refs.push(
    @moondata_core.moondata_ref(
      "dataset-version",
      version.version_id,
      @moondata_store.dataset_version_path(root, version.version_id),
      version.summary,
    ),
  )
  refs.push(
    @moondata_core.moondata_ref(
      "dataset",
      version.dataset_id,
      @moondata_store.dataset_kind_path(root, "curated", version.dataset_id),
      "curated dataset for slice \{version.version_id}",
    ),
  )
  for gate in gates {
    refs.push(
      @moondata_core.moondata_ref(
        "quality-run",
        gate.quality_run_id,
        @moondata_store.quality_run_path(root, gate.quality_run_id),
        "quality gate \{gate.status}",
      ),
    )
  }
  for published in exports {
    refs.push(
      @moondata_core.moondata_ref(
        "export-manifest",
        published.export_manifest_id,
        @moondata_store.export_manifest_path(root, published.export_manifest_id),
        published.report,
      ),
    )
  }
  for annotation in annotations {
    refs.push(
      @moondata_core.moondata_ref(
        "annotation-set",
        annotation.annotation_set_id,
        @moondata_store.annotation_set_path(root, annotation.annotation_set_id),
        annotation.summary,
      ),
    )
  }
  for replay in replays {
    refs.push(
      @moondata_core.moondata_ref(
        "replay-artifact",
        replay.replay_artifact_id,
        @moondata_store.replay_artifact_path(root, replay.replay_artifact_id),
        replay.summary,
      ),
    )
  }
  refs
}

///|
fn contains_id(ids : Array[String], id : String) -> Bool {
  for candidate in ids {
    if candidate == id {
      return true
    }
  }
  false
}

///|
fn slice_ref_ids(version : @moondata_core.DatasetVersion) -> Array[String] {
  let ids : Array[String] = [version.version_id, version.dataset_id]
  for episode_id in version.accepted_episode_ids {
    ids.push(episode_id)
  }
  ids
}

///|
fn refs_match_slice(
  refs : Array[@moondata_core.MoonDataRef],
  ids : Array[String],
) -> Bool {
  for moondata_ref in refs {
    if contains_id(ids, moondata_ref.artifact_id) {
      return true
    }
  }
  false
}

///|
fn matching_exports(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
  version_id : @moondata_core.DatasetVersionId,
) -> Result[Array[MoonDataExportView], @moondata_store.MoonDataStoreIssue] {
  let exports : Array[MoonDataExportView] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "export-manifest" {
      let manifest = match
        @moondata_store.read_export_manifest(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if manifest.input_version_id == version_id {
        exports.push(export_view(manifest))
      }
    }
  }
  Ok(exports)
}

///|
fn matching_annotations(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
  version : @moondata_core.DatasetVersion,
) -> Result[Array[MoonDataAnnotationView], @moondata_store.MoonDataStoreIssue] {
  let ids = slice_ref_ids(version)
  let annotations : Array[MoonDataAnnotationView] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "annotation-set" {
      let set = match
        @moondata_store.read_annotation_set(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if refs_match_slice(set.target_refs, ids) ||
        refs_match_slice(set.evidence_refs, ids) {
        annotations.push(annotation_view(set))
      }
    }
  }
  Ok(annotations)
}

///|
fn matching_replays(
  root : String,
  catalog : @moondata_core.MoonDataCatalog,
  version : @moondata_core.DatasetVersion,
) -> Result[Array[MoonDataReplayView], @moondata_store.MoonDataStoreIssue] {
  let ids = slice_ref_ids(version)
  let replays : Array[MoonDataReplayView] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "replay-artifact" {
      let replay = match
        @moondata_store.read_replay_artifact(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if replay.dataset_id == version.dataset_id ||
        refs_match_slice(replay.source_refs, ids) ||
        replay.episode_ids.any(episode_id => contains_id(ids, episode_id)) {
        replays.push(replay_view(replay))
      }
    }
  }
  Ok(replays)
}

///|
pub fn read_dataset_slice(
  root : String,
  version_id : @moondata_core.DatasetVersionId,
) -> Result[MoonDataDatasetSlice, @moondata_store.MoonDataStoreIssue] {
  let version = match @moondata_store.read_dataset_version(root, version_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dataset = match
    @moondata_store.read_curated_dataset(root, version.dataset_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let gates : Array[MoonDataQualityGateView] = []
  for quality_run_id in version.quality_run_ids {
    let quality = match @moondata_store.read_quality_run(root, quality_run_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    gates.push(quality_gate_view(quality))
  }
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let exports = match matching_exports(root, catalog, version.version_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let annotations = match matching_annotations(root, catalog, version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let replays = match matching_replays(root, catalog, version) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let status = slice_status(version, gates, exports)
  let refs = refs_for_slice(root, version, gates, exports, annotations, replays)
  Ok({
    root,
    version_id: version.version_id,
    dataset_id: version.dataset_id,
    status,
    dataset_status: dataset.status,
    accepted_episode_ids: version.accepted_episode_ids,
    accepted_episode_count: version.accepted_episode_ids.length(),
    quality_gates: gates,
    exports,
    annotations,
    replays,
    refs,
    summary: "MoonData slice \{status}: version \{version.version_id}, \{version.accepted_episode_ids.length()} accepted episode(s), \{exports.length()} export(s), \{annotations.length()} annotation(s), \{replays.length()} replay(s)",
  })
}
