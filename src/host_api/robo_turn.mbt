///|
pub(all) struct RoboTurnRequest {
  task_message : @task.RobotTaskMessageRequest
  now_ms : Int64
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboTurnResponse {
  turn_id : String
  turn_path : String
  persisted : Bool
  accepted : Bool
  moonclaw_handoff : Bool
  status : String
  ask : RoboAskResponse
  handoff : RoboHandoffResponse
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboTurnListResponse {
  turn_count : Int
  turns : Array[RoboTurnResponse]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robo_turn_path() -> String {
  "/api/moonrobo/turn"
}

///|
pub fn robo_turns_path() -> String {
  "/api/moonrobo/turns"
}

///|
pub fn robo_turn_detail_path(turn_id : String) -> String {
  "/api/moonrobo/turns/\{turn_id}"
}

///|
fn turn_id_from_robo_turn_detail_path(path : String) -> String? {
  let prefix = robo_turns_path() + "/"
  if path.has_prefix(prefix) && path.length() > prefix.length() {
    Some(path[prefix.length():path.length()].to_owned())
  } else {
    None
  }
}

///|
fn robo_turn_run_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = @runtime.moonrobo_robo_turns_dir(root)
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-robo-turn-dir", dir, "failed to create Robo turn artifact directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn write_robo_turn_response(
  root : String,
  response : RoboTurnResponse,
) -> Result[String, HostApiResponse] {
  let dir = match robo_turn_run_dir(root) {
    Ok(dir) => dir
    Err(response) => return Err(response)
  }
  let path = dir + "/\{response.turn_id}.json"
  @fsx.write_string_to_file(path, response.to_json().stringify(indent=2)) catch {
    _ =>
      return Err(
        error_response(
          500, "write-robo-turn", path, "failed to persist Robo turn artifact",
        ),
      )
  }
  Ok(path)
}

///|
fn decode_robo_turn_request(
  body : String,
) -> Result[RoboTurnRequest, HostApiResponse] {
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-robo-turn",
          robo_turn_path(),
          "failed to parse Robo turn JSON",
        ),
      )
  }
  let request : RoboTurnRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-robo-turn",
          robo_turn_path(),
          "failed to decode Robo turn contract",
        ),
      )
  }
  Ok(request)
}

///|
fn decode_robo_turn_file(
  path : String,
  text : String,
) -> Result[RoboTurnResponse, HostApiResponse] {
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        error_response(
          500, "parse-robo-turn-artifact", path, "failed to parse Robo turn artifact",
        ),
      )
  }
  let turn : RoboTurnResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500, "decode-robo-turn-artifact", path, "failed to decode Robo turn artifact",
        ),
      )
  }
  Ok(turn)
}

///|
fn read_robo_turn_file(
  path : String,
) -> Result[RoboTurnResponse, HostApiResponse] {
  let text = match @runtime.read_robo_turn_json_file(path) {
    Ok(text) => text
    Err(issue) =>
      return Err(error_response(404, issue.code, issue.path, issue.message))
  }
  decode_robo_turn_file(path, text)
}

///|
pub fn robo_turns_response(root : String) -> HostApiResponse {
  let paths = match @runtime.list_robo_turn_paths(root) {
    Ok(paths) => paths
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let turns : Array[RoboTurnResponse] = []
  for path in paths {
    match read_robo_turn_file(path) {
      Ok(turn) => turns.push(turn)
      Err(response) => return response
    }
  }
  json_response(200, { turn_count: turns.length(), turns }.to_json())
}

///|
pub fn robo_turn_detail_response(
  root : String,
  path : String,
) -> HostApiResponse {
  let turn_id = match turn_id_from_robo_turn_detail_path(path) {
    Some(value) => value
    None =>
      return error_response(
        404, "not-found", path, "No MoonRobo turn detail route",
      )
  }
  let text = match @runtime.read_robo_turn_json(root, turn_id) {
    Ok(text) => text
    Err(issue) =>
      return error_response(404, issue.code, issue.path, issue.message)
  }
  match decode_robo_turn_file(path, text) {
    Ok(turn) => json_response(200, turn.to_json())
    Err(response) => response
  }
}

///|
fn turn_status(handoff : RoboHandoffResponse) -> String {
  if handoff.needs_operator {
    "waiting-operator"
  } else if handoff.needs_moonclaw {
    "moonclaw-ready"
  } else {
    handoff.status
  }
}

///|
pub fn robo_turn_response(root : String, body : String) -> HostApiResponse {
  let request = match decode_robo_turn_request(body) {
    Ok(value) => value
    Err(response) => return response
  }
  let ask_response = robo_ask_response(
    root,
    request.task_message.to_json().stringify(),
  )
  if ask_response.status < 200 || ask_response.status >= 300 {
    return ask_response
  }
  let ask = match decode_ask_response(ask_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let handoff_response = robo_handoff_response(root)
  if handoff_response.status < 200 || handoff_response.status >= 300 {
    return handoff_response
  }
  let handoff = match decode_handoff(handoff_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let status = turn_status(handoff)
  let moonclaw_handoff = handoff.needs_moonclaw
  let turn_id = "robo-turn-\{ask.task_id}-\{request.now_ms}"
  let turn_path = @pathx.join(
    @runtime.moonrobo_robo_turns_dir(root),
    "\{turn_id}.json",
  )
  let response : RoboTurnResponse = {
    turn_id,
    turn_path,
    persisted: true,
    accepted: true,
    moonclaw_handoff,
    status,
    ask,
    handoff,
    message: if moonclaw_handoff {
      "Robo accepted the task message and left the next action for MoonClaw to run through registered MoonRobo tools."
    } else {
      "Robo accepted the task message and returned the next handoff without running MoonClaw routine locally."
    },
  }
  let path = match write_robo_turn_response(root, response) {
    Ok(path) => path
    Err(response) => return response
  }
  json_response(200, { ..response, turn_path: path }.to_json())
}
