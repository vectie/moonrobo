///|
pub(all) struct ExportManifest {
  export_manifest_id : ExportManifestId
  input_version_id : DatasetVersionId
  dataset_id : DatasetId
  target_format : String
  field_mapping : String
  output_refs : Array[DataRef]
  quality_run_ids : Array[QualityRunId]
  created_at_ms : Int64
  status : String
  report : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn export_manifest(
  export_manifest_id : ExportManifestId,
  input_version_id : DatasetVersionId,
  dataset_id : DatasetId,
  target_format : String,
  field_mapping : String,
  output_refs : Array[DataRef],
  created_at_ms : Int64,
  quality_run_ids? : Array[QualityRunId] = [],
  status? : String = "ready",
  report? : String = "",
) -> ExportManifest {
  {
    export_manifest_id,
    input_version_id,
    dataset_id,
    target_format,
    field_mapping,
    output_refs,
    quality_run_ids,
    created_at_ms,
    status,
    report,
  }
}
