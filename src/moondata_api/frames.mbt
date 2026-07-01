///|
pub(all) struct MoonDataFrameQuery {
  episode_id : String
  robot_id : String
  bridge_id : String
  data_kind : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonDataFrameList {
  root : String
  query : MoonDataFrameQuery
  frame_count : Int
  payload_ref_count : Int
  signal_ref_count : Int
  media_ref_count : Int
  data_ref_count : Int
  total_data_byte_count : Int64
  latest_frame_id : String
  latest_frame_captured_at_ms : Int64
  frames : Array[@moondata_core.FrameRef]
  refs : Array[@moondata_core.MoonDataRef]
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn frame_query(
  episode_id? : String = "",
  robot_id? : String = "",
  bridge_id? : String = "",
  data_kind? : String = "",
) -> MoonDataFrameQuery {
  { episode_id, robot_id, bridge_id, data_kind }
}

///|
fn frame_query_has_filters(query : MoonDataFrameQuery) -> Bool {
  query.episode_id != "" ||
  query.robot_id != "" ||
  query.bridge_id != "" ||
  query.data_kind != ""
}

///|
fn frame_ref_has_kind(
  refs : Array[@moondata_core.DataRef],
  data_kind : String,
) -> Bool {
  for data_ref in refs {
    if data_ref.kind == data_kind {
      return true
    }
  }
  false
}

///|
fn frame_has_data_kind(
  frame : @moondata_core.FrameRef,
  data_kind : String,
) -> Bool {
  if data_kind == "" {
    return true
  }
  match frame.payload_ref {
    Some(data_ref) => if data_ref.kind == data_kind { return true }
    None => ()
  }
  frame_ref_has_kind(frame.signal_refs, data_kind) ||
  frame_ref_has_kind(frame.media_refs, data_kind)
}

///|
fn frame_matches(
  frame : @moondata_core.FrameRef,
  query : MoonDataFrameQuery,
) -> Bool {
  if query.episode_id != "" && frame.episode_id != query.episode_id {
    return false
  }
  if query.robot_id != "" && frame.robot_id != query.robot_id {
    return false
  }
  if query.bridge_id != "" && frame.bridge_id != query.bridge_id {
    return false
  }
  frame_has_data_kind(frame, query.data_kind)
}

///|
fn frame_inventory_refs(
  root : String,
  frames : Array[@moondata_core.FrameRef],
) -> Array[@moondata_core.MoonDataRef] {
  let refs : Array[@moondata_core.MoonDataRef] = []
  for frame in frames {
    refs.push(
      @moondata_core.moondata_ref(
        "frame",
        frame.frame_id,
        @moondata_store.frame_path(root, frame.frame_id),
        "\{frame.episode_id} frame \{frame.sequence_index}",
      ),
    )
  }
  refs
}

///|
priv struct FrameListSummary {
  payload_ref_count : Int
  signal_ref_count : Int
  media_ref_count : Int
  data_ref_count : Int
  total_data_byte_count : Int64
  latest_frame_id : String
  latest_frame_captured_at_ms : Int64
}

///|
fn frame_list_summary(
  frames : Array[@moondata_core.FrameRef],
) -> FrameListSummary {
  let mut payload_ref_count = 0
  let mut signal_ref_count = 0
  let mut media_ref_count = 0
  let mut data_ref_count = 0
  let mut total_data_byte_count = 0L
  let mut latest_id = ""
  let mut latest_captured_at_ms = -1L
  for frame in frames {
    match frame.payload_ref {
      Some(data_ref) => {
        payload_ref_count += 1
        data_ref_count += 1
        total_data_byte_count += data_ref.byte_count
      }
      None => ()
    }
    signal_ref_count += frame.signal_refs.length()
    media_ref_count += frame.media_refs.length()
    for data_ref in frame.signal_refs {
      data_ref_count += 1
      total_data_byte_count += data_ref.byte_count
    }
    for data_ref in frame.media_refs {
      data_ref_count += 1
      total_data_byte_count += data_ref.byte_count
    }
    if frame.captured_at_ms > latest_captured_at_ms {
      latest_id = frame.frame_id
      latest_captured_at_ms = frame.captured_at_ms
    }
  }
  if latest_id == "" {
    return {
      payload_ref_count,
      signal_ref_count,
      media_ref_count,
      data_ref_count,
      total_data_byte_count,
      latest_frame_id: "",
      latest_frame_captured_at_ms: 0L,
    }
  }
  {
    payload_ref_count,
    signal_ref_count,
    media_ref_count,
    data_ref_count,
    total_data_byte_count,
    latest_frame_id: latest_id,
    latest_frame_captured_at_ms: latest_captured_at_ms,
  }
}

///|
pub fn list_frames(
  root : String,
  query? : MoonDataFrameQuery = frame_query(),
) -> Result[MoonDataFrameList, @moondata_store.MoonDataStoreIssue] {
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let frames : Array[@moondata_core.FrameRef] = []
  for entry in catalog.entries {
    if entry.artifact_kind == "frame" {
      let frame = match @moondata_store.read_frame(root, entry.artifact_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let matches = if frame_query_has_filters(query) {
        frame_matches(frame, query)
      } else {
        true
      }
      if matches {
        frames.push(frame)
      }
    }
  }
  let refs = frame_inventory_refs(root, frames)
  let evidence = frame_list_summary(frames)
  Ok({
    root,
    query,
    frame_count: frames.length(),
    payload_ref_count: evidence.payload_ref_count,
    signal_ref_count: evidence.signal_ref_count,
    media_ref_count: evidence.media_ref_count,
    data_ref_count: evidence.data_ref_count,
    total_data_byte_count: evidence.total_data_byte_count,
    latest_frame_id: evidence.latest_frame_id,
    latest_frame_captured_at_ms: evidence.latest_frame_captured_at_ms,
    frames,
    refs,
    summary: "MoonData frames: \{frames.length()} match(es), \{evidence.data_ref_count} data ref(s), \{evidence.total_data_byte_count} byte(s), latest \{evidence.latest_frame_id}",
  })
}
