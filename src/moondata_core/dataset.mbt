///|
pub(all) struct DatasetManifest {
  dataset_id : DatasetId
  schema_version : Int
  kind : String
  status : String
  source_ids : Array[SourceId]
  capture_ids : Array[CaptureId]
  episode_ids : Array[EpisodeId]
  created_at_ms : Int64
  lineage_id : String
  data_refs : Array[DataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn dataset_manifest(
  dataset_id : DatasetId,
  kind : String,
  status : String,
  created_at_ms : Int64,
  source_ids? : Array[SourceId] = [],
  capture_ids? : Array[CaptureId] = [],
  episode_ids? : Array[EpisodeId] = [],
  lineage_id? : String = "",
  data_refs? : Array[DataRef] = [],
  schema_version? : Int = 1,
) -> DatasetManifest {
  {
    dataset_id,
    schema_version,
    kind,
    status,
    source_ids,
    capture_ids,
    episode_ids,
    created_at_ms,
    lineage_id,
    data_refs,
  }
}

///|
pub(all) struct DatasetVersion {
  version_id : DatasetVersionId
  dataset_id : DatasetId
  status : String
  parent_version_ids : Array[DatasetVersionId]
  accepted_episode_ids : Array[EpisodeId]
  quality_run_ids : Array[QualityRunId]
  created_at_ms : Int64
  summary : String
} derive(Debug, Eq, ToJson, FromJson)
