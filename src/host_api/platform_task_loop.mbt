///|
pub(all) struct PlatformTaskLoopRequest {
  task_message : @task.RobotTaskMessageRequest
  max_steps : Int
  allow_dispatch : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformTaskLoopResponse {
  submitted : Bool
  task_id : String
  task_message : MoontownTaskMessageResponse
  first_loop_status : Int
  first_loop : PlatformFirstLoopResponse
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_task_loop_path() -> String {
  "/api/moonrobo/task-loop"
}

///|
fn normalize_task_loop_request(
  request : PlatformTaskLoopRequest,
) -> PlatformTaskLoopRequest {
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
  }
}

///|
pub fn decode_platform_task_loop_request(
  body : String,
) -> Result[PlatformTaskLoopRequest, HostApiResponse] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-platform-task-loop",
          platform_task_loop_path(),
          "failed to parse platform task-loop JSON",
        ),
      )
  }
  let request : PlatformTaskLoopRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-platform-task-loop",
          platform_task_loop_path(),
          "failed to decode platform task-loop contract",
        ),
      )
  }
  Ok(normalize_task_loop_request(request))
}

///|
fn decode_task_loop_message_response(
  response : HostApiResponse,
) -> Result[MoontownTaskMessageResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-platform-task-loop-message",
          platform_task_loop_path(),
          "task-message ingress returned invalid JSON",
        ),
      )
  }
  let result : MoontownTaskMessageResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-platform-task-loop-message",
          platform_task_loop_path(),
          "task-message ingress returned an unexpected contract",
        ),
      )
  }
  Ok(result)
}

///|
fn decode_task_loop_first_loop_response(
  response : HostApiResponse,
) -> Result[PlatformFirstLoopResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-platform-task-loop-first-loop",
          platform_task_loop_path(),
          "first-loop returned invalid JSON",
        ),
      )
  }
  let result : PlatformFirstLoopResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-platform-task-loop-first-loop",
          platform_task_loop_path(),
          "first-loop returned an unexpected contract",
        ),
      )
  }
  Ok(result)
}

///|
pub fn platform_task_loop_first_loop_body(
  request : PlatformTaskLoopRequest,
  task_id : String,
  allow_dispatch? : Bool = false,
) -> String {
  PlatformFirstLoopRequest::{
    task_id,
    max_steps: request.max_steps,
    allow_dispatch,
  }
  .to_json()
  .stringify()
}

///|
pub fn platform_task_loop_compose_response(
  task_message : MoontownTaskMessageResponse,
  first_loop_response : HostApiResponse,
) -> HostApiResponse {
  let first_loop = match
    decode_task_loop_first_loop_response(first_loop_response) {
    Ok(result) => result
    Err(response) => return response
  }
  json_response(
    first_loop_response.status,
    PlatformTaskLoopResponse::{
      submitted: true,
      task_id: task_message.message_plan.task.task_id,
      task_message,
      first_loop_status: first_loop_response.status,
      first_loop,
    }.to_json(),
  )
}

///|
pub fn platform_task_loop_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_platform_task_loop_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let task_message_response = moontown_task_message_response(
    root,
    request.task_message.to_json().stringify(),
  )
  if task_message_response.status < 200 || task_message_response.status >= 300 {
    return task_message_response
  }
  let task_message = match
    decode_task_loop_message_response(task_message_response) {
    Ok(result) => result
    Err(response) => return response
  }
  let first_loop = platform_first_loop_response(
    root,
    platform_task_loop_first_loop_body(
      request,
      task_message.message_plan.task.task_id,
      allow_dispatch=false,
    ),
  )
  platform_task_loop_compose_response(task_message, first_loop)
}
