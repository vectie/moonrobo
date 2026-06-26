///|
pub fn moonrobo_gateway_status_path() -> String {
  @gateway.gateway_status_path()
}

///|
fn[T : @json.FromJson] decode_gateway_response(
  response : HostApiResponse,
  path : String,
  code : String,
  label : String,
) -> Result[T, HostApiResponse] {
  if response.status < 200 || response.status >= 300 {
    return Err(response)
  }
  let json = @json.parse(response.body) catch {
    _ =>
      return Err(
        error_response(500, code + "-parse", path, "failed to parse \{label}"),
      )
  }
  Ok(@json.from_json(json)) catch {
    _ =>
      Err(
        error_response(500, code + "-decode", path, "failed to decode \{label}"),
      )
  }
}

///|
fn moonrobo_gateway_status(
  root : String,
) -> Result[@gateway.MoonroboGatewayStatus, HostApiResponse] {
  let session_result : Result[RoboSessionResponse, HostApiResponse] = decode_gateway_response(
    robo_session_response(root),
    robo_session_path(),
    "gateway-session",
    "Robo session",
  )
  let session = match session_result {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  let live_result : Result[MoonroboLiveReadinessResponse, HostApiResponse] = decode_gateway_response(
    moonrobo_live_readiness_response(root),
    moonrobo_live_readiness_path(),
    "gateway-live-readiness",
    "live readiness",
  )
  let live = match live_result {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  let proof = match platform_loop_proof(root) {
    Ok(value) => value
    Err(response) => return Err(response)
  }
  Ok(
    @gateway.project({
      root,
      robot_id: live.robot_id,
      bridge_id: live.bridge_id,
      mapped: session.mapping.mapped,
      has_task_message: session.has_task_message,
      session_stage: session.session.stage,
      memory_card_count: session.memory.card_count,
      loop_ready: proof.ready,
      loop_percent: proof.percent,
      loop_status: proof.status,
      live_readiness_status: live.status,
      physical_execution_allowed: live.physical_execution_allowed,
      can_submit_gateway_command: live.can_submit_gateway_command,
      latest_task_execution_path: proof.latest_task_execution_path,
      latest_gateway_command_path: proof.latest_gateway_command_path,
      latest_robo_loop_path: proof.latest_robo_loop_path,
      latest_proof_session_path: live.latest_proof_session_path,
      proof_session_feedback_closed: live.proof_session_feedback_closed,
      proof_session_feedback_binding_success_count: live.proof_session_feedback_binding_success_count,
      proof_session_latest_feedback_status: live.proof_session_latest_feedback_status,
      proof_session_latest_feedback_message: live.proof_session_latest_feedback_message,
      next_method: live.next_method,
      next_route: live.next_route,
      next_title: live.next_title,
    }),
  )
}

///|
pub fn moonrobo_gateway_status_response(root : String) -> HostApiResponse {
  match moonrobo_gateway_status(root) {
    Ok(status) => json_response(200, status.to_json())
    Err(response) => response
  }
}
