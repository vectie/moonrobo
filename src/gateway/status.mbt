///|
pub(all) struct MoonroboGatewayStatusInput {
  root : String
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
  can_submit_gateway_command : Bool
  latest_task_execution_path : String
  latest_gateway_command_path : String
  latest_robo_loop_path : String
  latest_proof_session_path : String
  proof_session_feedback_closed : Bool
  proof_session_auto_feedback_success_count : Int
  proof_session_latest_feedback_status : Int
  proof_session_latest_feedback_message : String
  next_method : String
  next_route : String
  next_title : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboGatewayStatus {
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
  can_submit_gateway_command : Bool
  latest_task_execution_path : String
  latest_gateway_command_path : String
  latest_robo_loop_path : String
  latest_proof_session_path : String
  proof_session_feedback_closed : Bool
  proof_session_auto_feedback_success_count : Int
  proof_session_latest_feedback_status : Int
  proof_session_latest_feedback_message : String
  next_method : String
  next_route : String
  next_title : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn gateway_status_path() -> String {
  "/api/moonrobo/gateway-status"
}

///|
pub fn gateway_command_path() -> String {
  "/api/moonrobo/gateway/command"
}

///|
pub fn status_text(input : MoonroboGatewayStatusInput) -> String {
  if input.loop_ready && input.live_readiness_status == "verified" {
    "verified"
  } else if input.can_submit_gateway_command {
    "ready-for-command"
  } else if input.mapped {
    "mapped-needs-evidence"
  } else {
    "unmapped"
  }
}

///|
pub fn status_message(status : String, next_route : String) -> String {
  match status {
    "verified" =>
      "Moonrobo gateway has verified one-to-one loop evidence and can accept the next task message."
    "ready-for-command" =>
      "Moonrobo gateway is mapped and live-ready; continue with \{next_route}."
    "mapped-needs-evidence" =>
      "Moonrobo gateway has a mapped RoboBook, but still needs durable loop evidence through \{next_route}."
    _ =>
      "Moonrobo gateway is not yet mapped; complete RoboBook identity and readiness before routine work."
  }
}

///|
pub fn project(input : MoonroboGatewayStatusInput) -> MoonroboGatewayStatus {
  let status = status_text(input)
  {
    service: "moonrobo-gateway",
    root: input.root,
    status,
    ready: input.loop_ready && input.live_readiness_status == "verified",
    robot_id: input.robot_id,
    bridge_id: input.bridge_id,
    mapped: input.mapped,
    has_task_message: input.has_task_message,
    session_stage: input.session_stage,
    memory_card_count: input.memory_card_count,
    loop_ready: input.loop_ready,
    loop_percent: input.loop_percent,
    loop_status: input.loop_status,
    live_readiness_status: input.live_readiness_status,
    physical_execution_allowed: input.physical_execution_allowed,
    can_submit_gateway_command: input.can_submit_gateway_command,
    latest_task_execution_path: input.latest_task_execution_path,
    latest_gateway_command_path: input.latest_gateway_command_path,
    latest_robo_loop_path: input.latest_robo_loop_path,
    latest_proof_session_path: input.latest_proof_session_path,
    proof_session_feedback_closed: input.proof_session_feedback_closed,
    proof_session_auto_feedback_success_count: input.proof_session_auto_feedback_success_count,
    proof_session_latest_feedback_status: input.proof_session_latest_feedback_status,
    proof_session_latest_feedback_message: input.proof_session_latest_feedback_message,
    next_method: input.next_method,
    next_route: input.next_route,
    next_title: input.next_title,
    message: status_message(status, input.next_route),
  }
}
