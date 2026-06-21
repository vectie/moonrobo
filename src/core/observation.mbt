///|
pub(all) enum ObservationStatus {
  Active
  Stopped
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ObservationSession {
  session_id : String
  robot_id : RobotId
  bridge_id : BridgeId
  requested_by : Requester
  status : ObservationStatus
  started_at_ms : Int64
  stopped_at_ms : Int64?
  telemetry_frame_count : Int
  latest_frame_id : String?
  receipt_id : ReceiptId
  artifact_paths : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn observation_session(
  session_id : String,
  profile : RobotProfile,
  requested_by : Requester,
  receipt_id : ReceiptId,
  started_at_ms : Int64,
  telemetry_frame_count? : Int = 0,
  latest_frame_id? : String,
  artifact_paths? : Array[String] = [],
) -> ObservationSession {
  {
    session_id,
    robot_id: profile.id,
    bridge_id: profile.bridge.id,
    requested_by,
    status: Active,
    started_at_ms,
    stopped_at_ms: None,
    telemetry_frame_count,
    latest_frame_id,
    receipt_id,
    artifact_paths,
  }
}

///|
pub fn stopped_observation_session(
  session : ObservationSession,
  stopped_at_ms : Int64,
  telemetry_frame_count : Int,
  latest_frame_id? : String,
  artifact_paths? : Array[String] = session.artifact_paths,
) -> ObservationSession {
  {
    ..session,
    status: Stopped,
    stopped_at_ms: Some(stopped_at_ms),
    telemetry_frame_count,
    latest_frame_id,
    artifact_paths,
  }
}
