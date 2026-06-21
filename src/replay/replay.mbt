///|
pub(all) struct ReplayFrameSummary {
  frame_id : String
  artifact_path : String
  captured_at_ms : Int64
  mode : String
  joint_count : Int
  error_count : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ReplayTimeline {
  session_id : String
  robot_id : @core.RobotId
  bridge_id : @core.BridgeId
  status : String
  started_at_ms : Int64
  stopped_at_ms : Int64?
  telemetry_frame_count : Int
  latest_frame_id : String?
  frames : Array[ReplayFrameSummary]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn status_text(status : @core.ObservationStatus) -> String {
  match status {
    Active => "active"
    Stopped => "stopped"
  }
}

///|
pub fn frame_summary(
  artifact_path : String,
  frame : @core.TelemetryFrame,
) -> ReplayFrameSummary {
  {
    frame_id: frame.frame_id,
    artifact_path,
    captured_at_ms: frame.captured_at_ms,
    mode: frame.mode,
    joint_count: frame.joints.length(),
    error_count: frame.errors.length(),
  }
}

///|
pub fn timeline(
  session : @core.ObservationSession,
  frame_paths : Array[String],
  frames : Array[@core.TelemetryFrame],
) -> ReplayTimeline {
  let summaries : Array[ReplayFrameSummary] = []
  for index in 0..<frames.length() {
    let path = if index < frame_paths.length() {
      frame_paths[index]
    } else {
      ""
    }
    summaries.push(frame_summary(path, frames[index]))
  }
  {
    session_id: session.session_id,
    robot_id: session.robot_id,
    bridge_id: session.bridge_id,
    status: status_text(session.status),
    started_at_ms: session.started_at_ms,
    stopped_at_ms: session.stopped_at_ms,
    telemetry_frame_count: session.telemetry_frame_count,
    latest_frame_id: session.latest_frame_id,
    frames: summaries,
  }
}

///|
pub fn timeline_json(timeline : ReplayTimeline, indent? : Int = 2) -> String {
  timeline.to_json().stringify(indent~)
}
