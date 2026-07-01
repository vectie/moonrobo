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
  data_ref_count : Int
  receipt_count : Int
  stopped_capture_count : Int
  total_data_byte_count : Int64
  latest_capture_id : String
  latest_capture_status : String
  latest_capture_started_at_ms : Int64
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
priv struct CaptureListSummary {
  data_ref_count : Int
  receipt_count : Int
  stopped_capture_count : Int
  total_data_byte_count : Int64
  latest_capture_id : String
  latest_capture_status : String
  latest_capture_started_at_ms : Int64
}

///|
fn capture_list_summary(
  captures : Array[@moondata_core.CaptureSession],
) -> CaptureListSummary {
  let mut data_ref_count = 0
  let mut receipt_count = 0
  let mut stopped_capture_count = 0
  let mut total_data_byte_count = 0L
  let mut latest_id = ""
  let mut latest_status = "uncaptured"
  let mut latest_started_at_ms = -1L
  for capture in captures {
    data_ref_count += capture.data_refs.length()
    receipt_count += capture.receipt_ids.length()
    if capture.stopped_at_ms is Some(_) {
      stopped_capture_count += 1
    }
    for data_ref in capture.data_refs {
      total_data_byte_count += data_ref.byte_count
    }
    if capture.started_at_ms > latest_started_at_ms {
      latest_id = capture.capture_id
      latest_status = capture.status
      latest_started_at_ms = capture.started_at_ms
    }
  }
  if latest_id == "" {
    return {
      data_ref_count,
      receipt_count,
      stopped_capture_count,
      total_data_byte_count,
      latest_capture_id: "",
      latest_capture_status: "uncaptured",
      latest_capture_started_at_ms: 0L,
    }
  }
  {
    data_ref_count,
    receipt_count,
    stopped_capture_count,
    total_data_byte_count,
    latest_capture_id: latest_id,
    latest_capture_status: latest_status,
    latest_capture_started_at_ms: latest_started_at_ms,
  }
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
  let evidence = capture_list_summary(captures)
  Ok({
    root,
    query,
    capture_count: captures.length(),
    data_ref_count: evidence.data_ref_count,
    receipt_count: evidence.receipt_count,
    stopped_capture_count: evidence.stopped_capture_count,
    total_data_byte_count: evidence.total_data_byte_count,
    latest_capture_id: evidence.latest_capture_id,
    latest_capture_status: evidence.latest_capture_status,
    latest_capture_started_at_ms: evidence.latest_capture_started_at_ms,
    captures,
    refs,
    summary: "MoonData captures: \{captures.length()} match(es), \{evidence.data_ref_count} data ref(s), \{evidence.receipt_count} receipt(s), \{evidence.total_data_byte_count} byte(s), latest \{evidence.latest_capture_status}",
  })
}
