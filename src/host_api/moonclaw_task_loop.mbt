///|
pub(all) struct MoonClawTaskLoopRequest {
  task_loop : PlatformTaskLoopRequest
  auto_continue : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawTaskLoopResponse {
  task_id : String
  remediated : Bool
  continued : Bool
  initial_status : Int
  final_status : Int
  initial_loop : PlatformTaskLoopResponse
  gateway : MoonClawTaskLoopGatewayResult?
  final_loop : PlatformTaskLoopResponse?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawTaskLoopGatewayResult {
  route : String
  status : Int
  evidence_path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moonclaw_task_loop_path() -> String {
  "/api/moonclaw/task-loop"
}

///|
fn decode_moonclaw_task_loop_request(
  body : String,
) -> Result[MoonClawTaskLoopRequest, HostApiResponse] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-moonclaw-task-loop",
          moonclaw_task_loop_path(),
          "failed to parse MoonClaw task-loop JSON",
        ),
      )
  }
  let request : MoonClawTaskLoopRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-moonclaw-task-loop",
          moonclaw_task_loop_path(),
          "failed to decode MoonClaw task-loop contract",
        ),
      )
  }
  Ok({
    task_loop: {
      ..request.task_loop,
      max_steps: if request.task_loop.max_steps < 1 {
        1
      } else if request.task_loop.max_steps > 12 {
        12
      } else {
        request.task_loop.max_steps
      },
    },
    auto_continue: request.auto_continue,
  })
}

///|
fn decode_task_loop_response(
  response : HostApiResponse,
  path : String,
) -> Result[PlatformTaskLoopResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500, "parse-moonclaw-task-loop-result", path, "task-loop returned invalid JSON",
        ),
      )
  }
  let result : PlatformTaskLoopResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-moonclaw-task-loop-result", path, "task-loop returned an unexpected contract",
        ),
      )
  }
  Ok(result)
}

///|
fn runtime_revalidation_recovery(task_loop : PlatformTaskLoopResponse) -> Bool {
  match task_loop.recovery {
    Some(recovery) =>
      recovery.path == runtime_validation_session_path() ||
      recovery.kind == "runtime-validation-current"
    None => false
  }
}

///|
fn gateway_succeeded(gateway : MoonClawTaskLoopGatewayResult?) -> Bool {
  match gateway {
    Some(value) => value.status >= 200 && value.status < 300
    None => false
  }
}

///|
fn validation_gateway_result(
  response : HostApiResponse,
) -> MoonClawTaskLoopGatewayResult {
  if response.status >= 200 && response.status < 300 {
    let json = @json.parse(response.body) catch {
      _ =>
        return {
          route: runtime_validation_session_path(),
          status: response.status,
          evidence_path: runtime_validation_session_path(),
          message: response.body,
        }
    }
    let result : @runtime.RuntimeValidationSessionResult = @json.from_json(json) catch {
      _ =>
        return {
          route: runtime_validation_session_path(),
          status: response.status,
          evidence_path: runtime_validation_session_path(),
          message: response.body,
        }
    }
    {
      route: runtime_validation_session_path(),
      status: response.status,
      evidence_path: result.session_path,
      message: result.session.message,
    }
  } else {
    {
      route: runtime_validation_session_path(),
      status: response.status,
      evidence_path: runtime_validation_session_path(),
      message: response.body,
    }
  }
}

///|
fn task_loop_continue_body(
  task_id : String,
  max_steps : Int,
  allow_dispatch : Bool,
) -> String {
  PlatformTaskLoopContinueRequest::{ task_id, max_steps, allow_dispatch }
  .to_json()
  .stringify()
}

///|
pub fn moonclaw_task_loop_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_moonclaw_task_loop_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let initial_response = platform_task_loop_response(
    root,
    request.task_loop.to_json().stringify(),
  )
  let initial = match
    decode_task_loop_response(initial_response, platform_task_loop_path()) {
    Ok(value) => value
    Err(response) => return response
  }
  let mut gateway : MoonClawTaskLoopGatewayResult? = None
  let mut final_loop : PlatformTaskLoopResponse? = None
  let mut final_status = initial_response.status
  if request.auto_continue &&
    initial_response.status == 409 &&
    runtime_revalidation_recovery(initial) {
    let recovery = validation_gateway_result(
      runtime_validation_session_response(root, ""),
    )
    gateway = Some(recovery)
    if gateway_succeeded(gateway) {
      let continued_response = platform_task_loop_continue_response(
        root,
        task_loop_continue_body(
          initial.task_id,
          request.task_loop.max_steps,
          request.task_loop.allow_dispatch,
        ),
      )
      let continued = match
        decode_task_loop_response(
          continued_response,
          platform_task_loop_continue_path(),
        ) {
        Ok(value) => value
        Err(response) => return response
      }
      final_status = continued_response.status
      final_loop = Some(continued)
    }
  }
  json_response(
    final_status,
    {
      task_id: initial.task_id,
      remediated: gateway_succeeded(gateway),
      continued: final_loop is Some(_),
      initial_status: initial_response.status,
      final_status,
      initial_loop: initial,
      gateway,
      final_loop,
    }.to_json(),
  )
}
