///|
pub(all) struct RoboLoopRequest {
  loop_id : String
  turn : RoboTurnRequest?
  now_ms : Int64
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboLoopResponse {
  loop_id : String
  loop_path : String
  persisted : Bool
  accepted : Bool
  status : String
  turn : RoboTurnResponse?
  session : RoboSessionResponse
  decision : RoboDecisionResponse
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboLoopListResponse {
  loop_count : Int
  loops : Array[RoboLoopResponse]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboLoopSummaryResponse {
  loop_id : String
  loop_path : String
  status : String
  accepted : Bool
  final_owner : String
  final_kind : String
  final_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robo_loop_path() -> String {
  "/api/moonrobo/loop"
}

///|
pub fn robo_loops_path() -> String {
  "/api/moonrobo/loops"
}

///|
pub fn robo_loop_detail_path(loop_id : String) -> String {
  "/api/moonrobo/loops/\{loop_id}"
}

///|
fn loop_id_from_robo_loop_detail_path(path : String) -> String? {
  let prefix = robo_loops_path() + "/"
  if path.has_prefix(prefix) && path.length() > prefix.length() {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
fn default_robo_loop_request() -> RoboLoopRequest {
  { loop_id: "", turn: None, now_ms: 0L, remember: true }
}

///|
fn decode_robo_loop_request(
  body : String,
) -> Result[RoboLoopRequest, HostApiResponse] {
  if body == "" {
    return Ok(default_robo_loop_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-robo-loop",
          robo_loop_path(),
          "failed to parse Robo loop JSON",
        ),
      )
  }
  let request : RoboLoopRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-robo-loop",
          robo_loop_path(),
          "failed to decode Robo loop contract",
        ),
      )
  }
  Ok({
    loop_id: request.loop_id,
    turn: request.turn,
    now_ms: request.now_ms,
    remember: request.remember,
  })
}

///|
fn decode_robo_loop_turn(
  response : HostApiResponse,
) -> Result[RoboTurnResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-loop-turn",
          robo_loop_path(),
          "failed to parse Robo turn response during loop",
        ),
      )
  }
  let turn : RoboTurnResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-loop-turn",
          robo_loop_path(),
          "failed to decode Robo turn response during loop",
        ),
      )
  }
  Ok(turn)
}

///|
fn decode_robo_loop_session(
  response : HostApiResponse,
) -> Result[RoboSessionResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-loop-session",
          robo_loop_path(),
          "failed to parse Robo session response during loop",
        ),
      )
  }
  let session : RoboSessionResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-loop-session",
          robo_loop_path(),
          "failed to decode Robo session response during loop",
        ),
      )
  }
  Ok(session)
}

///|
fn decode_robo_loop_file(
  path : String,
  text : String,
) -> Result[RoboLoopResponse, HostApiResponse] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        error_response(
          500, "parse-robo-loop-artifact", path, "failed to parse Robo loop artifact",
        ),
      )
  }
  let item : RoboLoopResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-robo-loop-artifact", path, "failed to decode Robo loop artifact",
        ),
      )
  }
  Ok(item)
}

///|
fn read_robo_loop_file(
  path : String,
) -> Result[RoboLoopResponse, HostApiResponse] {
  let text = match @runtime.read_robo_loop_json_file(path) {
    Ok(text) => text
    Err(issue) =>
      return Err(error_response(404, issue.code, issue.path, issue.message))
  }
  decode_robo_loop_file(path, text)
}

///|
fn summarize_robo_loop(loop_run : RoboLoopResponse) -> RoboLoopSummaryResponse {
  {
    loop_id: loop_run.loop_id,
    loop_path: loop_run.loop_path,
    status: loop_run.status,
    accepted: loop_run.accepted,
    final_owner: loop_run.decision.next_owner,
    final_kind: loop_run.decision.next_kind,
    final_route: loop_run.decision.next_route,
    message: loop_run.message,
  }
}

///|
fn robo_loop_run_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = @runtime.robobook_path(root, "runs/robo-loops")
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-robo-loop-dir", dir, "failed to create Robo loop artifact directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn write_robo_loop_response(
  root : String,
  response : RoboLoopResponse,
) -> Result[String, HostApiResponse] {
  let dir = match robo_loop_run_dir(root) {
    Ok(dir) => dir
    Err(response) => return Err(response)
  }
  let path = dir + "/\{response.loop_id}.json"
  @fsx.write_string_to_file(path, response.to_json().stringify(indent=2)) catch {
    _ =>
      return Err(
        error_response(
          500, "write-robo-loop", path, "failed to persist Robo loop artifact",
        ),
      )
  }
  Ok(path)
}

///|
fn sanitized_robo_loop_id(raw : String) -> String {
  raw
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn robo_loop_id(request : RoboLoopRequest, turn : RoboTurnResponse?) -> String {
  if request.loop_id != "" {
    sanitized_robo_loop_id(request.loop_id)
  } else {
    match turn {
      Some(value) =>
        sanitized_robo_loop_id(
          "robo-loop-\{value.ask.task_id}-\{request.now_ms}",
        )
      None => sanitized_robo_loop_id("robo-loop-current-\{request.now_ms}")
    }
  }
}

///|
fn robo_loop_turn_request(
  request : RoboLoopRequest,
  turn : RoboTurnRequest,
) -> RoboTurnRequest {
  {
    task_message: turn.task_message,
    max_steps: 1,
    now_ms: if turn.now_ms == 0L {
      request.now_ms
    } else {
      turn.now_ms
    },
    remember: request.remember,
  }
}

///|
fn run_robo_loop_turn(
  root : String,
  request : RoboLoopRequest,
) -> Result[RoboTurnResponse?, HostApiResponse] {
  match request.turn {
    Some(turn) => {
      let canonical = robo_loop_turn_request(request, turn)
      let response = robo_turn_response(root, canonical.to_json().stringify())
      if response.status < 200 || response.status >= 300 {
        return Err(response)
      }
      match decode_robo_loop_turn(response) {
        Ok(value) => Ok(Some(value))
        Err(response) => Err(response)
      }
    }
    None => Ok(None)
  }
}

///|
fn loop_status(decision : RoboDecisionResponse) -> String {
  if decision.accepts_task_messages {
    "ready"
  } else if decision.needs_operator {
    "needs-operator"
  } else if decision.needs_moonclaw {
    "moonclaw-ready"
  } else {
    decision.status
  }
}

///|
fn loop_message(status : String, accepted : Bool) -> String {
  if status == "ready" {
    "Moonrobo loop is ready for the next Robo ask."
  } else if status == "needs-operator" {
    "Moonrobo loop stopped at an operator-owned decision."
  } else if status == "moonclaw-ready" {
    "Moonrobo loop has MoonClaw-owned work ready; MoonClaw must advance it through its robot policy gateway."
  } else if accepted {
    "Moonrobo accepted the task message and stopped at \{status}."
  } else {
    "Moonrobo restored the current session and stopped at \{status}."
  }
}

///|
pub fn robo_loops_response(root : String) -> HostApiResponse {
  let paths = match @runtime.list_robo_loop_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let loops : Array[RoboLoopResponse] = []
  for path in paths {
    match read_robo_loop_file(path) {
      Ok(item) => loops.push(item)
      Err(response) => return response
    }
  }
  json_response(
    200,
    RoboLoopListResponse::{ loop_count: loops.length(), loops }.to_json(),
  )
}

///|
pub fn robo_loop_detail_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let loop_id = match loop_id_from_robo_loop_detail_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No Moonrobo loop detail route",
      )
  }
  let text = match @runtime.read_robo_loop_json(root, loop_id) {
    Ok(text) => text
    Err(issue) =>
      return error_response(404, issue.code, issue.path, issue.message)
  }
  match decode_robo_loop_file(path, text) {
    Ok(item) => json_response(200, item.to_json())
    Err(response) => response
  }
}

///|
pub fn robo_loop_response(root : String, body : String) -> HostApiResponse {
  let request = match decode_robo_loop_request(body) {
    Ok(value) => value
    Err(response) => return response
  }
  let turn = match run_robo_loop_turn(root, request) {
    Ok(value) => value
    Err(response) => return response
  }
  let loop_id = robo_loop_id(request, turn)
  let session_response = robo_session_response(root)
  if session_response.status < 200 || session_response.status >= 300 {
    return session_response
  }
  let session = match decode_robo_loop_session(session_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let decision = session.decision
  let status = loop_status(decision)
  let loop_path = @runtime.robobook_path(
    root,
    "runs/robo-loops/\{loop_id}.json",
  )
  let response = RoboLoopResponse::{
    loop_id,
    loop_path,
    persisted: true,
    accepted: turn is Some(_),
    status,
    turn,
    session,
    decision,
    message: loop_message(status, turn is Some(_)),
  }
  let path = match write_robo_loop_response(root, response) {
    Ok(path) => path
    Err(response) => return response
  }
  json_response(200, { ..response, loop_path: path }.to_json())
}
