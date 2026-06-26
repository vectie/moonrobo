///|
pub fn moonrobo_product_status_path() -> String {
  @product_status.product_status_path()
}

///|
fn product_status_from_gateway(
  gateway : @gateway.MoonroboGatewayStatus,
) -> @product_status.MoonroboProductStatus {
  @product_status.project({
    root: gateway.root,
    robot_id: gateway.robot_id,
    bridge_id: gateway.bridge_id,
    mapped: gateway.mapped,
    has_task_message: gateway.has_task_message,
    memory_card_count: gateway.memory_card_count,
    can_submit_gateway_command: gateway.can_submit_gateway_command,
    physical_execution_allowed: gateway.physical_execution_allowed,
    loop_ready: gateway.loop_ready,
    loop_percent: gateway.loop_percent,
    loop_status: gateway.loop_status,
    live_readiness_status: gateway.live_readiness_status,
    latest_task_execution_path: gateway.latest_task_execution_path,
    latest_gateway_command_path: gateway.latest_gateway_command_path,
    latest_robo_loop_path: gateway.latest_robo_loop_path,
    latest_proof_session_path: gateway.latest_proof_session_path,
    proof_session_feedback_closed: gateway.proof_session_feedback_closed,
    proof_session_feedback_binding_success_count: gateway.proof_session_feedback_binding_success_count,
    proof_session_latest_feedback_status: gateway.proof_session_latest_feedback_status,
    proof_session_latest_feedback_message: gateway.proof_session_latest_feedback_message,
    next_route: gateway.next_route,
  })
}

///|
fn latest_live_exercise_for_product(
  root : String,
) -> MoonroboLiveExerciseResponse? {
  let paths = match list_live_exercise_paths(root) {
    Ok(paths) => paths
    Err(_) => return None
  }
  if paths.is_empty() {
    return None
  }
  match read_live_exercise_file(paths[paths.length() - 1]) {
    Ok(exercise) => Some(refreshed_live_exercise_for_read(root, exercise))
    Err(_) => None
  }
}

///|
fn moonrobo_product_status(
  root : String,
) -> Result[@product_status.MoonroboProductStatus, HostApiResponse] {
  match moonrobo_gateway_status(root) {
    Ok(gateway) => Ok(product_status_from_gateway(gateway))
    Err(response) => Err(response)
  }
}

///|
pub fn moonrobo_product_status_response(root : String) -> HostApiResponse {
  match moonrobo_product_status(root) {
    Ok(status) => json_response(200, status.to_json())
    Err(response) => response
  }
}
