///|
pub(all) struct ReplaySubmissionResponse {
  session_path : String
  frame_paths : Array[String]
  timeline : @replay.ReplayTimeline
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn replay_path(session_id : String) -> String {
  "/api/replays/\{session_id}"
}

///|
fn session_id_from_replay_path(path : String) -> String? {
  let prefix = "/api/replays/"
  if path.has_prefix(prefix) && path.length() > prefix.length() {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
pub fn replay_response(root : String, path : String) -> HostApiResponse {
  let session_id = match session_id_from_replay_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo host API route",
      )
  }
  let session = match @runtime.read_observation_session(root, session_id) {
    Ok(session) => session
    Err(issue) =>
      return error_response(400, issue.code, issue.path, issue.message)
  }
  let frame_paths = match
    @runtime.list_telemetry_frame_paths(root, session_id) {
    Ok(paths) => paths
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let frames : Array[@core.TelemetryFrame] = []
  for frame_path in frame_paths {
    match @runtime.read_telemetry_frame_file(frame_path) {
      Ok(frame) => frames.push(frame)
      Err(issue) =>
        return error_response(500, issue.code, issue.path, issue.message)
    }
  }
  json_response(
    200,
    {
      session_path: @runtime.observation_session_path(root, session_id),
      frame_paths,
      timeline: @replay.timeline(session, frame_paths, frames),
    }.to_json(),
  )
}
