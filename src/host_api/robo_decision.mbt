///|
pub(all) struct RoboDecisionResponse {
  decision_id : String
  robot_id : @core.RobotId
  status : String
  can_act : Bool
  needs_operator : Bool
  needs_agent : Bool
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
  latest_routine_path : String
  latest_execution_path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn robo_decision_path() -> String {
  "/api/moonrobo/decision"
}

///|
fn empty_decision_action(
  proof : PlatformLoopProofResponse,
  readiness : @readiness.PlatformReadinessPlan,
) -> RoboDecisionResponse {
  match readiness.next_action {
    Some(action) =>
      {
        decision_id: "robo-decision-\{proof.robot_id}",
        robot_id: proof.robot_id,
        status: "needs-operator",
        can_act: false,
        needs_operator: true,
        needs_agent: false,
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
        latest_routine_path: proof.latest_routine_path,
        latest_execution_path: proof.latest_task_execution_path,
        message: "Operator action is required before MoonClaw can continue: \{action.title}.",
      }
    None =>
      {
        decision_id: "robo-decision-\{proof.robot_id}",
        robot_id: proof.robot_id,
        status: "incomplete",
        can_act: false,
        needs_operator: true,
        needs_agent: false,
        accepts_task_messages: false,
        physical_execution_allowed: false,
        next_owner: "operator",
        next_method: "GET",
        next_route: proof.next_route,
        target_route: proof.next_route,
        next_kind: "loop-proof",
        next_title: "Continue Moonrobo loop proof",
        next_work_id: "",
        queue_count: 0,
        readiness_status: readiness.status,
        readiness_ready: readiness.ready,
        loop_status: proof.status,
        loop_ready: proof.ready,
        loop_percent: proof.percent,
        latest_routine_path: proof.latest_routine_path,
        latest_execution_path: proof.latest_task_execution_path,
        message: proof.message,
      }
  }
}

///|
fn ready_decision(
  proof : PlatformLoopProofResponse,
  readiness : @readiness.PlatformReadinessPlan,
) -> RoboDecisionResponse {
  {
    decision_id: "robo-decision-\{proof.robot_id}",
    robot_id: proof.robot_id,
    status: "ready",
    can_act: true,
    needs_operator: false,
    needs_agent: false,
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
    latest_routine_path: proof.latest_routine_path,
    latest_execution_path: proof.latest_task_execution_path,
    message: "Moonrobo is ready for the next Robo ask.",
  }
}

///|
fn action_decision(
  proof : PlatformLoopProofResponse,
  readiness : @readiness.PlatformReadinessPlan,
  queue : @work_queue.AgentWorkQueue,
  item : @work_queue.AgentWorkItem,
  action : @work_queue.AgentNextAction,
) -> RoboDecisionResponse {
  let agent_ready = action.http_method == "POST" &&
    !action.physical_execution_allowed &&
    dispatchable_kind(action.kind)
  let status = if agent_ready { "agent-work-ready" } else { "needs-operator" }
  let next_owner = if agent_ready { "moonclaw" } else { "operator" }
  let next_route = if agent_ready {
    moonclaw_work_run_path()
  } else {
    action.route
  }
  {
    decision_id: "robo-decision-\{proof.robot_id}",
    robot_id: proof.robot_id,
    status,
    can_act: agent_ready,
    needs_operator: !agent_ready,
    needs_agent: agent_ready,
    accepts_task_messages: false,
    physical_execution_allowed: action.physical_execution_allowed,
    next_owner,
    next_method: action.http_method,
    next_route,
    target_route: action.route,
    next_kind: action.kind,
    next_title: action.title,
    next_work_id: item.work_id,
    queue_count: queue.item_count,
    readiness_status: readiness.status,
    readiness_ready: readiness.ready,
    loop_status: proof.status,
    loop_ready: proof.ready,
    loop_percent: proof.percent,
    latest_routine_path: proof.latest_routine_path,
    latest_execution_path: proof.latest_task_execution_path,
    message: if agent_ready {
      "MoonClaw can continue by calling \{moonclaw_work_run_path()}; the next gateway target is \{action.route}."
    } else {
      "Operator action is required before MoonClaw can continue: \{action.title}."
    },
  }
}

///|
pub fn robo_decision_response(root : String) -> HostApiResponse {
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
    return json_response(200, ready_decision(proof, readiness).to_json())
  }
  let queue = match project_agent_work_queue(root, 0L) {
    Ok(queue) => queue
    Err(response) => return response
  }
  let item = match queue.next_item {
    Some(item) => item
    None =>
      return json_response(
        200,
        empty_decision_action(proof, readiness).to_json(),
      )
  }
  let registry = match tool_registry_or_response(root, 0L) {
    Ok(registry) => registry
    Err(response) => return response
  }
  let action = @work_queue.action_for_item_with_registry(item, registry)
  json_response(
    200,
    action_decision(proof, readiness, queue, item, action).to_json(),
  )
}
