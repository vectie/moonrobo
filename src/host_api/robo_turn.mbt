///|
pub(all) struct RoboTurnRequest {
  task_message : @task.RobotTaskMessageRequest
  run_agent : Bool
  max_steps : Int
  now_ms : Int64
  remember : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RoboTurnResponse {
  accepted : Bool
  agent_ran : Bool
  status : String
  ask : RoboAskResponse
  work_run : MoonClawWorkRunResponse?
  decision : RoboDecisionResponse
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robo_turn_path() -> String {
  "/api/moonrobo/turn"
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
fn decode_work_run(
  response : HostApiResponse,
) -> Result[MoonClawWorkRunResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-turn-work-run",
          robo_turn_path(),
          "failed to parse MoonClaw work-run response during Robo turn",
        ),
      )
  }
  let run : MoonClawWorkRunResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-turn-work-run",
          robo_turn_path(),
          "failed to decode MoonClaw work-run response during Robo turn",
        ),
      )
  }
  Ok(run)
}

///|
fn turn_status(
  agent_ran : Bool,
  decision : RoboDecisionResponse,
  run : MoonClawWorkRunResponse?,
) -> String {
  if agent_ran {
    match run {
      Some(value) => "agent-\{value.status}"
      None => "agent-ran"
    }
  } else if decision.needs_operator {
    "waiting-operator"
  } else if decision.needs_agent {
    "agent-ready"
  } else {
    decision.status
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
  let mut agent_ran = false
  let mut work_run : MoonClawWorkRunResponse? = None
  if request.run_agent && ask.decision.needs_agent {
    let work_request : MoonClawWorkRunRequest = {
      run_id: "robo-turn-\{ask.task_id}-\{request.now_ms}",
      max_steps: request.max_steps,
      now_ms: request.now_ms,
      remember: request.remember,
    }
    let run_response = moonclaw_work_run_response(
      root,
      work_request.to_json().stringify(),
    )
    if run_response.status < 200 || run_response.status >= 300 {
      return run_response
    }
    let run = match decode_work_run(run_response) {
      Ok(value) => value
      Err(response) => return response
    }
    agent_ran = true
    work_run = Some(run)
  }
  let decision_response = robo_decision_response(root)
  if decision_response.status < 200 || decision_response.status >= 300 {
    return decision_response
  }
  let decision = match decode_decision(decision_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let status = turn_status(agent_ran, decision, work_run)
  json_response(
    200,
    {
      accepted: true,
      agent_ran,
      status,
      ask,
      work_run,
      decision,
      message: if agent_ran {
        "Robo accepted the task message and MoonClaw ran bounded gateway work before returning the next decision."
      } else {
        "Robo accepted the task message and returned the next decision without running agent work."
      },
    }.to_json(),
  )
}
