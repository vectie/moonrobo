///|
pub(all) struct CurationRequest {
  transform_run_id : @moondata_core.TransformRunId
  output_dataset_id : @moondata_core.DatasetId
  version_id : @moondata_core.DatasetVersionId
  lineage_id : String
  input_dataset : @moondata_core.DatasetManifest
  accepted_episode_ids : Array[@moondata_core.EpisodeId]
  rejected_refs : Array[@moondata_core.MoonDataRef]
  quality_run_ids : Array[@moondata_core.QualityRunId]
  steps : Array[@moondata_core.TransformStep]
  created_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CurationResult {
  dataset : @moondata_core.DatasetManifest
  version : @moondata_core.DatasetVersion
  transform : @moondata_core.TransformRun
  lineage : @moondata_core.LineageManifest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn curation_request(
  transform_run_id : @moondata_core.TransformRunId,
  output_dataset_id : @moondata_core.DatasetId,
  version_id : @moondata_core.DatasetVersionId,
  lineage_id : String,
  input_dataset : @moondata_core.DatasetManifest,
  accepted_episode_ids : Array[@moondata_core.EpisodeId],
  created_at_ms : Int64,
  steps? : Array[@moondata_core.TransformStep] = [],
  rejected_refs? : Array[@moondata_core.MoonDataRef] = [],
  quality_run_ids? : Array[@moondata_core.QualityRunId] = [],
  summary? : String = "",
) -> CurationRequest {
  {
    transform_run_id,
    output_dataset_id,
    version_id,
    lineage_id,
    input_dataset,
    accepted_episode_ids,
    rejected_refs,
    quality_run_ids,
    steps,
    created_at_ms,
    summary,
  }
}

///|
fn lineage_edges(
  request : CurationRequest,
) -> Array[@moondata_core.LineageEdge] {
  let edges = [
    @moondata_core.lineage_edge(
      request.input_dataset.dataset_id,
      request.output_dataset_id,
      "curated-from",
    ),
    @moondata_core.lineage_edge(
      request.transform_run_id,
      request.output_dataset_id,
      "produced",
    ),
  ]
  for quality_run_id in request.quality_run_ids {
    edges.push(
      @moondata_core.lineage_edge(
        quality_run_id,
        request.version_id,
        "quality-gate",
      ),
    )
  }
  for rejected in request.rejected_refs {
    edges.push(
      @moondata_core.lineage_edge(
        rejected.artifact_id,
        request.transform_run_id,
        "rejected",
      ),
    )
  }
  edges
}

///|
pub fn curate_dataset(request : CurationRequest) -> CurationResult {
  let dataset = @moondata_core.dataset_manifest(
    request.output_dataset_id,
    "curated",
    "active",
    request.created_at_ms,
    source_ids=request.input_dataset.source_ids,
    capture_ids=request.input_dataset.capture_ids,
    episode_ids=request.accepted_episode_ids,
    lineage_id=request.lineage_id,
    data_refs=request.input_dataset.data_refs,
    schema_version=request.input_dataset.schema_version,
  )
  let version = @moondata_core.dataset_version(
    request.version_id,
    dataset.dataset_id,
    "accepted",
    request.created_at_ms,
    accepted_episode_ids=request.accepted_episode_ids,
    quality_run_ids=request.quality_run_ids,
    summary=request.summary,
  )
  let steps = if request.steps.length() == 0 {
    [
      @moondata_core.transform_step(
        "select-accepted-episodes",
        "episode-filter",
        "{\"mode\":\"accepted-only\"}",
        summary="retain accepted episode refs",
      ),
    ]
  } else {
    request.steps
  }
  let transform = @moondata_core.transform_run(
    request.transform_run_id,
    request.input_dataset.dataset_id,
    dataset.dataset_id,
    request.created_at_ms,
    steps,
    quality_run_ids=request.quality_run_ids,
    rejected_refs=request.rejected_refs,
    lineage_id=request.lineage_id,
    summary=request.summary,
  )
  let lineage = @moondata_core.lineage_manifest(
    request.lineage_id,
    request.input_dataset.dataset_id,
    request.created_at_ms,
    edges=lineage_edges(request),
  )
  { dataset, version, transform, lineage }
}
