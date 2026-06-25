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
  can_run_robot_routine : Bool
  latest_task_execution_path : String
  latest_routine_path : String
  latest_robo_loop_path : String
  latest_proof_session_path : String
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
pub fn gateway_status_path() -> String {
  "/api/moonrobo/gateway-status"
}

///|
pub fn status_text(input : MoonroboGatewayStatusInput) -> String {
  if input.loop_ready && input.live_readiness_status == "verified" {
    "verified"
  } else if input.can_run_robot_routine {
    "ready-for-routine"
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
    "ready-for-routine" =>
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
    can_run_robot_routine: input.can_run_robot_routine,
    latest_task_execution_path: input.latest_task_execution_path,
    latest_routine_path: input.latest_routine_path,
    latest_robo_loop_path: input.latest_robo_loop_path,
    latest_proof_session_path: input.latest_proof_session_path,
    next_method: input.next_method,
    next_route: input.next_route,
    next_title: input.next_title,
    message: status_message(status, input.next_route),
  }
}
