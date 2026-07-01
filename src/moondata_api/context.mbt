///|
pub(all) struct MoonDataContext {
  root : String
  status : String
  ready : Bool
  validation_report_id : String
  validation_status : String
  validation_generated_at_ms : Int64
  validation_catalog_entry_count : Int
  validation_covers_catalog : Bool
  validation_finding_count : Int
  validation_blocker_count : Int
  validation_warning_count : Int
  repair_work_count : Int
  repair_open_count : Int
  repair_applied_count : Int
  repair_applied_unvalidated_count : Int
  repair_failed_count : Int
  repair_pending_count : Int
  summary : String
  refs : Array[@moondata_core.MoonDataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn context_from_status(status : MoonDataStatus) -> MoonDataContext {
  let state = if status.entry_count == 0 {
    "empty"
  } else if status.ready {
    "ready"
  } else if status.latest_validation_status == "passed" &&
    status.latest_validation_covers_catalog &&
    status_has_repair_pressure(status) {
    "repair-pressure"
  } else if status.latest_validation_status == "blocked" {
    "blocked"
  } else if status.latest_validation_status == "review" {
    "review"
  } else if status.latest_validation_status == "stale" {
    "stale"
  } else if status.latest_validation_status == "missing" {
    "missing-validation"
  } else if status.latest_validation_status == "catalog-only" {
    "catalog-only"
  } else {
    "unvalidated"
  }
  {
    root: status.root,
    status: state,
    ready: status.ready,
    validation_report_id: status.latest_validation_report_id,
    validation_status: status.latest_validation_status,
    validation_generated_at_ms: status.latest_validation_generated_at_ms,
    validation_catalog_entry_count: status.latest_validation_catalog_entry_count,
    validation_covers_catalog: status.latest_validation_covers_catalog,
    validation_finding_count: status.latest_validation_finding_count,
    validation_blocker_count: status.latest_validation_blocker_count,
    validation_warning_count: status.latest_validation_warning_count,
    repair_work_count: status.repair_work_count,
    repair_open_count: status.repair_open_count,
    repair_applied_count: status.repair_applied_count,
    repair_applied_unvalidated_count: status.repair_applied_unvalidated_count,
    repair_failed_count: status.repair_failed_count,
    repair_pending_count: status.repair_pending_count,
    summary: "MoonData \{state}: \{status.entry_count} cataloged artifact(s), \{status.dataset_count} dataset(s), \{status.capture_count} capture(s), \{status.episode_count} episode(s), \{status.frame_count} frame(s), \{status.robot_model_count} robot model(s), \{status.annotation_count} annotation(s), \{status.annotation_index_count} annotation index(es), \{status.export_count} export(s), \{status.handoff_count} handoff dossier(s), validation \{status.latest_validation_status}, covered \{status.latest_validation_catalog_entry_count}/\{status.entry_count} catalog artifact(s), \{status.latest_validation_blocker_count} blocker(s), \{status.latest_validation_warning_count} warning(s), repair work \{status.repair_work_count} action(s), \{status.repair_open_count} open, \{status.repair_applied_unvalidated_count} applied without validation",
    refs: status.refs,
  }
}

///|
pub fn read_context(
  root : String,
) -> Result[MoonDataContext, @moondata_store.MoonDataStoreIssue] {
  let status = match read_status(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(context_from_status(status))
}
