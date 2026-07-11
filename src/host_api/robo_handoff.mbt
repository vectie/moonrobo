///|
pub(all) struct RoboHandoffResponse {
  handoff_id : String
  robot_id : @core.RobotId
  status : String
  can_act : Bool
  needs_operator : Bool
  needs_moonclaw : Bool
  accepts_task_messages : Bool
  physical_execution_allowed : Bool
  next_owner : String
  next_method : String
  next_route : String
  target_route : String
  next_kind : String
  next_title : String
  next_work_id : String
  queue_count : Int
  readiness_status : String
  readiness_ready : Bool
  loop_status : String
  loop_ready : Bool
  loop_percent : Int
  latest_gateway_command_path : String
  latest_execution_path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robo_handoff_path() -> String {
  "/api/moonrobo/handoff"
}

///|
fn empty_handoff_action(
  proof : PlatformLoopProofResponse,
  readiness : @readiness.PlatformReadinessPlan,
) -> RoboHandoffResponse {
  match readiness.next_action {
    Some(action) =>
      {
        handoff_id: "robo-handoff-\{proof.robot_id}",
        robot_id: proof.robot_id,
        status: "needs-operator",
        can_act: false,
        needs_operator: true,
        needs_moonclaw: false,
        accepts_task_messages: false,
        physical_execution_allowed: action.physical_execution_allowed,
        next_owner: "operator",
        next_method: action.http_method,
        next_route: action.route,
        target_route: action.route,
        next_kind: action.check_code,
        next_title: action.title,
        next_work_id: "",
        queue_count: 0,
        readiness_status: readiness.status,
        readiness_ready: readiness.ready,
        loop_status: proof.status,
        loop_ready: proof.ready,
        loop_percent: proof.percent,
        latest_gateway_command_path: proof.latest_gateway_command_path,
        latest_execution_path: proof.latest_task_execution_path,
        message: "Operator action is required before MoonClaw can continue: \{action.title}.",
      }
    None =>
      {
        handoff_id: "robo-handoff-\{proof.robot_id}",
        robot_id: proof.robot_id,
        status: "incomplete",
        can_act: false,
        needs_operator: true,
        needs_moonclaw: false,
        accepts_task_messages: false,
        physical_execution_allowed: false,
        next_owner: "operator",
        next_method: "GET",
        next_route: proof.next_route,
        target_route: proof.next_route,
        next_kind: "loop-proof",
        next_title: "Continue MoonRobo loop proof",
        next_work_id: "",
        queue_count: 0,
        readiness_status: readiness.status,
        readiness_ready: readiness.ready,
        loop_status: proof.status,
        loop_ready: proof.ready,
        loop_percent: proof.percent,
        latest_gateway_command_path: proof.latest_gateway_command_path,
        latest_execution_path: proof.latest_task_execution_path,
        message: proof.message,
      }
  }
}

///|
fn ready_handoff(
  proof : PlatformLoopProofResponse,
  readiness : @readiness.PlatformReadinessPlan,
) -> RoboHandoffResponse {
  {
    handoff_id: "robo-handoff-\{proof.robot_id}",
    robot_id: proof.robot_id,
    status: "ready",
    can_act: true,
    needs_operator: false,
    needs_moonclaw: false,
    accepts_task_messages: true,
    physical_execution_allowed: false,
    next_owner: "moontown",
    next_method: "POST",
    next_route: robo_ask_path(),
    target_route: robo_ask_path(),
    next_kind: "task-message",
    next_title: "Ask Robo",
    next_work_id: "",
    queue_count: 0,
    readiness_status: readiness.status,
    readiness_ready: readiness.ready,
    loop_status: proof.status,
    loop_ready: proof.ready,
    loop_percent: proof.percent,
    latest_gateway_command_path: proof.latest_gateway_command_path,
    latest_execution_path: proof.latest_task_execution_path,
    message: "MoonRobo is ready for the next Robo ask.",
  }
}

///|
fn work_handoff(
  proof : PlatformLoopProofResponse,
  readiness : @readiness.PlatformReadinessPlan,
  queue : @platform_queue.RobotPlatformQueue,
) -> RoboHandoffResponse {
  {
    handoff_id: "robo-handoff-\{proof.robot_id}",
    robot_id: proof.robot_id,
    status: "moonclaw-context-ready",
    can_act: false,
    needs_operator: false,
    needs_moonclaw: true,
    accepts_task_messages: false,
    physical_execution_allowed: false,
    next_owner: "moonclaw",
    next_method: "GET",
    next_route: moonclaw_context_path(),
    target_route: moonclaw_context_path(),
    next_kind: "moonclaw-routine",
    next_title: "Read MoonClaw context",
    next_work_id: "",
    queue_count: queue.item_count,
    readiness_status: readiness.status,
    readiness_ready: readiness.ready,
    loop_status: proof.status,
    loop_ready: proof.ready,
    loop_percent: proof.percent,
    latest_gateway_command_path: proof.latest_gateway_command_path,
    latest_execution_path: proof.latest_task_execution_path,
    message: "MoonClaw owns the next move; read context at \{moonclaw_context_path()} and select from \{queue.item_count} platform work item(s).",
  }
}

///|
pub fn robo_handoff_response(root : String) -> HostApiResponse {
  let proof = match platform_loop_proof(root) {
    Ok(proof) => proof
    Err(response) => return response
  }
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
  }
  let readiness_report = @readiness.report(root, book)
  let readiness = @readiness.plan(readiness_report)
  if proof.ready && readiness.ready {
    return json_response(200, ready_handoff(proof, readiness).to_json())
  }
  let queue = match project_robot_platform_queue(root, 0L) {
    Ok(queue) => queue
    Err(response) => return response
  }
  if queue.item_count == 0 {
    return json_response(200, empty_handoff_action(proof, readiness).to_json())
  }
  json_response(200, work_handoff(proof, readiness, queue).to_json())
}
