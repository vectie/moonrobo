///|
pub(all) struct PipelineIssue {
  http_status : Int
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ObservationStartRequest {
  session_id : String
  receipt_id : String
  requester : @core.Requester
  now_ms : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ObservationStopRequest {
  receipt_id : String
  requester : @core.Requester
  now_ms : Int64
  telemetry_frame_count : Int
  latest_frame_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ObservationSubmission {
  persisted : Bool
  receipt_path : String
  observation_path : String
  telemetry_path : String
  session : @core.ObservationSession
  receipt : @core.RunReceipt
  bridge_response : @bridge_protocol.BridgeResponse
  result : PipelineResult
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ObservationFrameSubmission {
  persisted : Bool
  observation_path : String
  telemetry_path : String
  session : @core.ObservationSession
  frame : @core.TelemetryFrame
} derive(Debug, Eq, ToJson, FromJson)

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
pub(all) struct ObservationRunResult {
  persisted : Bool
  plan : @task.ObservationTaskPlan
  observation : ObservationSubmission
  frame_submissions : Array[ObservationFrameSubmission]
  stop : ObservationSubmission
  replay : @replay.ReplayTimeline
} derive(Debug, Eq, ToJson, FromJson)

///|
fn issue(
  http_status : Int,
  code : String,
  path : String,
  message : String,
) -> PipelineIssue {
  { http_status, code, path, message }
}

///|
fn runtime_issue(status : Int, error : @runtime.RuntimeIssue) -> PipelineIssue {
  issue(status, error.code, error.path, error.message)
}

///|
fn task_issue(path : String, error : @task.RobotTaskIssue) -> PipelineIssue {
  issue(400, error.code, path, error.message)
}

///|
fn generated_session_id(
  profile : @core.RobotProfile,
  request : ObservationStartRequest,
) -> String {
  if request.session_id == "" {
    "observe-\{profile.id}-\{request.now_ms}"
  } else {
    request.session_id
  }
}

///|
fn maybe_frame_id(value : String) -> String? {
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
fn observe_result(
  profile : @core.RobotProfile,
  requester : @core.Requester,
  receipt_id : @core.ReceiptId,
  now_ms : Int64,
) -> PipelineResult {
  evaluate_request(
    profile,
    @core.bridge_ok(profile.bridge.id, profile.id, last_telemetry_age_ms=0),
    observe_telemetry_intent(
      "intent-observe-\{receipt_id}",
      profile.id,
      requester,
    ),
    receipt_id,
    now_ms,
  )
}

///|
fn mock_observation_frame(
  profile : @core.RobotProfile,
  now_ms : Int64,
) -> @core.TelemetryFrame {
  let bridge = @mock_bridge.new(profile)
  {
    ..@mock_bridge.telemetry_frame(profile, bridge, now_ms),
    frame_id: "mock-\{profile.id}-\{now_ms}",
  }
}

///|
fn sdk_frame(
  profile : @core.RobotProfile,
  session_id : String,
  index : Int,
  captured_at_ms : Int64,
  path : String,
) -> Result[@core.TelemetryFrame, PipelineIssue] {
  let snapshot = {
    ..@sdk_e1.default_snapshot("sdk-\{session_id}-\{index}", captured_at_ms),
    joints: @sdk_e1.default_joint_states(profile),
  }
  match @sdk_e1.telemetry_frame(profile, snapshot) {
    Ok(frame) => Ok(frame)
    Err(error) => Err(issue(500, error.code, path, error.message))
  }
}

///|
fn latest_artifact_path(paths : Array[String]) -> String {
  if paths.is_empty() {
    ""
  } else {
    paths[paths.length() - 1]
  }
}

///|
fn ensure_observe_allowed(
  result : PipelineResult,
  path : String,
) -> PipelineIssue? {
  if result.next_action == Execute {
    None
  } else {
    Some(
      issue(
        400, "observation-not-allowed", path, "safety pipeline did not allow observation",
      ),
    )
  }
}

///|
pub fn start_observation(
  root : String,
  request : ObservationStartRequest,
) -> Result[ObservationSubmission, PipelineIssue] {
  let path = "pipeline:observation:start"
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(error) => return Err(runtime_issue(500, error))
  }
  let session_id = generated_session_id(book.profile, request)
  let result = observe_result(
    book.profile,
    request.requester,
    request.receipt_id,
    request.now_ms,
  )
  match ensure_observe_allowed(result, path) {
    Some(error) => return Err(error)
    None => ()
  }
  let frame = mock_observation_frame(book.profile, request.now_ms)
  let telemetry_path = match
    @runtime.write_telemetry_frame(root, session_id, frame) {
    Ok(path) => path
    Err(error) => return Err(runtime_issue(500, error))
  }
  let receipt = @core.executed_receipt(
    request.receipt_id,
    result.receipt,
    request.now_ms,
    telemetry_frame_count=1,
    artifact_paths=[telemetry_path],
  )
  let session = @core.observation_session(
    session_id,
    book.profile,
    request.requester,
    receipt.receipt_id,
    request.now_ms,
    telemetry_frame_count=1,
    latest_frame_id=frame.frame_id,
    artifact_paths=[telemetry_path],
  )
  let bridge_request = @bridge_protocol.start_observe_request(
    "request-observe-start-\{session_id}-\{request.now_ms}",
    book.profile,
    session_id,
    request.now_ms,
  )
  let bridge_response = @bridge_protocol.session_response(
    bridge_request, "observation session started",
  )
  let receipt_path = match @runtime.write_run_receipt(root, receipt) {
    Ok(path) => path
    Err(error) => return Err(runtime_issue(500, error))
  }
  let observation_path = match
    @runtime.write_observation_session(root, session) {
    Ok(path) => path
    Err(error) => return Err(runtime_issue(500, error))
  }
  Ok({
    persisted: true,
    receipt_path,
    observation_path,
    telemetry_path,
    session,
    receipt,
    bridge_response,
    result,
  })
}

///|
fn validate_observation_frame(
  session : @core.ObservationSession,
  frame : @core.TelemetryFrame,
  path : String,
) -> PipelineIssue? {
  if frame.robot_id != session.robot_id {
    return Some(
      issue(
        400, "frame-robot-mismatch", path, "telemetry frame robot does not match observation session",
      ),
    )
  }
  if frame.bridge_id != session.bridge_id {
    return Some(
      issue(
        400, "frame-bridge-mismatch", path, "telemetry frame bridge does not match observation session",
      ),
    )
  }
  None
}

///|
pub fn ingest_observation_frame(
  root : String,
  session_id : String,
  frame : @core.TelemetryFrame,
) -> Result[ObservationFrameSubmission, PipelineIssue] {
  let path = "pipeline:observation:\{session_id}:frame"
  let existing = match @runtime.read_observation_session(root, session_id) {
    Ok(session) => session
    Err(error) => return Err(runtime_issue(400, error))
  }
  if existing.status != Active {
    return Err(
      issue(
        400, "observation-not-active", path, "observation session is not active",
      ),
    )
  }
  match validate_observation_frame(existing, frame, path) {
    Some(error) => return Err(error)
    None => ()
  }
  let telemetry_path = @runtime.telemetry_frame_path(
    root,
    session_id,
    frame.frame_id,
  )
  if existing.artifact_paths.contains(telemetry_path) {
    return Err(
      issue(
        400, "duplicate-telemetry-frame", path, "telemetry frame already exists in this observation session",
      ),
    )
  }
  let written_path = match
    @runtime.write_telemetry_frame(root, session_id, frame) {
    Ok(path) => path
    Err(error) => return Err(runtime_issue(500, error))
  }
  let session = @core.observed_telemetry_frame(
    existing,
    frame.frame_id,
    written_path,
  )
  let observation_path = match
    @runtime.write_observation_session(root, session) {
    Ok(path) => path
    Err(error) => return Err(runtime_issue(500, error))
  }
  Ok({
    persisted: true,
    observation_path,
    telemetry_path: written_path,
    session,
    frame,
  })
}

///|
pub fn stop_observation(
  root : String,
  session_id : String,
  request : ObservationStopRequest,
) -> Result[ObservationSubmission, PipelineIssue] {
  let path = "pipeline:observation:\{session_id}:stop"
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(error) => return Err(runtime_issue(500, error))
  }
  let existing = match @runtime.read_observation_session(root, session_id) {
    Ok(session) => session
    Err(error) => return Err(runtime_issue(400, error))
  }
  if existing.status != Active {
    return Err(
      issue(
        400, "observation-not-active", path, "observation session is not active",
      ),
    )
  }
  let result = observe_result(
    book.profile,
    request.requester,
    request.receipt_id,
    request.now_ms,
  )
  match ensure_observe_allowed(result, path) {
    Some(error) => return Err(error)
    None => ()
  }
  let session = match maybe_frame_id(request.latest_frame_id) {
    Some(frame_id) =>
      @core.stopped_observation_session(
        existing,
        request.now_ms,
        request.telemetry_frame_count,
        latest_frame_id=frame_id,
      )
    None =>
      @core.stopped_observation_session(
        existing,
        request.now_ms,
        request.telemetry_frame_count,
      )
  }
  let receipt = @core.executed_receipt(
    request.receipt_id,
    result.receipt,
    request.now_ms,
    telemetry_frame_count=request.telemetry_frame_count,
    artifact_paths=session.artifact_paths,
  )
  let bridge_request = @bridge_protocol.stop_session_request(
    "request-observe-stop-\{session_id}-\{request.now_ms}",
    book.profile,
    session_id,
    request.now_ms,
  )
  let bridge_response = @bridge_protocol.session_response(
    bridge_request, "observation session stopped",
  )
  let receipt_path = match @runtime.write_run_receipt(root, receipt) {
    Ok(path) => path
    Err(error) => return Err(runtime_issue(500, error))
  }
  let observation_path = match
    @runtime.write_observation_session(root, session) {
    Ok(path) => path
    Err(error) => return Err(runtime_issue(500, error))
  }
  Ok({
    persisted: true,
    receipt_path,
    observation_path,
    telemetry_path: latest_artifact_path(session.artifact_paths),
    session,
    receipt,
    bridge_response,
    result,
  })
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
fn replay_timeline(
  root : String,
  session_id : String,
  path : String,
) -> Result[@replay.ReplayTimeline, PipelineIssue] {
  let session = match @runtime.read_observation_session(root, session_id) {
    Ok(session) => session
    Err(error) => return Err(runtime_issue(500, error))
  }
  let frame_paths = match
    @runtime.list_telemetry_frame_paths(root, session_id) {
    Ok(paths) => paths
    Err(error) => return Err(runtime_issue(500, error))
  }
  let frames = match @runtime.list_telemetry_frames(root, session_id) {
    Ok(frames) => frames
    Err(error) => return Err(runtime_issue(500, error))
  }
  if frames.length() != frame_paths.length() {
    return Err(
      issue(
        500, "replay-frame-mismatch", path, "replay frame paths and frames do not align",
      ),
    )
  }
  Ok(@replay.timeline(session, frame_paths, frames))
}

///|
fn latest_frame_id(
  observation : ObservationSubmission,
  frames : Array[ObservationFrameSubmission],
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
pub fn run_bounded_observation(
  root : String,
  request : ObservationRunRequest,
) -> Result[ObservationRunResult, PipelineIssue] {
  let path = "pipeline:observation-run"
  let book = match @runtime.load_robotbook(root) {
    Ok(book) => book
    Err(error) => return Err(runtime_issue(500, error))
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
    Err(error) => return Err(task_issue(path, error))
  }
  let observation = match
    start_observation(root, {
      session_id: plan.session_id,
      receipt_id: plan.receipt_id,
      requester: plan.requester,
      now_ms: plan.planned_at_ms,
    }) {
    Ok(response) => response
    Err(error) => return Err(error)
  }
  let frame_count = normalized_frame_count(request.frame_count)
  let interval = normalized_frame_interval(request.frame_interval_ms)
  let frame_submissions : Array[ObservationFrameSubmission] = []
  for index in 1..<frame_count {
    let captured_at_ms = request.now_ms + interval * index.to_int64()
    let frame = match
      sdk_frame(book.profile, plan.session_id, index, captured_at_ms, path) {
      Ok(frame) => frame
      Err(error) => return Err(error)
    }
    let submitted = match
      ingest_observation_frame(root, plan.session_id, frame) {
      Ok(response) => response
      Err(error) => return Err(error)
    }
    frame_submissions.push(submitted)
  }
  let stopped_at_ms = request.now_ms + interval * (frame_count - 1).to_int64()
  let stop = match
    stop_observation(root, plan.session_id, {
      receipt_id: "receipt-\{request.task_id}-observe-stop",
      requester: plan.requester,
      now_ms: stopped_at_ms,
      telemetry_frame_count: frame_count,
      latest_frame_id: latest_frame_id(observation, frame_submissions),
    }) {
    Ok(response) => response
    Err(error) => return Err(error)
  }
  let replay = match replay_timeline(root, plan.session_id, path) {
    Ok(timeline) => timeline
    Err(error) => return Err(error)
  }
  Ok({ persisted: true, plan, observation, frame_submissions, stop, replay })
}
