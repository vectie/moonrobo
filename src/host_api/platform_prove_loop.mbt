///|
pub(all) struct PlatformProveLoopRequest {
  task_message : @task.RobotTaskMessageRequest
  max_steps : Int
  allow_dispatch : Bool
  auto_continue : Bool
  bootstrap : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformProveLoopResponse {
  status : String
  ready : Bool
  advanced : Bool
  bootstrap_applied : Bool
  routine_attempted : Bool
  routine_http_status : Int
  before : PlatformLoopProofResponse
  bootstrap : PlatformBootstrapResponse?
  routine : MoonClawRobotRoutineResponse?
  after : PlatformLoopProofResponse
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn default_prove_loop_request() -> PlatformProveLoopRequest {
  {
    task_message: @task.task_message_request(
      "prove-loop",
      "",
      @core.operator_requester("prove-loop"),
      "walk forward when ready",
      0L,
    ),
    max_steps: 8,
    allow_dispatch: false,
    auto_continue: true,
    bootstrap: true,
  }
}

///|
fn bounded_prove_loop_request(
  request : PlatformProveLoopRequest,
) -> PlatformProveLoopRequest {
  {
    task_message: request.task_message,
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
  }
}

///|
fn decode_platform_prove_loop_request(
  body : String,
) -> Result[PlatformProveLoopRequest, HostApiResponse] {
  let submitted = body.trim().to_owned()
  if submitted == "" || submitted == "{}" {
    return Ok(default_prove_loop_request())
  }
  let json = @json.parse(submitted) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-platform-prove-loop",
          platform_prove_loop_path(),
          "failed to parse platform prove-loop JSON",
        ),
      )
  }
  let request : PlatformProveLoopRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-platform-prove-loop",
          platform_prove_loop_path(),
          "failed to decode platform prove-loop contract",
        ),
      )
  }
  Ok(bounded_prove_loop_request(request))
}

///|
fn decode_bootstrap_response(
  response : HostApiResponse,
) -> Result[PlatformBootstrapResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch { _ => return Err(response) }
  let result : PlatformBootstrapResponse = @json.from_json(json) catch {
    _ => return Err(response)
  }
  Ok(result)
}

///|
fn decode_robot_routine_response(
  response : HostApiResponse,
) -> Result[MoonClawRobotRoutineResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch { _ => return Err(response) }
  let result : MoonClawRobotRoutineResponse = @json.from_json(json) catch {
    _ => return Err(response)
  }
  Ok(result)
}

///|
fn prove_loop_routine_body(request : PlatformProveLoopRequest) -> String {
  MoonClawRobotRoutineRequest::{
    task_message: request.task_message,
    max_steps: request.max_steps,
    allow_dispatch: request.allow_dispatch,
    auto_continue: request.auto_continue,
  }
  .to_json()
  .stringify()
}

///|
fn prove_loop_message(
  after : PlatformLoopProofResponse,
  bootstrap_applied : Bool,
  routine_attempted : Bool,
  next_route : String,
) -> String {
  if after.ready {
    "Moonrobo closed-loop proof is complete for this RoboBook root."
  } else if routine_attempted {
    "Moonrobo prove-loop advanced to \{after.completed_count}/\{after.total_count}; continue with \{next_route}."
  } else if bootstrap_applied {
    "Moonrobo prove-loop bootstrapped non-physical substrate; continue with \{next_route}."
  } else {
    "Moonrobo prove-loop inspected current evidence; continue with \{next_route}."
  }
}

///|
pub fn platform_prove_loop_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_platform_prove_loop_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let before = match platform_loop_proof(root) {
    Ok(proof) => proof
    Err(response) => return response
  }
  let mut bootstrap_applied = false
  let mut bootstrap : PlatformBootstrapResponse? = None
  if request.bootstrap && !before.ready {
    let bootstrap_response = platform_bootstrap_response(
      root,
      request.task_message.to_json().stringify(),
    )
    bootstrap = Some(
      match decode_bootstrap_response(bootstrap_response) {
        Ok(result) => result
        Err(response) => return response
      },
    )
    bootstrap_applied = true
  }
  let routine_response = moonclaw_robot_routine_response(
    root,
    prove_loop_routine_body(request),
  )
  let routine = match decode_robot_routine_response(routine_response) {
    Ok(result) => Some(result)
    Err(response) => return response
  }
  let after = match platform_loop_proof(root) {
    Ok(proof) => proof
    Err(response) => return response
  }
  let routine_next_route = match routine {
    Some(value) => value.next_route
    None => ""
  }
  let next_route = if after.ready || routine_next_route == "" {
    after.next_route
  } else {
    routine_next_route
  }
  let advanced = after.completed_count > before.completed_count ||
    after.ready != before.ready
  let response : PlatformProveLoopResponse = {
    status: after.status,
    ready: after.ready,
    advanced,
    bootstrap_applied,
    routine_attempted: true,
    routine_http_status: routine_response.status,
    before,
    bootstrap,
    routine,
    after,
    next_route,
    message: prove_loop_message(after, bootstrap_applied, true, next_route),
  }
  json_response(200, response.to_json())
}
