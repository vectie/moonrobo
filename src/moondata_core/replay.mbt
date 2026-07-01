///|
pub(all) struct ReplayArtifact {
  replay_artifact_id : ReplayArtifactId
  dataset_id : DatasetId
  episode_ids : Array[EpisodeId]
  source_refs : Array[MoonDataRef]
  generated_refs : Array[DataRef]
  viewer_profile : String
  created_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn replay_artifact(
  replay_artifact_id : ReplayArtifactId,
  dataset_id : DatasetId,
  episode_ids : Array[EpisodeId],
  created_at_ms : Int64,
  source_refs? : Array[MoonDataRef] = [],
  generated_refs? : Array[DataRef] = [],
  viewer_profile? : String = "moondata.replay.v1",
  summary? : String = "",
) -> ReplayArtifact {
  {
    replay_artifact_id,
    dataset_id,
    episode_ids,
    source_refs,
    generated_refs,
    viewer_profile,
    created_at_ms,
    summary,
  }
}
