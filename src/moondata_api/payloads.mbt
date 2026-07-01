///|
pub(all) struct MoonDataPayloadQuery {
  uri_contains : String
  payload_root : String
  local_status : String
  data_kind : String
  artifact_kind : String
  artifact_id : String
  metadata_status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataPayloadOwner {
  artifact_kind : String
  artifact_id : String
  ref_role : String
  ref_id : String
  data_kind : String
  byte_count : Int64
  checksum : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataPayloadView {
  uri : String
  relative_path : String
  local_path : String
  payload_root : String
  local_status : String
  byte_count : Int64
  checksum : String
  owner_count : Int
  metadata_consistent : Bool
  owners : Array[MoonDataPayloadOwner]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataPayloadList {
  root : String
  query : MoonDataPayloadQuery
  payload_count : Int
  owner_count : Int
  total_byte_count : Int64
  checksums : Array[String]
  present_count : Int
  missing_count : Int
  non_payload_count : Int
  unsafe_count : Int
  external_count : Int
  conflict_count : Int
  payloads : Array[MoonDataPayloadView]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn payload_query(
  uri_contains? : String = "",
  payload_root? : String = "",
  local_status? : String = "",
  data_kind? : String = "",
  artifact_kind? : String = "",
  artifact_id? : String = "",
  metadata_status? : String = "",
) -> MoonDataPayloadQuery {
  {
    uri_contains,
    payload_root,
    local_status,
    data_kind,
    artifact_kind,
    artifact_id,
    metadata_status,
  }
}

///|
fn owner_from_data_ref(view : MoonDataDataRefView) -> MoonDataPayloadOwner {
  {
    artifact_kind: view.artifact_kind,
    artifact_id: view.artifact_id,
    ref_role: view.ref_role,
    ref_id: view.data_ref.ref_id,
    data_kind: view.data_ref.kind,
    byte_count: view.data_ref.byte_count,
    checksum: view.data_ref.checksum,
  }
}

///|
fn find_payload_index(
  payloads : Array[MoonDataPayloadView],
  uri : String,
) -> Int? {
  for index in 0..<payloads.length() {
    if payloads[index].uri == uri {
      return Some(index)
    }
  }
  None
}

///|
fn metadata_matches(
  payload : MoonDataPayloadView,
  owner : MoonDataPayloadOwner,
) -> Bool {
  let byte_count_matches = payload.byte_count == 0L ||
    owner.byte_count == 0L ||
    payload.byte_count == owner.byte_count
  let checksum_matches = payload.checksum == "" ||
    owner.checksum == "" ||
    payload.checksum == owner.checksum
  byte_count_matches && checksum_matches
}

///|
fn merge_payload_view(
  payload : MoonDataPayloadView,
  owner : MoonDataPayloadOwner,
) -> MoonDataPayloadView {
  payload.owners.push(owner)
  let byte_count = if payload.byte_count == 0L {
    owner.byte_count
  } else {
    payload.byte_count
  }
  let checksum = if payload.checksum == "" {
    owner.checksum
  } else {
    payload.checksum
  }
  {
    ..payload,
    byte_count,
    checksum,
    owner_count: payload.owners.length(),
    metadata_consistent: payload.metadata_consistent &&
    metadata_matches(payload, owner),
  }
}

///|
fn payload_from_data_ref(view : MoonDataDataRefView) -> MoonDataPayloadView {
  let owner = owner_from_data_ref(view)
  {
    uri: view.data_ref.uri,
    relative_path: view.relative_path,
    local_path: view.local_path,
    payload_root: view.payload_root,
    local_status: view.local_status,
    byte_count: view.data_ref.byte_count,
    checksum: view.data_ref.checksum,
    owner_count: 1,
    metadata_consistent: true,
    owners: [owner],
  }
}

///|
fn push_payload_view(
  payloads : Array[MoonDataPayloadView],
  view : MoonDataDataRefView,
) -> Unit {
  match find_payload_index(payloads, view.data_ref.uri) {
    Some(index) => {
      let owner = owner_from_data_ref(view)
      payloads[index] = merge_payload_view(payloads[index], owner)
    }
    None => payloads.push(payload_from_data_ref(view))
  }
}

///|
fn metadata_status_matches(
  payload : MoonDataPayloadView,
  metadata_status : String,
) -> Bool {
  if metadata_status == "" {
    true
  } else if metadata_status == "consistent" {
    payload.metadata_consistent
  } else if metadata_status == "conflict" {
    !payload.metadata_consistent
  } else {
    false
  }
}

///|
fn payload_matches(
  payload : MoonDataPayloadView,
  query : MoonDataPayloadQuery,
) -> Bool {
  if query.payload_root != "" && payload.payload_root != query.payload_root {
    return false
  }
  metadata_status_matches(payload, query.metadata_status)
}

///|
fn payload_refs(
  payloads : Array[MoonDataPayloadView],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for payload in payloads {
    refs.push(
      @moondata_core.moondata_ref(
        "payload",
        payload.uri,
        if payload.local_path == "" {
          payload.uri
        } else {
          payload.local_path
        },
        "\{payload.local_status} \{payload.owner_count} owner(s)",
      ),
    )
  }
  refs
}

///|
fn payload_total_byte_count(payloads : Array[MoonDataPayloadView]) -> Int64 {
  let mut count = 0L
  for payload in payloads {
    count += payload.byte_count
  }
  count
}

///|
fn payload_owner_count(payloads : Array[MoonDataPayloadView]) -> Int {
  let mut count = 0
  for payload in payloads {
    count += payload.owner_count
  }
  count
}

///|
fn payload_checksums(payloads : Array[MoonDataPayloadView]) -> Array[String] {
  let checksums : Array[String] = []
  for payload in payloads {
    push_unique_checksum(checksums, payload.checksum)
  }
  checksums
}

///|
priv struct PayloadStatusSummary {
  present_count : Int
  missing_count : Int
  non_payload_count : Int
  unsafe_count : Int
  external_count : Int
  conflict_count : Int
}

///|
fn payload_status_summary(
  payloads : Array[MoonDataPayloadView],
) -> PayloadStatusSummary {
  let mut present_count = 0
  let mut missing_count = 0
  let mut non_payload_count = 0
  let mut unsafe_count = 0
  let mut external_count = 0
  let mut conflict_count = 0
  for payload in payloads {
    match payload.local_status {
      "present" => present_count += 1
      "missing" => missing_count += 1
      "non-payload" => non_payload_count += 1
      "unsafe" => unsafe_count += 1
      "external" => external_count += 1
      _ => ()
    }
    if !payload.metadata_consistent {
      conflict_count += 1
    }
  }
  {
    present_count,
    missing_count,
    non_payload_count,
    unsafe_count,
    external_count,
    conflict_count,
  }
}

///|
pub fn list_payloads(
  root : String,
  query? : MoonDataPayloadQuery = payload_query(),
) -> Result[MoonDataPayloadList, @moondata_store.MoonDataStoreIssue] {
  let data_refs = match
    list_data_refs(
      root,
      query=data_ref_query(
        artifact_kind=query.artifact_kind,
        artifact_id=query.artifact_id,
        data_kind=query.data_kind,
        uri_contains=query.uri_contains,
        local_status=query.local_status,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let all_payloads : Array[MoonDataPayloadView] = []
  for view in data_refs.data_refs {
    push_payload_view(all_payloads, view)
  }
  let payloads : Array[MoonDataPayloadView] = []
  for payload in all_payloads {
    if payload_matches(payload, query) {
      payloads.push(payload)
    }
  }
  let status = payload_status_summary(payloads)
  let owner_count = payload_owner_count(payloads)
  let byte_count = payload_total_byte_count(payloads)
  Ok({
    root,
    query,
    payload_count: payloads.length(),
    owner_count,
    total_byte_count: byte_count,
    checksums: payload_checksums(payloads),
    present_count: status.present_count,
    missing_count: status.missing_count,
    non_payload_count: status.non_payload_count,
    unsafe_count: status.unsafe_count,
    external_count: status.external_count,
    conflict_count: status.conflict_count,
    payloads,
    refs: payload_refs(payloads),
    summary: "MoonData payloads: \{payloads.length()} unique URI(s), \{owner_count} owner ref(s), \{byte_count} byte(s), \{status.present_count} present, \{status.missing_count} missing, \{status.conflict_count} conflict(s)",
  })
}
