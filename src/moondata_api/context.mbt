///|
pub(all) struct MoonDataContext {
  root : String
  status : String
  summary : String
  refs : Array[@moondata_core.MoonDataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn context_from_status(status : MoonDataStatus) -> MoonDataContext {
  let state = if status.ready { "ready" } else { "empty" }
  {
    root: status.root,
    status: state,
    summary: "MoonData \{state}: \{status.entry_count} cataloged artifact(s), \{status.export_count} export(s)",
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
