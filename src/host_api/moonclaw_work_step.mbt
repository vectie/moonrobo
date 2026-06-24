///|
pub(all) struct MoonClawWorkStepRequest {
  work_id : String
  now_ms : Int64
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawWorkStepResponse {
  step_id : String
  step_path : String
  persisted : Bool
  status : String
  dispatched : Bool
  work_id : String
  action_kind : String
  action_route : String
  context_before : @moonclaw.MoonClawPlanningResult
  dispatch_status : Int
  dispatch : Json
  context_after : @moonclaw.MoonClawPlanningResult
  memory_updated : Bool
  memory_path : String
  memory_pack_id : String
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawWorkRunRequest {
  run_id : String
  max_steps : Int
  now_ms : Int64
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonClawWorkRunResponse {
  run_id : String
  run_path : String
  persisted : Bool
  status : String
  step_count : Int
  dispatched_count : Int
  blocked_count : Int
  stop_reason : String
  context_before : @moonclaw.MoonClawPlanningResult
  steps : Array[MoonClawWorkStepResponse]
  context_after : @moonclaw.MoonClawPlanningResult
  memory_path : String
  memory_pack_id : String
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moonclaw_work_step_path() -> String {
  "/api/moonclaw/work-step"
}

///|
pub fn moonclaw_work_run_path() -> String {
  "/api/moonclaw/work-run"
}

///|
fn default_moonclaw_work_step_request() -> MoonClawWorkStepRequest {
  { work_id: "", now_ms: 0L, remember: true }
}

///|
fn default_moonclaw_work_run_request() -> MoonClawWorkRunRequest {
  { run_id: "", max_steps: 4, now_ms: 0L, remember: true }
}

///|
fn bounded_work_run_steps(max_steps : Int) -> Int {
  if max_steps < 1 {
    1
  } else if max_steps > 12 {
    12
  } else {
    max_steps
  }
}

///|
fn decode_moonclaw_work_step_request(
  body : String,
) -> Result[MoonClawWorkStepRequest, HostApiResponse] {
  if body == "" {
    return Ok(default_moonclaw_work_step_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-moonclaw-work-step",
          moonclaw_work_step_path(),
          "failed to parse MoonClaw work-step JSON",
        ),
      )
  }
  let request : MoonClawWorkStepRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-moonclaw-work-step",
          moonclaw_work_step_path(),
          "failed to decode MoonClaw work-step contract",
        ),
      )
  }
  Ok(request)
}

///|
fn decode_moonclaw_work_run_request(
  body : String,
) -> Result[MoonClawWorkRunRequest, HostApiResponse] {
  if body == "" {
    return Ok(default_moonclaw_work_run_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-moonclaw-work-run",
          moonclaw_work_run_path(),
          "failed to parse MoonClaw work-run JSON",
        ),
      )
  }
  let request : MoonClawWorkRunRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-moonclaw-work-run",
          moonclaw_work_run_path(),
          "failed to decode MoonClaw work-run contract",
        ),
      )
  }
  Ok({
    run_id: request.run_id,
    max_steps: bounded_work_run_steps(request.max_steps),
    now_ms: request.now_ms,
    remember: request.remember,
  })
}

///|
fn work_step_dir(root : String) -> String {
  @runtime.robobook_path(root, "runs/moonclaw-work-steps")
}

///|
fn work_run_dir(root : String) -> String {
  @runtime.robobook_path(root, "runs/moonclaw-work-runs")
}

///|
fn ensure_work_step_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = work_step_dir(root)
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-moonclaw-work-step-dir", dir, "failed to create MoonClaw work-step directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn ensure_work_run_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = work_run_dir(root)
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-moonclaw-work-run-dir", dir, "failed to create MoonClaw work-run directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn work_step_id(
  request : MoonClawWorkStepRequest,
  context : @moonclaw.MoonClawPlanningResult,
  action_kind : String,
) -> String {
  let requested = if request.work_id == "" { "next" } else { request.work_id }
  "moonclaw-work-step-\{context.context.robot_id}-\{action_kind}-\{requested}-\{request.now_ms}"
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn work_run_id(
  request : MoonClawWorkRunRequest,
  context : @moonclaw.MoonClawPlanningResult,
) -> String {
  let id = if request.run_id == "" {
    "moonclaw-work-run-\{context.context.robot_id}-\{request.now_ms}"
  } else {
    request.run_id
  }
  id
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn write_work_step_response(
  root : String,
  response : MoonClawWorkStepResponse,
) -> Result[String, HostApiResponse] {
  let dir = match ensure_work_step_dir(root) {
    Ok(dir) => dir
    Err(response) => return Err(response)
  }
  let path = dir + "/\{response.step_id}.json"
  @fsx.write_string_to_file(path, response.to_json().stringify(indent=2)) catch {
    _ =>
      return Err(
        error_response(
          500, "write-moonclaw-work-step", path, "failed to persist MoonClaw work-step artifact",
        ),
      )
  }
  Ok(path)
}

///|
fn write_work_run_response(
  root : String,
  response : MoonClawWorkRunResponse,
) -> Result[String, HostApiResponse] {
  let dir = match ensure_work_run_dir(root) {
    Ok(dir) => dir
    Err(response) => return Err(response)
  }
  let path = dir + "/\{response.run_id}.json"
  @fsx.write_string_to_file(path, response.to_json().stringify(indent=2)) catch {
    _ =>
      return Err(
        error_response(
          500, "write-moonclaw-work-run", path, "failed to persist MoonClaw work-run artifact",
        ),
      )
  }
  Ok(path)
}

///|
fn parse_dispatch_json(response : HostApiResponse) -> Json {
  @json.parse(response.body) catch {
    _ => { "raw_body": response.body }
  }
}

///|
fn selected_step_action(
  root : String,
  request : AgentDispatchRequest,
  now_ms : Int64,
) -> Result[@work_queue.AgentNextAction, HostApiResponse] {
  let queue = match project_agent_work_queue(root, now_ms) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  let item = match selected_work_item(queue, request) {
    Some(value) => value
    None =>
      return Err(
        error_response(
          409,
          "no-agent-work",
          moonclaw_work_step_path(),
          "no queued agent work item is available for MoonClaw work-step dispatch",
        ),
      )
  }
  let registry = match tool_registry_or_response(root, 0L) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  Ok(@work_queue.action_for_item_with_registry(item, registry))
}

///|
fn work_step_dispatch_body(request : MoonClawWorkStepRequest) -> String {
  if request.work_id == "" {
    ""
  } else {
    AgentDispatchRequest::{ work_id: request.work_id, body: None }
    .to_json()
    .stringify()
  }
}

///|
fn decode_work_step_response(
  response : HostApiResponse,
) -> Result[MoonClawWorkStepResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch { _ => return Err(response) }
  let step : MoonClawWorkStepResponse = @json.from_json(json) catch {
    _ => return Err(response)
  }
  Ok(step)
}

///|
fn queue_has_dispatch_candidate(root : String, now_ms : Int64) -> Bool {
  match project_agent_work_queue(root, now_ms) {
    Ok(queue) =>
      match queue.next_item {
        Some(_) => true
        None => false
      }
    Err(_) => false
  }
}

///|
fn run_status(dispatched_count : Int, blocked_count : Int) -> String {
  if blocked_count > 0 {
    "blocked"
  } else if dispatched_count > 0 {
    "advanced"
  } else {
    "idle"
  }
}

///|
fn run_message(response : MoonClawWorkRunResponse) -> String {
  match response.stop_reason {
    "step-limit" =>
      "MoonClaw consumed \{response.step_count} safe work item(s) and stopped at the configured step limit."
    "blocked" =>
      "MoonClaw stopped after a queued work item could not be dispatched safely."
    "no-work" => "MoonClaw found no queued work item to dispatch."
    _ => "MoonClaw completed bounded queue consumption through Moonrobo."
  }
}

///|
pub fn moonclaw_work_step_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_moonclaw_work_step_request(body) {
    Ok(value) => value
    Err(response) => return response
  }
  let context_before = match
    moonclaw_planning_result_for(root, request.now_ms) {
    Ok(value) => value
    Err(response) => return response
  }
  let dispatch_request : AgentDispatchRequest = {
    work_id: request.work_id,
    body: None,
  }
  let action = match
    selected_step_action(root, dispatch_request, request.now_ms) {
    Ok(value) => value
    Err(response) => return response
  }
  let dispatch_response = agent_dispatch_next_response(
    root,
    work_step_dispatch_body(request),
  )
  let dispatch = parse_dispatch_json(dispatch_response)
  let context_after = match moonclaw_planning_result_for(root, request.now_ms) {
    Ok(value) => value
    Err(response) => return response
  }
  let memory = if request.remember {
    match persist_moonbook_memory(root, request.now_ms) {
      Ok(value) => Some(value)
      Err(response) => return response
    }
  } else {
    None
  }
  let dispatched = dispatch_response.status >= 200 &&
    dispatch_response.status < 300
  let status = if dispatched { "dispatched" } else { "blocked" }
  let step_id = work_step_id(request, context_before, action.kind)
  let step_path = work_step_dir(root) + "/\{step_id}.json"
  let memory_path = match memory {
    Some(value) => value.memory_path
    None => ""
  }
  let memory_pack_id = match memory {
    Some(value) => value.pack.pack_id
    None => ""
  }
  let response = MoonClawWorkStepResponse::{
    step_id,
    step_path,
    persisted: true,
    status,
    dispatched,
    work_id: if request.work_id == "" {
      "next"
    } else {
      request.work_id
    },
    action_kind: action.kind,
    action_route: action.route,
    context_before,
    dispatch_status: dispatch_response.status,
    dispatch,
    context_after,
    memory_updated: memory is Some(_),
    memory_path,
    memory_pack_id,
    next_route: "/api/agent/next-action",
    message: "MoonClaw consumed one Moonrobo agent work item through the safe dispatch rail and persisted memory.",
  }
  match write_work_step_response(root, response) {
    Ok(_) => json_response(dispatch_response.status, response.to_json())
    Err(error) => error
  }
}

///|
pub fn moonclaw_work_run_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_moonclaw_work_run_request(body) {
    Ok(value) => value
    Err(response) => return response
  }
  let context_before = match
    moonclaw_planning_result_for(root, request.now_ms) {
    Ok(value) => value
    Err(response) => return response
  }
  let steps : Array[MoonClawWorkStepResponse] = []
  let mut dispatched_count = 0
  let mut blocked_count = 0
  let mut stop_reason = "no-work"
  for index in 0..<request.max_steps {
    let step_now_ms = request.now_ms + index.to_int64()
    if !queue_has_dispatch_candidate(root, step_now_ms) {
      stop_reason = "no-work"
      break
    }
    let step_request : MoonClawWorkStepRequest = {
      work_id: "",
      now_ms: step_now_ms,
      remember: false,
    }
    let step_response = moonclaw_work_step_response(
      root,
      step_request.to_json().stringify(),
    )
    let step = match decode_work_step_response(step_response) {
      Ok(value) => value
      Err(response) => return response
    }
    steps.push(step)
    if step.dispatched {
      dispatched_count += 1
      stop_reason = "step-limit"
    } else {
      blocked_count += 1
      stop_reason = "blocked"
      break
    }
  }
  if steps.length() < request.max_steps && blocked_count == 0 {
    stop_reason = "no-work"
  }
  let context_after = match moonclaw_planning_result_for(root, request.now_ms) {
    Ok(value) => value
    Err(response) => return response
  }
  let memory = if request.remember {
    match persist_moonbook_memory(root, request.now_ms) {
      Ok(value) => Some(value)
      Err(response) => return response
    }
  } else {
    None
  }
  let memory_path = match memory {
    Some(value) => value.memory_path
    None => ""
  }
  let memory_pack_id = match memory {
    Some(value) => value.pack.pack_id
    None => ""
  }
  let run_id = work_run_id(request, context_before)
  let run_path = work_run_dir(root) + "/\{run_id}.json"
  let status = run_status(dispatched_count, blocked_count)
  let response = MoonClawWorkRunResponse::{
    run_id,
    run_path,
    persisted: true,
    status,
    step_count: steps.length(),
    dispatched_count,
    blocked_count,
    stop_reason,
    context_before,
    steps,
    context_after,
    memory_path,
    memory_pack_id,
    next_route: "/api/agent/next-action",
    message: "",
  }
  let response = { ..response, message: run_message(response) }
  match write_work_run_response(root, response) {
    Ok(_) => json_response(200, response.to_json())
    Err(error) => error
  }
}
