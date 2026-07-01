///|
pub(all) struct PlatformProofSessionRequest {
  session_id : String
  task_message : @task.RobotTaskMessageRequest
  iterations : Int
  max_steps : Int
  bootstrap : Bool
  stop_when_ready : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformProofSessionResponse {
  session_id : String
  session_path : String
  persisted : Bool
  status : String
  ready : Bool
  attempted_count : Int
  requested_iterations : Int
  stop_reason : String
  latest_proof_path : String
  next_route : String
  feedback_binding_required_count : Int
  feedback_binding_success_count : Int
  latest_feedback_binding_status : Int
  latest_feedback_binding_message : String
  attempts : Array[PlatformProveLoopResponse]
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformProofSessionListResponse {
  session_count : Int
  sessions : Array[PlatformProofSessionResponse]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_proof_session_path() -> String {
  "/api/moonrobo/proof-session"
}

///|
pub fn platform_proof_sessions_path() -> String {
  "/api/moonrobo/proof-sessions"
}

///|
pub fn platform_proof_session_detail_path(session_id : String) -> String {
  "/api/moonrobo/proof-sessions/\{session_id}"
}

///|
fn default_proof_session_request() -> PlatformProofSessionRequest {
  {
    session_id: "proof-session",
    task_message: @task.task_message_request(
      "proof-session",
      "",
      @core.operator_requester("proof-session"),
      "walk forward when ready",
      0L,
    ),
    iterations: 3,
    max_steps: 8,
    bootstrap: true,
    stop_when_ready: true,
  }
}

///|
fn bounded_proof_session_request(
  request : PlatformProofSessionRequest,
) -> PlatformProofSessionRequest {
  {
    session_id: if request.session_id == "" {
      "proof-session-\{request.task_message.now_ms}"
    } else {
      request.session_id
    },
    task_message: request.task_message,
    iterations: if request.iterations < 1 {
      1
    } else if request.iterations > 8 {
      8
    } else {
      request.iterations
    },
    max_steps: if request.max_steps < 1 {
      1
    } else if request.max_steps > 12 {
      12
    } else {
      request.max_steps
    },
    bootstrap: request.bootstrap,
    stop_when_ready: request.stop_when_ready,
  }
}

///|
fn decode_platform_proof_session_request(
  body : String,
) -> Result[PlatformProofSessionRequest, HostApiResponse] {
  let submitted = body.trim().to_owned()
  if submitted == "" || submitted == "{}" {
    return Ok(default_proof_session_request())
  }
  let json = @json.parse(submitted) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-platform-proof-session",
          platform_proof_session_path(),
          "failed to parse platform proof-session JSON",
        ),
      )
  }
  let request : PlatformProofSessionRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-platform-proof-session",
          platform_proof_session_path(),
          "failed to decode platform proof-session contract",
        ),
      )
  }
  Ok(bounded_proof_session_request(request))
}

///|
fn proof_session_safe_id(value : String) -> String {
  value
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn proof_session_dir(root : String) -> String {
  @runtime.moonrobo_proof_sessions_dir(root)
}

///|
fn proof_session_record_path(root : String, session_id : String) -> String {
  proof_session_dir(root) + "/\{proof_session_safe_id(session_id)}.json"
}

///|
fn proof_session_id_from_detail_path(path : String) -> String? {
  let prefix = platform_proof_sessions_path() + "/"
  if path.has_prefix(prefix) && path.length() > prefix.length() {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
fn list_proof_session_paths(
  root : String,
) -> Result[Array[String], HostApiResponse] {
  let dir = proof_session_dir(root)
  if !@fsx.path_exists(dir) {
    return Ok([])
  }
  let names = @fsx.read_dir(dir) catch {
    _ =>
      return Err(
        error_response(
          500, "read-proof-sessions", dir, "failed to read Moonrobo proof-session directory",
        ),
      )
  }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(dir + "/\{name}")
    }
  }
  Ok(paths)
}

///|
fn decode_proof_session_file(
  path : String,
  text : String,
) -> Result[PlatformProofSessionResponse, HostApiResponse] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        error_response(
          500, "parse-proof-session-artifact", path, "failed to parse Moonrobo proof-session artifact",
        ),
      )
  }
  let session : PlatformProofSessionResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-proof-session-artifact", path, "failed to decode Moonrobo proof-session artifact",
        ),
      )
  }
  Ok(session)
}

///|
fn read_proof_session_file(
  path : String,
) -> Result[PlatformProofSessionResponse, HostApiResponse] {
  let text = @fsx.read_file_to_string(path) catch {
    _ =>
      return Err(
        error_response(
          404, "read-proof-session", path, "failed to read Moonrobo proof-session artifact",
        ),
      )
  }
  decode_proof_session_file(path, text)
}

///|
fn ensure_proof_session_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = proof_session_dir(root)
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-proof-session-dir", dir, "failed to create Moonrobo proof-session directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn write_proof_session_response(
  root : String,
  response : PlatformProofSessionResponse,
) -> Result[String, HostApiResponse] {
  match ensure_proof_session_dir(root) {
    Ok(_) => ()
    Err(response) => return Err(response)
  }
  @fsx.write_string_to_file(
    response.session_path,
    response.to_json().stringify(indent=2),
  ) catch {
    _ =>
      return Err(
        error_response(
          500,
          "write-proof-session",
          response.session_path,
          "failed to persist Moonrobo proof-session artifact",
        ),
      )
  }
  Ok(response.session_path)
}

///|
fn proof_session_attempt_message(
  request : PlatformProofSessionRequest,
  attempt_index : Int,
) -> @task.RobotTaskMessageRequest {
  let base_id = if request.task_message.message_id == "" {
    request.session_id
  } else {
    request.task_message.message_id
  }
  @task.task_message_request(
    "\{proof_session_safe_id(base_id)}-attempt-\{attempt_index + 1}",
    request.task_message.robot_id,
    request.task_message.requested_by,
    request.task_message.message,
    request.task_message.now_ms + attempt_index.to_int64(),
  )
}

///|
fn proof_session_attempt_body(
  request : PlatformProofSessionRequest,
  attempt_index : Int,
) -> String {
  let prove : PlatformProveLoopRequest = {
    task_message: proof_session_attempt_message(request, attempt_index),
    max_steps: request.max_steps,
    bootstrap: request.bootstrap,
  }
  prove.to_json().stringify()
}

///|
fn decode_proof_session_attempt(
  response : HostApiResponse,
) -> Result[PlatformProveLoopResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch { _ => return Err(response) }
  let proof : PlatformProveLoopResponse = @json.from_json(json) catch {
    _ => return Err(response)
  }
  Ok(proof)
}

///|
fn proof_session_status(ready : Bool, stop_reason : String) -> String {
  if ready {
    "complete"
  } else if stop_reason == "stalled" {
    "blocked"
  } else {
    "pending"
  }
}

///|
fn proof_session_feedback_attempted_count(
  attempts : Array[PlatformProveLoopResponse],
) -> Int {
  let mut count = 0
  for attempt in attempts {
    if attempt.feedback_binding_required {
      count += 1
    }
  }
  count
}

///|
fn proof_session_feedback_success_count(
  attempts : Array[PlatformProveLoopResponse],
) -> Int {
  let mut count = 0
  for attempt in attempts {
    if attempt.feedback_binding_required &&
      attempt.feedback_binding_status >= 200 &&
      attempt.feedback_binding_status < 300 {
      count += 1
    }
  }
  count
}

///|
fn proof_session_latest_feedback_status(
  attempts : Array[PlatformProveLoopResponse],
) -> Int {
  let mut status = 0
  for attempt in attempts {
    if attempt.feedback_binding_required {
      status = attempt.feedback_binding_status
    }
  }
  status
}

///|
fn proof_session_latest_feedback_message(
  attempts : Array[PlatformProveLoopResponse],
) -> String {
  let mut message = ""
  for attempt in attempts {
    if attempt.feedback_binding_required {
      message = attempt.feedback_binding_message
    }
  }
  message
}

///|
fn proof_session_message(
  status : String,
  attempted_count : Int,
  next_route : String,
) -> String {
  match status {
    "complete" =>
      "Moonrobo proof session completed after \{attempted_count} attempt(s)."
    "blocked" =>
      "Moonrobo proof session stopped without new progress; continue with \{next_route}."
    _ =>
      "Moonrobo proof session ran \{attempted_count} attempt(s); continue with \{next_route}."
  }
}

///|
pub fn platform_proof_sessions_response(root : String) -> HostApiResponse {
  let paths = match list_proof_session_paths(root) {
    Ok(paths) => paths
    Err(response) => return response
  }
  let sessions : Array[PlatformProofSessionResponse] = []
  for path in paths {
    match read_proof_session_file(path) {
      Ok(session) => sessions.push(session)
      Err(response) => return response
    }
  }
  json_response(
    200,
    PlatformProofSessionListResponse::{
      session_count: sessions.length(),
      sessions,
    }.to_json(),
  )
}

///|
pub fn platform_proof_session_detail_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let session_id = match proof_session_id_from_detail_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo proof-session detail route",
      )
  }
  let file_path = proof_session_record_path(root, session_id)
  match read_proof_session_file(file_path) {
    Ok(session) => json_response(200, session.to_json())
    Err(response) => response
  }
}

///|
pub fn platform_proof_session_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_platform_proof_session_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let attempts : Array[PlatformProveLoopResponse] = []
  let mut stop_reason = "max-iterations"
  let mut previous_completed = -1
  let mut previous_next_route = ""
  for i in 0..<request.iterations {
    let attempt_response = platform_prove_loop_response(
      root,
      proof_session_attempt_body(request, i),
    )
    let attempt = match decode_proof_session_attempt(attempt_response) {
      Ok(proof) => proof
      Err(response) => return response
    }
    let completed = attempt.after.completed_count
    let next_route = attempt.next_route
    let ready = attempt.ready
    attempts.push(attempt)
    if request.stop_when_ready && ready {
      stop_reason = "ready"
      break
    }
    if previous_completed == completed && previous_next_route == next_route {
      stop_reason = "stalled"
      break
    }
    previous_completed = completed
    previous_next_route = next_route
  }
  let latest = if attempts.is_empty() {
    None
  } else {
    Some(attempts[attempts.length() - 1])
  }
  let ready = match latest {
    Some(proof) => proof.ready
    None => false
  }
  let next_route = match latest {
    Some(proof) => proof.next_route
    None => platform_prove_loop_path()
  }
  let latest_proof_path = match latest {
    Some(proof) => proof.proof_path
    None => ""
  }
  let feedback_binding_required_count = proof_session_feedback_attempted_count(
    attempts,
  )
  let feedback_binding_success_count = proof_session_feedback_success_count(
    attempts,
  )
  let latest_feedback_binding_status = proof_session_latest_feedback_status(
    attempts,
  )
  let latest_feedback_binding_message = proof_session_latest_feedback_message(
    attempts,
  )
  let status = proof_session_status(ready, stop_reason)
  let session_path = proof_session_record_path(root, request.session_id)
  let response : PlatformProofSessionResponse = {
    session_id: request.session_id,
    session_path,
    persisted: true,
    status,
    ready,
    attempted_count: attempts.length(),
    requested_iterations: request.iterations,
    stop_reason,
    latest_proof_path,
    next_route,
    feedback_binding_required_count,
    feedback_binding_success_count,
    latest_feedback_binding_status,
    latest_feedback_binding_message,
    attempts,
    message: proof_session_message(status, attempts.length(), next_route),
  }
  match write_proof_session_response(root, response) {
    Ok(_) => json_response(200, response.to_json())
    Err(error) => error
  }
}
