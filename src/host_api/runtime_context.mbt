///|
fn latest_runtime_context(root : String) -> (String, String) {
  match @runtime.read_latest_runtime_health(root) {
    Ok(Some(record)) => (record.status, record.bridge_base_url)
    _ => ("not-running", "")
  }
}
