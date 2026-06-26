///|
pub(all) struct RoboStepRequest {
  run_id : String
  max_steps : Int
  now_ms : Int64
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboStepResponse {
  step_id : String
  step_path : String
  persisted : Bool
  status : String
  advanced : Bool
  blocked_reason : String
  decision_before : RoboDecisionResponse
  decision_after : RoboDecisionResponse
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboStepListResponse {
  step_count : Int
  steps : Array[RoboStepResponse]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robo_step_path() -> String {
  "/api/moonrobo/step"
}

///|
pub fn robo_steps_path() -> String {
  "/api/moonrobo/steps"
}

///|
pub fn robo_step_detail_path(step_id : String) -> String {
  "/api/moonrobo/steps/\{step_id}"
}

///|
fn step_id_from_robo_step_detail_path(path : String) -> String? {
  let prefix = robo_steps_path() + "/"
  if path.has_prefix(prefix) && path.length() > prefix.length() {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
fn default_robo_step_request() -> RoboStepRequest {
  { run_id: "", max_steps: 4, now_ms: 0L, remember: true }
}

///|
fn bounded_robo_step_steps(max_steps : Int) -> Int {
  if max_steps < 1 {
    1
  } else if max_steps > 12 {
    12
  } else {
    max_steps
  }
}

///|
fn decode_robo_step_request(
  body : String,
) -> Result[RoboStepRequest, HostApiResponse] {
  if body == "" {
    return Ok(default_robo_step_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-robo-step",
          robo_step_path(),
          "failed to parse Robo step JSON",
        ),
      )
  }
  let request : RoboStepRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-robo-step",
          robo_step_path(),
          "failed to decode Robo step contract",
        ),
      )
  }
  Ok({
    run_id: request.run_id,
    max_steps: bounded_robo_step_steps(request.max_steps),
    now_ms: request.now_ms,
    remember: request.remember,
  })
}

///|
fn decode_robo_step_decision(
  response : HostApiResponse,
) -> Result[RoboDecisionResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-step-decision",
          robo_step_path(),
          "failed to parse Robo decision response during step",
        ),
      )
  }
  let decision : RoboDecisionResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-step-decision",
          robo_step_path(),
          "failed to decode Robo decision response during step",
        ),
      )
  }
  Ok(decision)
}

///|
fn robo_step_run_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = @runtime.robobook_path(root, "runs/robo-steps")
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-robo-step-dir", dir, "failed to create Robo step artifact directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn write_robo_step_response(
  root : String,
  response : RoboStepResponse,
) -> Result[String, HostApiResponse] {
  let dir = match robo_step_run_dir(root) {
    Ok(dir) => dir
    Err(response) => return Err(response)
  }
  let path = dir + "/\{response.step_id}.json"
  @fsx.write_string_to_file(path, response.to_json().stringify(indent=2)) catch {
    _ =>
      return Err(
        error_response(
          500, "write-robo-step", path, "failed to persist Robo step artifact",
        ),
      )
  }
  Ok(path)
}

///|
fn decode_robo_step_file(
  path : String,
  text : String,
) -> Result[RoboStepResponse, HostApiResponse] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        error_response(
          500, "parse-robo-step-artifact", path, "failed to parse Robo step artifact",
        ),
      )
  }
  let step : RoboStepResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-robo-step-artifact", path, "failed to decode Robo step artifact",
        ),
      )
  }
  Ok(step)
}

///|
fn read_robo_step_file(
  path : String,
) -> Result[RoboStepResponse, HostApiResponse] {
  let text = match @runtime.read_robo_step_json_file(path) {
    Ok(text) => text
    Err(issue) =>
      return Err(error_response(404, issue.code, issue.path, issue.message))
  }
  decode_robo_step_file(path, text)
}

///|
pub fn robo_steps_response(root : String) -> HostApiResponse {
  let paths = match @runtime.list_robo_step_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let steps : Array[RoboStepResponse] = []
  for path in paths {
    match read_robo_step_file(path) {
      Ok(step) => steps.push(step)
      Err(response) => return response
    }
  }
  json_response(
    200,
    RoboStepListResponse::{ step_count: steps.length(), steps }.to_json(),
  )
}

///|
pub fn robo_step_detail_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let step_id = match step_id_from_robo_step_detail_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo step detail route",
      )
  }
  let text = match @runtime.read_robo_step_json(root, step_id) {
    Ok(text) => text
    Err(issue) =>
      return error_response(404, issue.code, issue.path, issue.message)
  }
  match decode_robo_step_file(path, text) {
    Ok(step) => json_response(200, step.to_json())
    Err(response) => response
  }
}

///|
fn robo_step_id(
  request : RoboStepRequest,
  decision : RoboDecisionResponse,
) -> String {
  let id = if request.run_id == "" {
    "robo-step-\{decision.robot_id}-\{decision.next_kind}-\{request.now_ms}"
  } else {
    request.run_id
  }
  id
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn idle_step_status(
  decision : RoboDecisionResponse,
) -> (String, String, String) {
  if decision.needs_operator {
    (
      "needs-operator",
      decision.next_kind,
      "Robo step stopped because the current decision belongs to the operator.",
    )
  } else if decision.accepts_task_messages {
    (
      "ready-for-task", "", "Robo step stopped because the loop is ready for a new task message.",
    )
  } else {
    (
      "idle",
      decision.next_kind,
      "Robo step found no MoonClaw-owned work to advance.",
    )
  }
}

///|
fn step_message(response : RoboStepResponse) -> String {
  if response.advanced {
    "Moonrobo advanced the current MoonClaw-owned decision through the gateway and persisted the step."
  } else if response.status == "agent-ready" {
    "Moonrobo persisted the pending MoonClaw-owned decision without running agent policy locally."
  } else {
    response.message
  }
}

///|
pub fn robo_step_response(root : String, body : String) -> HostApiResponse {
  let request = match decode_robo_step_request(body) {
    Ok(value) => value
    Err(response) => return response
  }
  let before_response = robo_decision_response(root)
  if before_response.status < 200 || before_response.status >= 300 {
    return before_response
  }
  let decision_before = match decode_robo_step_decision(before_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let step_id = robo_step_id(request, decision_before)
  let step_path = @runtime.robobook_path(
    root,
    "runs/robo-steps/\{step_id}.json",
  )
  let advanced = false
  let mut status = ""
  let mut blocked_reason = ""
  let mut message = ""
  if decision_before.needs_agent {
    status = "agent-ready"
    blocked_reason = decision_before.next_kind
    message = "MoonClaw owns this decision; Moonrobo exposes the target tool but does not run the agent loop."
  } else {
    let (idle_status, idle_blocker, idle_message) = idle_step_status(
      decision_before,
    )
    status = idle_status
    blocked_reason = idle_blocker
    message = idle_message
  }
  let after_response = robo_decision_response(root)
  if after_response.status < 200 || after_response.status >= 300 {
    return after_response
  }
  let decision_after = match decode_robo_step_decision(after_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let response : RoboStepResponse = {
    step_id,
    step_path,
    persisted: true,
    status,
    advanced,
    blocked_reason,
    decision_before,
    decision_after,
    message,
  }
  let response = { ..response, message: step_message(response) }
  let path = match write_robo_step_response(root, response) {
    Ok(path) => path
    Err(response) => return response
  }
  json_response(200, { ..response, step_path: path }.to_json())
}
