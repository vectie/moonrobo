///|
pub(all) struct PlatformProveLoopRequest {
  task_message : @task.RobotTaskMessageRequest
  max_steps : Int
  bootstrap : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformProveLoopResponse {
  proof_id : String
  proof_path : String
  memory_path : String
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
pub(all) struct PlatformProveLoopRecord {
  proof_id : String
  proof_path : String
  task_id : String
  status : String
  ready : Bool
  advanced : Bool
  completed_before : Int
  completed_after : Int
  total_count : Int
  percent_after : Int
  next_route : String
  routine_path : String
  robo_loop_path : String
  recorded_at_ms : Int64
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
    bootstrap: request.bootstrap,
  }
}

///|
fn prove_loop_proof_id(request : PlatformProveLoopRequest) -> String {
  let base = if request.task_message.message_id == "" {
    "prove-loop-\{request.task_message.now_ms}"
  } else {
    "prove-loop-\{request.task_message.message_id}-\{request.task_message.now_ms}"
  }
  base
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn prove_loop_dir(root : String) -> String {
  @runtime.robobook_path(root, "runs/prove-loop")
}

///|
fn prove_loop_record_path(root : String, proof_id : String) -> String {
  prove_loop_dir(root) + "/\{proof_id}.json"
}

///|
fn ensure_prove_loop_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = prove_loop_dir(root)
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-prove-loop-dir", dir, "failed to create prove-loop evidence directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn write_prove_loop_record(
  root : String,
  record : PlatformProveLoopRecord,
) -> Result[String, HostApiResponse] {
  match ensure_prove_loop_dir(root) {
    Ok(_) => ()
    Err(response) => return Err(response)
  }
  @fsx.write_string_to_file(
    record.proof_path,
    record.to_json().stringify(indent=2),
  ) catch {
    _ =>
      return Err(
        error_response(
          500,
          "write-prove-loop-record",
          record.proof_path,
          "failed to persist prove-loop evidence",
        ),
      )
  }
  Ok(record.proof_path)
}

///|
fn list_prove_loop_record_paths(root : String) -> Array[String] {
  let dir = prove_loop_dir(root)
  if !@fsx.path_exists(dir) {
    return []
  }
  let names = @fsx.read_dir(dir) catch { _ => return [] }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(prove_loop_dir(root) + "/\{name}")
    }
  }
  paths
}

///|
fn read_prove_loop_record_file(path : String) -> PlatformProveLoopRecord? {
  let text = @fsx.read_file_to_string(path) catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  let record : PlatformProveLoopRecord = @json.from_json(json) catch {
    _ => return None
  }
  Some(record)
}

///|
fn latest_prove_loop_record(root : String) -> PlatformProveLoopRecord? {
  let paths = list_prove_loop_record_paths(root)
  if paths.is_empty() {
    None
  } else {
    read_prove_loop_record_file(paths[paths.length() - 1])
  }
}

///|
fn prove_loop_memory_card(
  root : String,
  resident : @resident.ResidentRobotAgent,
  generated_at_ms : Int64,
) -> @moonbook.MoonBookMemoryCard? {
  match latest_prove_loop_record(root) {
    Some(record) =>
      Some(
        @moonbook.memory_card(
          resident.robot_id,
          resident.resident_id,
          "closed-loop-proof",
          if record.ready {
            56
          } else {
            94
          },
          "Closed-loop proof",
          "Moonrobo prove-loop is \{record.status}; advanced \{record.completed_before}/\{record.total_count} to \{record.completed_after}/\{record.total_count}; next \{record.next_route}",
          record.proof_path,
          record.next_route,
          generated_at_ms,
        ),
      )
    None => None
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
    remember: true,
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
  let proof_id = prove_loop_proof_id(request)
  let proof_path = prove_loop_record_path(root, proof_id)
  let message = prove_loop_message(after, bootstrap_applied, true, next_route)
  let routine_path = match routine {
    Some(value) => value.routine_path
    None => ""
  }
  let robo_loop_path = match routine {
    Some(value) => value.robo_loop.loop_path
    None => ""
  }
  let record : PlatformProveLoopRecord = {
    proof_id,
    proof_path,
    task_id: request.task_message.message_id,
    status: after.status,
    ready: after.ready,
    advanced,
    completed_before: before.completed_count,
    completed_after: after.completed_count,
    total_count: after.total_count,
    percent_after: after.percent,
    next_route,
    routine_path,
    robo_loop_path,
    recorded_at_ms: request.task_message.now_ms,
    message,
  }
  let proof_path = match write_prove_loop_record(root, record) {
    Ok(path) => path
    Err(response) => return response
  }
  let memory = match
    persist_moonbook_memory(root, request.task_message.now_ms) {
    Ok(memory) => memory
    Err(response) => return response
  }
  let response : PlatformProveLoopResponse = {
    proof_id,
    proof_path,
    memory_path: memory.memory_path,
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
    message,
  }
  json_response(200, response.to_json())
}
