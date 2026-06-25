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
    can_run_robot_routine: gateway.can_run_robot_routine,
    physical_execution_allowed: gateway.physical_execution_allowed,
    loop_ready: gateway.loop_ready,
    loop_percent: gateway.loop_percent,
    loop_status: gateway.loop_status,
    live_readiness_status: gateway.live_readiness_status,
    latest_task_execution_path: gateway.latest_task_execution_path,
    latest_routine_path: gateway.latest_routine_path,
    latest_robo_loop_path: gateway.latest_robo_loop_path,
    latest_proof_session_path: gateway.latest_proof_session_path,
    next_route: gateway.next_route,
  })
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
