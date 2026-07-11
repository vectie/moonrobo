///|
pub(all) struct CaptureSession {
  capture_id : CaptureId
  source_id : SourceId
  robot_id : String
  bridge_id : String
  status : String
  started_at_ms : Int64
  stopped_at_ms : Int64?
  receipt_ids : Array[String]
  data_refs : Array[DataRef]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn capture_session(
  capture_id : CaptureId,
  source_id : SourceId,
  robot_id : String,
  bridge_id : String,
  status : String,
  started_at_ms : Int64,
  stopped_at_ms? : Int64? = None,
  receipt_ids? : Array[String] = [],
  data_refs? : Array[DataRef] = [],
) -> CaptureSession {
  {
    capture_id,
    source_id,
    robot_id,
    bridge_id,
    status,
    started_at_ms,
    stopped_at_ms,
    receipt_ids,
    data_refs,
  }
}
