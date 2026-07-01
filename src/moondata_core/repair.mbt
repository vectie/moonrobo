///|
pub(all) struct RepairAction {
  action_id : String
  operation_kind : String
  category : String
  severity : String
  target_ref : String
  artifact_kind : String
  artifact_id : String
  rule_id : String
  reason : String
  recommendation : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RepairRun {
  repair_run_id : RepairRunId
  root : String
  validation_report_id : String
  validation_status : String
  generated_at_ms : Int64
  action_count : Int
  blocker_count : Int
  warning_count : Int
  missing_payload_count : Int
  unmanaged_payload_count : Int
  metadata_conflict_count : Int
  unsafe_ref_count : Int
  external_ref_count : Int
  non_payload_ref_count : Int
  manifest_surface_ref_count : Int
  actions : Array[RepairAction]
  refs : Array[MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn repair_action(
  action_id : String,
  category : String,
  severity : String,
  artifact_kind : String,
  artifact_id : String,
  rule_id : String,
  reason : String,
  recommendation : String,
  operation_kind? : String = "",
  target_ref? : String = "",
) -> RepairAction {
  {
    action_id,
    operation_kind,
    category,
    severity,
    target_ref,
    artifact_kind,
    artifact_id,
    rule_id,
    reason,
    recommendation,
  }
}

///|
pub fn repair_run(
  repair_run_id : RepairRunId,
  root : String,
  validation_report_id : String,
  validation_status : String,
  generated_at_ms : Int64,
  action_count : Int,
  blocker_count : Int,
  warning_count : Int,
  missing_payload_count : Int,
  unmanaged_payload_count : Int,
  metadata_conflict_count : Int,
  unsafe_ref_count : Int,
  external_ref_count : Int,
  non_payload_ref_count : Int,
  manifest_surface_ref_count : Int,
  actions : Array[RepairAction],
  refs : Array[MoonDataRef],
  summary : String,
) -> RepairRun {
  {
    repair_run_id,
    root,
    validation_report_id,
    validation_status,
    generated_at_ms,
    action_count,
    blocker_count,
    warning_count,
    missing_payload_count,
    unmanaged_payload_count,
    metadata_conflict_count,
    unsafe_ref_count,
    external_ref_count,
    non_payload_ref_count,
    manifest_surface_ref_count,
    actions,
    refs,
    summary,
  }
}
