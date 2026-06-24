///|
pub(all) struct PlatformLiveProofRequest {
  task_loop : MoonClawTaskLoopRequest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformLiveProofResponse {
  proof_id : String
  proof_path : String
  persisted : Bool
  status : String
  verified : Bool
  task_id : String
  task_loop_status : Int
  task_loop : MoonClawTaskLoopResponse
  effective_loop : PlatformTaskLoopResponse
  readiness : @readiness.PlatformReadinessReport
  readiness_plan : @readiness.PlatformReadinessPlan
  execution_proof : TaskExecutionProofReport
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_live_proof_path() -> String {
  "/api/moonrobo/live-proof"
}

///|
fn decode_platform_live_proof_request(
  body : String,
) -> Result[PlatformLiveProofRequest, HostApiResponse] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-platform-live-proof",
          platform_live_proof_path(),
          "failed to parse platform live-proof JSON",
        ),
      )
  }
  let request : PlatformLiveProofRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-platform-live-proof",
          platform_live_proof_path(),
          "failed to decode platform live-proof contract",
        ),
      )
  }
  Ok(request)
}

///|
fn decode_live_proof_task_loop(
  response : HostApiResponse,
) -> Result[MoonClawTaskLoopResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          response.status,
          "parse-platform-live-proof-task-loop",
          platform_live_proof_path(),
          "MoonClaw task-loop returned invalid JSON",
        ),
      )
  }
  let result : MoonClawTaskLoopResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          response.status,
          "decode-platform-live-proof-task-loop",
          platform_live_proof_path(),
          "MoonClaw task-loop returned an unexpected contract",
        ),
      )
  }
  Ok(result)
}

///|
fn live_proof_effective_loop(
  task_loop : MoonClawTaskLoopResponse,
) -> PlatformTaskLoopResponse {
  match task_loop.final_loop {
    Some(final_loop) => final_loop
    None => task_loop.initial_loop
  }
}

///|
fn live_proof_id(task_id : String, now_ms : Int64) -> String {
  let id = if task_id == "" {
    "live-proof-\{now_ms}"
  } else {
    "live-proof-\{task_id}-\{now_ms}"
  }
  id
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn live_proof_dir(root : String) -> String {
  @runtime.robobook_path(root, "runs/live-proof")
}

///|
fn ensure_live_proof_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = live_proof_dir(root)
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-live-proof-dir", dir, "failed to create Moonrobo live-proof directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn write_live_proof_response(
  root : String,
  response : PlatformLiveProofResponse,
) -> Result[String, HostApiResponse] {
  let dir = match ensure_live_proof_dir(root) {
    Ok(dir) => dir
    Err(response) => return Err(response)
  }
  let path = dir + "/\{response.proof_id}.json"
  @fsx.write_string_to_file(path, response.to_json().stringify(indent=2)) catch {
    _ =>
      return Err(
        error_response(
          500, "write-live-proof", path, "failed to persist Moonrobo live-proof artifact",
        ),
      )
  }
  Ok(path)
}

///|
fn live_proof_next_route(
  effective_loop : PlatformTaskLoopResponse,
  readiness_plan : @readiness.PlatformReadinessPlan,
  verified : Bool,
) -> String {
  if verified {
    task_executions_path()
  } else if effective_loop.session.recovery_path != "" {
    effective_loop.session.recovery_path
  } else {
    match readiness_plan.next_action {
      Some(action) => action.route
      None => effective_loop.session.continuation_route
    }
  }
}

///|
fn live_proof_status(
  effective_loop : PlatformTaskLoopResponse,
  readiness : @readiness.PlatformReadinessReport,
) -> String {
  if effective_loop.session.execution_verified && readiness.ready {
    "verified"
  } else if effective_loop.session.execution_verified {
    "execution-verified-readiness-blocked"
  } else if effective_loop.session.recovery_path != "" {
    "blocked"
  } else if effective_loop.session.dispatch_ready &&
    !effective_loop.session.dispatch_requested {
    "dispatch-ready"
  } else {
    "pending"
  }
}

///|
fn live_proof_message(status : String, next_route : String) -> String {
  match status {
    "verified" =>
      "live proof verified; task execution, runtime evidence, and readiness agree"
    "execution-verified-readiness-blocked" =>
      "task execution is verified, but platform readiness still has blockers; continue with \{next_route}"
    "dispatch-ready" =>
      "task is ready for explicit dispatch; continue with \{next_route}"
    "blocked" => "live proof is blocked; continue with \{next_route}"
    _ => "live proof is pending; continue with \{next_route}"
  }
}

///|
pub fn platform_live_proof_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_platform_live_proof_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let task_loop_response = moonclaw_task_loop_response(
    root,
    request.task_loop.to_json().stringify(),
  )
  let task_loop = match decode_live_proof_task_loop(task_loop_response) {
    Ok(result) => result
    Err(response) => return response
  }
  let effective_loop = live_proof_effective_loop(task_loop)
  ignore(try_bind_latest_execution_feedback(root, "live-proof"))
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let readiness = @readiness.report(root, book)
  let readiness_plan = @readiness.plan(readiness)
  let execution_proof = match task_execution_proof_report(root) {
    Ok(report) => report
    Err(response) => return response
  }
  let verified = effective_loop.session.execution_verified && readiness.ready
  let status = live_proof_status(effective_loop, readiness)
  let next_route = live_proof_next_route(
    effective_loop, readiness_plan, verified,
  )
  let proof_id = live_proof_id(
    task_loop.task_id,
    request.task_loop.task_loop.task_message.now_ms,
  )
  let proof_path = live_proof_dir(root) + "/\{proof_id}.json"
  let response = PlatformLiveProofResponse::{
    proof_id,
    proof_path,
    persisted: true,
    status,
    verified,
    task_id: task_loop.task_id,
    task_loop_status: task_loop_response.status,
    task_loop,
    effective_loop,
    readiness,
    readiness_plan,
    execution_proof,
    next_route,
    message: live_proof_message(status, next_route),
  }
  match write_live_proof_response(root, response) {
    Ok(_) => json_response(task_loop_response.status, response.to_json())
    Err(error) => error
  }
}
