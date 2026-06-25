///|
pub(all) struct MoonroboProductCapability {
  code : String
  label : String
  ready : Bool
  evidence_path : String
  next_route : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboProductStatusInput {
  root : String
  robot_id : String
  bridge_id : String
  mapped : Bool
  has_task_message : Bool
  memory_card_count : Int
  can_run_robot_routine : Bool
  physical_execution_allowed : Bool
  loop_ready : Bool
  loop_percent : Int
  loop_status : String
  live_readiness_status : String
  latest_task_execution_path : String
  latest_routine_path : String
  latest_robo_loop_path : String
  latest_proof_session_path : String
  next_route : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboProductStatus {
  service : String
  root : String
  status : String
  ready : Bool
  percent : Int
  completed_count : Int
  total_count : Int
  robot_id : String
  bridge_id : String
  next_route : String
  capabilities : Array[MoonroboProductCapability]
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn product_status_path() -> String {
  "/api/moonrobo/status"
}

///|
fn capability(
  code : String,
  label : String,
  ready : Bool,
  evidence_path : String,
  next_route : String,
  pass_message : String,
  fail_message : String,
) -> MoonroboProductCapability {
  {
    code,
    label,
    ready,
    evidence_path,
    next_route,
    message: if ready {
      pass_message
    } else {
      fail_message
    },
  }
}

///|
fn completed_count(capabilities : Array[MoonroboProductCapability]) -> Int {
  let mut count = 0
  for item in capabilities {
    if item.ready {
      count += 1
    }
  }
  count
}

///|
fn first_blocked_route(
  capabilities : Array[MoonroboProductCapability],
  fallback : String,
) -> String {
  for item in capabilities {
    if !item.ready && item.next_route != "" {
      return item.next_route
    }
  }
  fallback
}

///|
fn status_text(
  ready : Bool,
  completed : Int,
  total : Int,
  can_run_robot_routine : Bool,
) -> String {
  if ready {
    "complete"
  } else if can_run_robot_routine && completed >= total - 1 {
    "routine-ready"
  } else if completed >= total / 2 {
    "agent-loop-forming"
  } else {
    "needs-foundation"
  }
}

///|
fn status_message(
  status : String,
  completed : Int,
  total : Int,
  next_route : String,
) -> String {
  match status {
    "complete" =>
      "Moonrobo has the first usable digital-physical agent loop: mapped body, task message, durable memory, routine loop, live readiness, and verified feedback."
    "routine-ready" =>
      "Moonrobo can run the bounded robot routine; continue with \{next_route} to collect sustained proof."
    "agent-loop-forming" =>
      "Moonrobo has \{completed}/\{total} first-loop capabilities; continue with \{next_route}."
    _ =>
      "Moonrobo still needs foundation evidence; continue with \{next_route}."
  }
}

///|
pub fn project(input : MoonroboProductStatusInput) -> MoonroboProductStatus {
  let has_routine_loop = input.latest_routine_path != "" &&
    input.latest_robo_loop_path != ""
  let capabilities = [
    capability(
      "digital-physical-map",
      "One RoboBook profile maps to one resident robot body",
      input.mapped,
      "/api/moontown/resident",
      "/api/moonrobo/readiness",
      "RoboBook identity is mapped to the resident robot.",
      "Complete RoboBook identity and readiness before robot work.",
    ),
    capability(
      "user-task-message",
      "User can ask Robo to do a task",
      input.has_task_message,
      "/api/moonbook/task-messages",
      "/api/moontown/tasks/message",
      "A user task message is persisted through MoonBook.",
      "Submit a task message so the robot loop has user intent.",
    ),
    capability(
      "moonbook-memory",
      "MoonBook remembers robot context",
      input.memory_card_count > 0,
      "/api/moonbook/memory",
      "/api/moonbook/remember",
      "MoonBook has durable robot memory cards.",
      "Persist MoonBook memory so later agent steps have recall.",
    ),
    capability(
      "moonclaw-robot-routine",
      "MoonClaw can use Moonrobo as the robot gateway",
      has_routine_loop,
      input.latest_routine_path,
      "/api/moonclaw/robot-routine",
      "A MoonClaw robot routine and canonical Robo loop are persisted.",
      "Run the MoonClaw robot routine through Moonrobo.",
    ),
    capability(
      "live-runtime-ready",
      "Live runtime is ready for bounded proof work",
      input.can_run_robot_routine,
      input.latest_proof_session_path,
      "/api/moonrobo/live-readiness",
      "The live runtime can run the bounded robot routine path.",
      "Collect runtime validation or calibration evidence.",
    ),
    capability(
      "physical-feedback-verified",
      "Physical execution feedback is verified",
      input.loop_ready && input.physical_execution_allowed,
      input.latest_task_execution_path,
      "/api/moonrobo/executions/feedback",
      "Verified task execution and physical feedback close the loop.",
      "Capture matched runtime and physical feedback for an executed task.",
    ),
  ]
  let completed = completed_count(capabilities)
  let total = capabilities.length()
  let ready = completed == total
  let next_route = first_blocked_route(capabilities, input.next_route)
  let status = status_text(ready, completed, total, input.can_run_robot_routine)
  {
    service: "moonrobo",
    root: input.root,
    status,
    ready,
    percent: if total == 0 {
      0
    } else {
      completed * 100 / total
    },
    completed_count: completed,
    total_count: total,
    robot_id: input.robot_id,
    bridge_id: input.bridge_id,
    next_route,
    capabilities,
    message: status_message(status, completed, total, next_route),
  }
}
