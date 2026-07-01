///|
pub(all) struct TransformStep {
  step_id : String
  kind : String
  config_json : String
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn transform_step(
  step_id : String,
  kind : String,
  config_json : String,
  summary? : String = "",
) -> TransformStep {
  { step_id, kind, config_json, summary }
}

///|
pub(all) struct TransformRun {
  transform_run_id : TransformRunId
  input_dataset_id : DatasetId
  output_dataset_id : DatasetId
  created_at_ms : Int64
  status : String
  step_count : Int
  quality_run_ids : Array[QualityRunId]
  rejected_refs : Array[MoonDataRef]
  lineage_id : String
  steps : Array[TransformStep]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn transform_run(
  transform_run_id : TransformRunId,
  input_dataset_id : DatasetId,
  output_dataset_id : DatasetId,
  created_at_ms : Int64,
  steps : Array[TransformStep],
  status? : String = "completed",
  quality_run_ids? : Array[QualityRunId] = [],
  rejected_refs? : Array[MoonDataRef] = [],
  lineage_id? : String = "",
  summary? : String = "",
) -> TransformRun {
  {
    transform_run_id,
    input_dataset_id,
    output_dataset_id,
    created_at_ms,
    status,
    step_count: steps.length(),
    quality_run_ids,
    rejected_refs,
    lineage_id,
    steps,
    summary,
  }
}
