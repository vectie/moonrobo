///|
pub(all) struct ObservationRunRequest {
  task_id : String
  robot_id : @core.RobotId
  requester : @core.Requester
  goal : String
  now_ms : Int64
  frame_count : Int
  frame_interval_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ObservationRunSubmissionResponse {
  persisted : Bool
  plan : @task.ObservationTaskPlan
  observation : ObservationSubmissionResponse
  frame_submissions : Array[ObservationFrameSubmissionResponse]
  stop : ObservationSubmissionResponse
  replay : @replay.ReplayTimeline
  resident : @resident.ResidentRobotAgent
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moontown_observe_run_path() -> String {
  "/api/moontown/tasks/observe-run"
}

///|
fn decode_observation_run_request(
  body : String,
  path : String,
) -> Result[ObservationRunRequest, HostApiError] {
  let json = @json.parse(body) catch {
    _ =>
      return Err({
        code: "parse-observation-run",
        path,
        message: "failed to parse observation run JSON",
      })
  }
  let request : ObservationRunRequest = @json.from_json(json) catch {
    _ =>
      return Err({
        code: "decode-observation-run",
        path,
        message: "failed to decode observation run contract",
      })
  }
  Ok(request)
}

///|
fn normalized_frame_count(value : Int) -> Int {
  if value < 1 {
    1
  } else {
    value
  }
}

///|
fn normalized_frame_interval(value : Int64) -> Int64 {
  if value < 1L {
    1L
  } else {
    value
  }
}

///|
fn sdk_frame(
  profile : @core.RobotProfile,
  session_id : String,
  index : Int,
  captured_at_ms : Int64,
  path : String,
) -> Result[@core.TelemetryFrame, HostApiResponse] {
  let snapshot = {
    ..@sdk_e1.default_snapshot("sdk-\{session_id}-\{index}", captured_at_ms),
    joints: @sdk_e1.default_joint_states(profile),
  }
  match @sdk_e1.telemetry_frame(profile, snapshot) {
    Ok(frame) => Ok(frame)
    Err(issue) => Err(error_response(500, issue.code, path, issue.message))
  }
}

///|
fn replay_timeline_or_response(
  root : String,
  session_id : String,
  path : String,
) -> Result[@replay.ReplayTimeline, HostApiResponse] {
  let session = match @runtime.read_observation_session(root, session_id) {
    Ok(session) => session
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let frame_paths = match
    @runtime.list_telemetry_frame_paths(root, session_id) {
    Ok(paths) => paths
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let frames = match @runtime.list_telemetry_frames(root, session_id) {
    Ok(frames) => frames
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  if frames.length() != frame_paths.length() {
    return Err(
      error_response(
        500, "replay-frame-mismatch", path, "replay frame paths and frames do not align",
      ),
    )
  }
  Ok(@replay.timeline(session, frame_paths, frames))
}

///|
fn latest_frame_id(
  observation : ObservationSubmissionResponse,
  frames : Array[ObservationFrameSubmissionResponse],
) -> String {
  if frames.is_empty() {
    match observation.session.latest_frame_id {
      Some(value) => value
      None => ""
    }
  } else {
    frames[frames.length() - 1].frame.frame_id
  }
}

///|
pub fn moontown_observe_run_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let path = moontown_observe_run_path()
  let request = match decode_observation_run_request(body, path) {
    Ok(request) => request
    Err(error) =>
      return error_response(400, error.code, error.path, error.message)
  }
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let task_request = @task.observe_task_request(
    request.task_id,
    request.robot_id,
    request.requester,
    request.goal,
    request.now_ms,
  )
  let plan = match @task.plan_observation_task(book.profile, task_request) {
    Ok(plan) => @task.accepted_plan(plan)
    Err(issue) => return error_response(400, issue.code, path, issue.message)
  }
  let observation = match
    start_observation_result(root, {
      session_id: plan.session_id,
      receipt_id: plan.receipt_id,
      requester: plan.requester,
      now_ms: plan.planned_at_ms,
    }) {
    Ok(response) => response
    Err(response) => return response
  }
  let frame_count = normalized_frame_count(request.frame_count)
  let interval = normalized_frame_interval(request.frame_interval_ms)
  let frame_submissions : Array[ObservationFrameSubmissionResponse] = []
  for index in 1..<frame_count {
    let captured_at_ms = request.now_ms + interval * index.to_int64()
    let frame = match
      sdk_frame(book.profile, plan.session_id, index, captured_at_ms, path) {
      Ok(frame) => frame
      Err(response) => return response
    }
    let submitted = match
      ingest_observation_frame_result(root, plan.session_id, path, frame) {
      Ok(response) => response
      Err(response) => return response
    }
    frame_submissions.push(submitted)
  }
  let stopped_at_ms = request.now_ms + interval * (frame_count - 1).to_int64()
  let stop = match
    stop_observation_result(root, plan.session_id, path, {
      receipt_id: "receipt-\{request.task_id}-observe-stop",
      requester: plan.requester,
      now_ms: stopped_at_ms,
      telemetry_frame_count: frame_count,
      latest_frame_id: latest_frame_id(observation, frame_submissions),
    }) {
    Ok(response) => response
    Err(response) => return response
  }
  let replay = match replay_timeline_or_response(root, plan.session_id, path) {
    Ok(timeline) => timeline
    Err(response) => return response
  }
  json_response(
    200,
    {
      persisted: true,
      plan,
      observation,
      frame_submissions,
      stop,
      replay,
      resident: resident_after_task(root, book),
    }.to_json(),
  )
}
