///|
pub(all) struct FrameRef {
  frame_id : FrameId
  episode_id : EpisodeId
  robot_id : String
  bridge_id : String
  sequence_index : Int
  captured_at_ms : Int64
  payload_ref : DataRef?
  signal_refs : Array[DataRef]
  media_refs : Array[DataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn frame_ref(
  frame_id : FrameId,
  episode_id : EpisodeId,
  robot_id : String,
  bridge_id : String,
  sequence_index : Int,
  captured_at_ms : Int64,
  payload_ref? : DataRef? = None,
  signal_refs? : Array[DataRef] = [],
  media_refs? : Array[DataRef] = [],
) -> FrameRef {
  {
    frame_id,
    episode_id,
    robot_id,
    bridge_id,
    sequence_index,
    captured_at_ms,
    payload_ref,
    signal_refs,
    media_refs,
  }
}
