///|
pub(all) struct EpisodeManifest {
  episode_id : EpisodeId
  dataset_id : DatasetId
  robot_id : String
  bridge_id : String
  session_id : String
  task_id : String
  status : String
  started_at_ms : Int64
  stopped_at_ms : Int64?
  frame_count : Int
  timebase : String
  receipt_ids : Array[String]
  frame_ids : Array[FrameId]
  data_refs : Array[DataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn episode_manifest(
  episode_id : EpisodeId,
  dataset_id : DatasetId,
  robot_id : String,
  bridge_id : String,
  session_id : String,
  status : String,
  started_at_ms : Int64,
  stopped_at_ms? : Int64? = None,
  frame_count? : Int = 0,
  frame_ids? : Array[FrameId] = [],
  receipt_ids? : Array[String] = [],
  data_refs? : Array[DataRef] = [],
  task_id? : String = "",
  timebase? : String = "unix-ms",
) -> EpisodeManifest {
  {
    episode_id,
    dataset_id,
    robot_id,
    bridge_id,
    session_id,
    task_id,
    status,
    started_at_ms,
    stopped_at_ms,
    frame_count,
    timebase,
    receipt_ids,
    frame_ids,
    data_refs,
  }
}
