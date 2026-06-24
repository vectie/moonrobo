///|
pub(all) struct PlatformProofSessionRequest {
  session_id : String
  task_message : @task.RobotTaskMessageRequest
  iterations : Int
  max_steps : Int
  allow_dispatch : Bool
  auto_continue : Bool
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
  attempts : Array[PlatformProveLoopResponse]
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_proof_session_path() -> String {
  "/api/moonrobo/proof-session"
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
    allow_dispatch: false,
    auto_continue: true,
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
    allow_dispatch: request.allow_dispatch,
    auto_continue: request.auto_continue,
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
  @runtime.robobook_path(root, "runs/proof-sessions")
}

///|
fn proof_session_record_path(root : String, session_id : String) -> String {
  proof_session_dir(root) + "/\{proof_session_safe_id(session_id)}.json"
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
    allow_dispatch: request.allow_dispatch,
    auto_continue: request.auto_continue,
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
    attempts,
    message: proof_session_message(status, attempts.length(), next_route),
  }
  match write_proof_session_response(root, response) {
    Ok(_) => json_response(200, response.to_json())
    Err(error) => error
  }
}
