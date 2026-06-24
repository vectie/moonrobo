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
pub fn moonclaw_work_step_path() -> String {
  "/api/moonclaw/work-step"
}

///|
fn default_moonclaw_work_step_request() -> MoonClawWorkStepRequest {
  { work_id: "", now_ms: 0L, remember: true }
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
fn work_step_dir(root : String) -> String {
  @runtime.robobook_path(root, "runs/moonclaw-work-steps")
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
