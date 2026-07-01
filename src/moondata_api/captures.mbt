///|
pub(all) struct MoonDataCaptureQuery {
  source_id : String
  robot_id : String
  bridge_id : String
  status : String
  data_kind : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataCaptureList {
  root : String
  query : MoonDataCaptureQuery
  capture_count : Int
  captures : Array[@moondata_core.CaptureSession]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn capture_query(
  source_id? : String = "",
  robot_id? : String = "",
  bridge_id? : String = "",
  status? : String = "",
  data_kind? : String = "",
) -> MoonDataCaptureQuery {
  { source_id, robot_id, bridge_id, status, data_kind }
}

///|
fn capture_query_has_filters(query : MoonDataCaptureQuery) -> Bool {
  query.source_id != "" ||
  query.robot_id != "" ||
  query.bridge_id != "" ||
  query.status != "" ||
  query.data_kind != ""
}

///|
fn capture_has_data_kind(
  capture : @moondata_core.CaptureSession,
  data_kind : String,
) -> Bool {
  if data_kind == "" {
    return true
  }
  for data_ref in capture.data_refs {
    if data_ref.kind == data_kind {
      return true
    }
  }
  false
}

///|
fn capture_matches(
  capture : @moondata_core.CaptureSession,
  query : MoonDataCaptureQuery,
) -> Bool {
  if query.source_id != "" && capture.source_id != query.source_id {
    return false
  }
  if query.robot_id != "" && capture.robot_id != query.robot_id {
    return false
  }
  if query.bridge_id != "" && capture.bridge_id != query.bridge_id {
    return false
  }
  if query.status != "" && capture.status != query.status {
    return false
  }
  capture_has_data_kind(capture, query.data_kind)
}

///|
fn capture_refs(
  root : String,
  captures : Array[@moondata_core.CaptureSession],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for capture in captures {
    refs.push(
      @moondata_core.moondata_ref(
        "capture",
        capture.capture_id,
        @moondata_store.capture_path(root, capture.capture_id),
        "\{capture.robot_id}/\{capture.bridge_id} \{capture.status}",
      ),
    )
  }
  refs
}

///|
pub fn list_captures(
  root : String,
  query? : MoonDataCaptureQuery = capture_query(),
) -> Result[MoonDataCaptureList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let captures : Array[@moondata_core.CaptureSession] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "capture" {
      let capture = match
        @moondata_store.read_capture(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if capture_query_has_filters(query) {
        capture_matches(capture, query)
      } else {
        true
      }
      if matches {
        captures.push(capture)
      }
    }
  }
  let refs = capture_refs(root, captures)
  Ok({
    root,
    query,
    capture_count: captures.length(),
    captures,
    refs,
    summary: "MoonData captures: \{captures.length()} match(es)",
  })
}
