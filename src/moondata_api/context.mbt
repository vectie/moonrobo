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
  summary : String
  refs : Array[@moondata_core.MoonDataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn context_from_status(status : MoonDataStatus) -> MoonDataContext {
  let state = if status.entry_count == 0 {
    "empty"
  } else if status.ready {
    "ready"
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
    summary: "MoonData \{state}: \{status.entry_count} cataloged artifact(s), \{status.dataset_count} dataset(s), \{status.capture_count} capture(s), \{status.episode_count} episode(s), \{status.frame_count} frame(s), \{status.export_count} export(s), validation \{status.latest_validation_status}, covered \{status.latest_validation_catalog_entry_count}/\{status.entry_count} catalog artifact(s), \{status.latest_validation_blocker_count} blocker(s), \{status.latest_validation_warning_count} warning(s)",
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
