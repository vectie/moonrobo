///|
pub(all) struct MoonroboGatewayStatusResponse {
  service : String
  root : String
  status : String
  ready : Bool
  robot_id : @core.RobotId
  bridge_id : @core.BridgeId
  mapped : Bool
  has_task_message : Bool
  session_stage : String
  memory_card_count : Int
  loop_ready : Bool
  loop_percent : Int
  loop_status : String
  live_readiness_status : String
  physical_execution_allowed : Bool
  can_run_robot_routine : Bool
  latest_task_execution_path : String
  latest_routine_path : String
  latest_robo_loop_path : String
  latest_proof_session_path : String
  next_method : String
  next_route : String
  next_title : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moonrobo_gateway_status_path() -> String {
  "/api/moonrobo/gateway-status"
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
fn gateway_status_text(
  session : RoboSessionResponse,
  live : MoonroboLiveReadinessResponse,
  proof : PlatformLoopProofResponse,
) -> String {
  if proof.ready && live.status == "verified" {
    "verified"
  } else if live.can_run_robot_routine {
    "ready-for-routine"
  } else if session.mapping.mapped {
    "mapped-needs-evidence"
  } else {
    "unmapped"
  }
}

///|
fn gateway_status_message(status : String, next_route : String) -> String {
  match status {
    "verified" =>
      "Moonrobo gateway has verified one-to-one loop evidence and can accept the next task message."
    "ready-for-routine" =>
      "Moonrobo gateway is mapped and live-ready; continue with \{next_route}."
    "mapped-needs-evidence" =>
      "Moonrobo gateway has a mapped RoboBook, but still needs durable loop evidence through \{next_route}."
    _ =>
      "Moonrobo gateway is not yet mapped; complete RoboBook identity and readiness before routine work."
  }
}

///|
pub fn moonrobo_gateway_status_response(root : String) -> HostApiResponse {
  let session_result : Result[RoboSessionResponse, HostApiResponse] = decode_gateway_response(
    robo_session_response(root),
    robo_session_path(),
    "gateway-session",
    "Robo session",
  )
  let session = match session_result {
    Ok(value) => value
    Err(response) => return response
  }
  let live_result : Result[MoonroboLiveReadinessResponse, HostApiResponse] = decode_gateway_response(
    moonrobo_live_readiness_response(root),
    moonrobo_live_readiness_path(),
    "gateway-live-readiness",
    "live readiness",
  )
  let live = match live_result {
    Ok(value) => value
    Err(response) => return response
  }
  let proof = match platform_loop_proof(root) {
    Ok(value) => value
    Err(response) => return response
  }
  let status = gateway_status_text(session, live, proof)
  json_response(
    200,
    MoonroboGatewayStatusResponse::{
      service: "moonrobo-gateway",
      root,
      status,
      ready: proof.ready && live.status == "verified",
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
      can_run_robot_routine: live.can_run_robot_routine,
      latest_task_execution_path: proof.latest_task_execution_path,
      latest_routine_path: proof.latest_routine_path,
      latest_robo_loop_path: proof.latest_robo_loop_path,
      latest_proof_session_path: live.latest_proof_session_path,
      next_method: live.next_method,
      next_route: live.next_route,
      next_title: live.next_title,
      message: gateway_status_message(status, live.next_route),
    }.to_json(),
  )
}
