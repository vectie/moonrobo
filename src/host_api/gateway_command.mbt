///|
pub(all) struct MoonroboGatewayCommandRequest {
  command_id : String
  robot_id : @core.RobotId
  requested_by : @core.Requester
  goal : String
  now_ms : Int64
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboGatewayCommandRecord {
  command_id : String
  command_path : String
  robot_id : @core.RobotId
  requested_by : @core.Requester
  goal : String
  now_ms : Int64
  status : String
  accepted : Bool
  downstream_status : Int
  next_route : String
  message_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboGatewayCommandResponse {
  command : MoonroboGatewayCommandRecord
  gateway : @gateway.MoonroboGatewayStatus
  ask : RoboAskResponse?
  session : RoboSessionResponse?
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moonrobo_gateway_command_path() -> String {
  "/api/moonrobo/gateway/command"
}

///|
fn default_gateway_command_request() -> MoonroboGatewayCommandRequest {
  {
    command_id: "",
    robot_id: "",
    requested_by: @core.moontown_requester("moonclaw"),
    goal: "",
    now_ms: 0L,
    remember: true,
  }
}

///|
fn decode_gateway_command_request(
  body : String,
) -> Result[MoonroboGatewayCommandRequest, HostApiResponse] {
  if body == "" {
    return Ok(default_gateway_command_request())
  }
  let json = @json.parse(body) catch {
    _ =>
      return Err(
        error_response(
          400,
          "parse-gateway-command",
          moonrobo_gateway_command_path(),
          "failed to parse Moonrobo gateway command JSON",
        ),
      )
  }
  let request : MoonroboGatewayCommandRequest = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          400,
          "decode-gateway-command",
          moonrobo_gateway_command_path(),
          "failed to decode Moonrobo gateway command contract",
        ),
      )
  }
  Ok(request)
}

///|
fn gateway_command_id(request : MoonroboGatewayCommandRequest) -> String {
  let base = if request.command_id == "" {
    "gateway-command-\{request.now_ms}"
  } else {
    request.command_id
  }
  base
  .replace(old="/", new="-")
  .replace(old=":", new="-")
  .replace(old=" ", new="-")
}

///|
fn gateway_command_dir(root : String) -> String {
  @runtime.robobook_path(root, "runs/gateway-commands")
}

///|
fn ensure_gateway_command_dir(root : String) -> Result[String, HostApiResponse] {
  match @runtime.ensure_process_dirs(root) {
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
    Ok(_) => ()
  }
  let dir = gateway_command_dir(root)
  if !@fsx.path_exists(dir) {
    @fsx.create_dir(dir) catch {
      _ =>
        return Err(
          error_response(
            500, "create-gateway-command-dir", dir, "failed to create Moonrobo gateway command directory",
          ),
        )
    }
  }
  Ok(dir)
}

///|
fn write_gateway_command_response(
  root : String,
  response : MoonroboGatewayCommandResponse,
) -> Result[String, HostApiResponse] {
  let dir = match ensure_gateway_command_dir(root) {
    Ok(dir) => dir
    Err(response) => return Err(response)
  }
  let path = dir + "/\{response.command.command_id}.json"
  @fsx.write_string_to_file(path, response.to_json().stringify(indent=2)) catch {
    _ =>
      return Err(
        error_response(
          500, "write-gateway-command", path, "failed to persist Moonrobo gateway command artifact",
        ),
      )
  }
  Ok(path)
}

///|
fn gateway_command_task_message(
  request : MoonroboGatewayCommandRequest,
  gateway : @gateway.MoonroboGatewayStatus,
  command_id : String,
) -> @task.RobotTaskMessageRequest {
  @task.task_message_request(
    command_id,
    gateway_command_robot_id(request, gateway),
    request.requested_by,
    request.goal,
    request.now_ms,
  )
}

///|
fn gateway_command_robot_id(
  request : MoonroboGatewayCommandRequest,
  gateway : @gateway.MoonroboGatewayStatus,
) -> @core.RobotId {
  if request.robot_id == "" {
    gateway.robot_id
  } else {
    request.robot_id
  }
}

///|
fn decode_gateway_command_ask(
  response : HostApiResponse,
) -> Result[RoboAskResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch { _ => return Err(response) }
  let ask : RoboAskResponse = @json.from_json(json) catch {
    _ => return Err(response)
  }
  Ok(ask)
}

///|
fn decode_gateway_command_session(
  response : HostApiResponse,
) -> Result[RoboSessionResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch { _ => return Err(response) }
  let session : RoboSessionResponse = @json.from_json(json) catch {
    _ => return Err(response)
  }
  Ok(session)
}

///|
fn gateway_command_record(
  request : MoonroboGatewayCommandRequest,
  robot_id : @core.RobotId,
  command_id : String,
  command_path : String,
  accepted : Bool,
  downstream_status : Int,
  next_route : String,
  message_path : String,
) -> MoonroboGatewayCommandRecord {
  {
    command_id,
    command_path,
    robot_id,
    requested_by: request.requested_by,
    goal: request.goal,
    now_ms: request.now_ms,
    status: if accepted {
      "accepted"
    } else {
      "blocked"
    },
    accepted,
    downstream_status,
    next_route,
    message_path,
  }
}

///|
pub fn moonrobo_gateway_command_response(
  root : String,
  body : String,
) -> HostApiResponse {
  let request = match decode_gateway_command_request(body) {
    Ok(request) => request
    Err(response) => return response
  }
  let gateway = match moonrobo_gateway_status(root) {
    Ok(status) => status
    Err(response) => return response
  }
  let command_id = gateway_command_id(request)
  let robot_id = gateway_command_robot_id(request, gateway)
  let command_path = gateway_command_dir(root) + "/\{command_id}.json"
  guard request.goal.trim().to_owned() != "" else {
    let command = gateway_command_record(
      request,
      robot_id,
      command_id,
      command_path,
      false,
      400,
      gateway.next_route,
      "",
    )
    let response = {
      command,
      gateway,
      ask: None,
      session: None,
      message: "Moonrobo gateway rejected an empty command goal; MoonClaw policy must send a concrete robot task.",
    }
    match write_gateway_command_response(root, response) {
      Ok(_) => return json_response(400, response.to_json())
      Err(error) => return error
    }
  }
  let task_message = gateway_command_task_message(request, gateway, command_id)
  let ask_response = robo_ask_response(root, task_message.to_json().stringify())
  let ask = match decode_gateway_command_ask(ask_response) {
    Ok(value) => Some(value)
    Err(_) => None
  }
  let accepted = ask_response.status >= 200 && ask_response.status < 300
  let next_route = match ask {
    Some(value) => value.decision.next_route
    None => gateway.next_route
  }
  let message_path = match ask {
    Some(value) => value.message_path
    None => ""
  }
  let session = if accepted {
    let session_response = robo_session_response(root)
    if session_response.status >= 200 && session_response.status < 300 {
      match decode_gateway_command_session(session_response) {
        Ok(value) => Some(value)
        Err(_) => None
      }
    } else {
      None
    }
  } else {
    None
  }
  let command = gateway_command_record(
    request,
    robot_id,
    command_id,
    command_path,
    accepted,
    ask_response.status,
    next_route,
    message_path,
  )
  let response = {
    command,
    gateway,
    ask,
    session,
    message: if accepted {
      "Moonrobo gateway accepted the MoonClaw-authored command as a durable Robo task message; policy execution remains outside Moonrobo."
    } else {
      "Moonrobo gateway could not accept the command as a Robo task message."
    },
  }
  match write_gateway_command_response(root, response) {
    Ok(_) => json_response(ask_response.status, response.to_json())
    Err(error) => error
  }
}
