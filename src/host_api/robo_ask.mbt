///|
pub(all) struct RoboAskResponse {
  accepted : Bool
  task_id : String
  message_path : String
  conversation_route : String
  status_route : String
  submitted : MoontownTaskMessageResponse
  decision : RoboDecisionResponse
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robo_ask_path() -> String {
  "/api/moonrobo/ask"
}

///|
fn decode_task_submission(
  response : HostApiResponse,
) -> Result[MoontownTaskMessageResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-ask-task-response",
          robo_ask_path(),
          "failed to parse task-message response after Robo ask",
        ),
      )
  }
  let submitted : MoontownTaskMessageResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-ask-task-response",
          robo_ask_path(),
          "failed to decode task-message response after Robo ask",
        ),
      )
  }
  Ok(submitted)
}

///|
fn decode_decision(
  response : HostApiResponse,
) -> Result[RoboDecisionResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-ask-decision",
          robo_ask_path(),
          "failed to parse Robo decision response after ask",
        ),
      )
  }
  let decision : RoboDecisionResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-ask-decision",
          robo_ask_path(),
          "failed to decode Robo decision response after ask",
        ),
      )
  }
  Ok(decision)
}

///|
pub fn robo_ask_response(root : String, body : String) -> HostApiResponse {
  let submitted_response = moontown_task_message_response(root, body)
  if submitted_response.status < 200 || submitted_response.status >= 300 {
    return submitted_response
  }
  let submitted = match decode_task_submission(submitted_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let decision_response = robo_decision_response(root)
  if decision_response.status < 200 || decision_response.status >= 300 {
    return decision_response
  }
  let decision = match decode_decision(decision_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let task_id = submitted.message_plan.task.task_id
  json_response(
    200,
    {
      accepted: true,
      task_id,
      message_path: submitted.message_path,
      conversation_route: moonbook_conversation_path(),
      status_route: moonbook_task_message_status_path(task_id),
      submitted,
      decision,
    }.to_json(),
  )
}
