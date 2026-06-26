///|
pub(all) struct RoboAskResponse {
  accepted : Bool
  task_id : String
  message_path : String
  conversation_route : String
  status_route : String
  submitted : MoontownTaskMessageResponse
  memory : MoonBookMemoryResponse
  conversation : MoonBookConversationResponse
  loop_proof : PlatformLoopProofResponse
  live_readiness : MoonroboLiveReadinessResponse
  handoff : RoboHandoffResponse
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
fn decode_handoff(
  response : HostApiResponse,
) -> Result[RoboHandoffResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-ask-decision",
          robo_ask_path(),
          "failed to parse Robo handoff response after ask",
        ),
      )
  }
  let handoff : RoboHandoffResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-ask-decision",
          robo_ask_path(),
          "failed to decode Robo handoff response after ask",
        ),
      )
  }
  Ok(handoff)
}

///|
fn decode_ask_conversation(
  response : HostApiResponse,
) -> Result[MoonBookConversationResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-ask-conversation",
          moonbook_conversation_path(),
          "failed to parse MoonBook conversation after Robo ask",
        ),
      )
  }
  let conversation : MoonBookConversationResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-ask-conversation",
          moonbook_conversation_path(),
          "failed to decode MoonBook conversation after Robo ask",
        ),
      )
  }
  Ok(conversation)
}

///|
fn decode_ask_live_readiness(
  response : HostApiResponse,
) -> Result[MoonroboLiveReadinessResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-ask-live-readiness",
          moonrobo_live_readiness_path(),
          "failed to parse Moonrobo live readiness after Robo ask",
        ),
      )
  }
  let live_readiness : MoonroboLiveReadinessResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-ask-live-readiness",
          moonrobo_live_readiness_path(),
          "failed to decode Moonrobo live readiness after Robo ask",
        ),
      )
  }
  Ok(live_readiness)
}

///|
fn decode_ask_response(
  response : HostApiResponse,
) -> Result[RoboAskResponse, HostApiResponse] {
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(
          500,
          "parse-robo-ask-response",
          robo_ask_path(),
          "failed to parse Robo ask response",
        ),
      )
  }
  let ask : RoboAskResponse = @json.from_json(json) catch {
    _ =>
      return Err(
        error_response(
          500,
          "decode-robo-ask-response",
          robo_ask_path(),
          "failed to decode Robo ask response",
        ),
      )
  }
  Ok(ask)
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
  let handoff_response = robo_handoff_response(root)
  if handoff_response.status < 200 || handoff_response.status >= 300 {
    return handoff_response
  }
  let handoff = match decode_handoff(handoff_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let task_id = submitted.message_plan.task.task_id
  let conversation_response = moonbook_conversation_response(root)
  if conversation_response.status < 200 || conversation_response.status >= 300 {
    return conversation_response
  }
  let conversation = match decode_ask_conversation(conversation_response) {
    Ok(value) => value
    Err(response) => return response
  }
  let live_readiness_response = moonrobo_live_readiness_response(root)
  if live_readiness_response.status < 200 ||
    live_readiness_response.status >= 300 {
    return live_readiness_response
  }
  let live_readiness = match
    decode_ask_live_readiness(live_readiness_response) {
    Ok(value) => value
    Err(response) => return response
  }
  json_response(
    200,
    {
      accepted: true,
      task_id,
      message_path: submitted.message_path,
      conversation_route: moonbook_conversation_path(),
      status_route: moonbook_task_message_status_path(task_id),
      submitted,
      memory: submitted.memory,
      conversation,
      loop_proof: live_readiness.loop_proof,
      live_readiness,
      handoff,
    }.to_json(),
  )
}
