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
  Ok({
    root,
    query,
    frame_count: frames.length(),
    frames,
    refs,
    summary: "MoonData frames: \{frames.length()} match(es)",
  })
}
