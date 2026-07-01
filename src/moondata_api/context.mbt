///|
pub(all) struct MoonDataContext {
  root : String
  status : String
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
  } else {
    "unvalidated"
  }
  {
    root: status.root,
    status: state,
    summary: "MoonData \{state}: \{status.entry_count} cataloged artifact(s), \{status.export_count} export(s), validation \{status.latest_validation_status}",
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
