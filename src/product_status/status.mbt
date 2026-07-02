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
pub(all) struct MoonroboProductHomes {
  moonrobo_product_home : String
  moonrobo_gateway_commands_path : String
  moonrobo_dry_runs_path : String
  moonrobo_approvals_path : String
  moonrobo_robo_loops_path : String
  moonrobo_robo_turns_path : String
  moonrobo_prove_loop_path : String
  moonrobo_proof_sessions_path : String
  moonrobo_live_exercises_path : String
  moonrobo_bridge_dispatches_path : String
  moonrobo_bridge_contracts_path : String
  moonrobo_runtime_supervisor_path : String
  moonrobo_runtime_validation_path : String
  moonrobo_runtime_calibration_path : String
  moonrobo_runtime_health_path : String
  moonclaw_product_home : String
  moonclaw_robot_routine_runs_path : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct MoonroboProductStatusInput {
  root : String
  robot_id : String
  bridge_id : String
  mapped : Bool
  has_task_message : Bool
  memory_card_count : Int
  can_submit_gateway_command : Bool
  physical_execution_allowed : Bool
  loop_ready : Bool
  loop_percent : Int
  loop_status : String
  live_readiness_status : String
  latest_task_execution_path : String
  latest_gateway_command_path : String
  latest_robo_loop_path : String
  latest_proof_session_path : String
  proof_session_feedback_closed : Bool
  proof_session_feedback_binding_success_count : Int
  proof_session_latest_feedback_status : Int
  proof_session_latest_feedback_message : String
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
  product_homes : MoonroboProductHomes
  capabilities : Array[MoonroboProductCapability]
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn product_status_path() -> String {
  "/api/moonrobo/status"
}

///|
fn active_workspace_root() -> String {
  "."
}

///|
pub fn moonrobo_product_home_for_workspace_root(root : String) -> String {
  @moonsuite.product_home_for_workspace_root(root, "moonrobo").state_path
}

///|
pub fn moonrobo_product_home() -> String {
  moonrobo_product_home_for_workspace_root(active_workspace_root())
}

///|
pub fn moonclaw_product_home_for_workspace_root(root : String) -> String {
  @moonsuite.product_home_for_workspace_root(root, "moonclaw").state_path
}

///|
pub fn moonclaw_product_home() -> String {
  moonclaw_product_home_for_workspace_root(active_workspace_root())
}

///|
pub fn moonrobo_product_artifact_for_workspace_root(
  root : String,
  relative : String,
) -> String {
  @moonsuite.product_artifact_for_workspace_root(root, "moonrobo", relative)
}

///|
pub fn moonrobo_product_display_state_dir() -> String {
  @moonsuite.product_display_dir("moonrobo")
}

///|
pub fn moonrobo_product_display_artifact(relative : String) -> String {
  @moonsuite.product_display_artifact("moonrobo", relative)
}

///|
pub fn moonrobo_product_display_absolute_artifact(relative : String) -> String {
  @moonsuite.product_display_absolute_artifact("moonrobo", relative)
}

///|
pub fn moonclaw_product_artifact_for_workspace_root(
  root : String,
  relative : String,
) -> String {
  @moonsuite.product_artifact_for_workspace_root(root, "moonclaw", relative)
}

///|
pub fn moonrobo_gateway_commands_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "gateway-commands",
  )
}

///|
pub fn moonrobo_dry_runs_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "dry-runs",
  )
}

///|
pub fn moonrobo_approvals_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "approvals",
  )
}

///|
pub fn moonrobo_robo_loops_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "robo-loops",
  )
}

///|
pub fn moonrobo_robo_turns_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "robo-turns",
  )
}

///|
pub fn moonrobo_prove_loop_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "prove-loop",
  )
}

///|
pub fn moonrobo_proof_sessions_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "proof-sessions",
  )
}

///|
pub fn moonrobo_live_exercises_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "live-exercises",
  )
}

///|
pub fn moonrobo_bridge_dispatches_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "bridge-dispatches",
  )
}

///|
pub fn moonrobo_bridge_contracts_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "bridge-contracts",
  )
}

///|
pub fn moonrobo_runtime_supervisor_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "runtime-supervisor",
  )
}

///|
pub fn moonrobo_runtime_validation_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "runtime-validation",
  )
}

///|
pub fn moonrobo_runtime_calibration_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "runtime-calibration",
  )
}

///|
pub fn moonrobo_runtime_health_path() -> String {
  moonrobo_product_artifact_for_workspace_root(
    active_workspace_root(),
    "runtime-health",
  )
}

///|
pub fn moonclaw_robot_routine_runs_path() -> String {
  moonclaw_product_artifact_for_workspace_root(
    active_workspace_root(),
    "robot-routine-runs",
  )
}

///|
pub fn product_homes_for_workspace_root(root : String) -> MoonroboProductHomes {
  {
    moonrobo_product_home: moonrobo_product_home_for_workspace_root(root),
    moonrobo_gateway_commands_path: moonrobo_product_artifact_for_workspace_root(
      root, "gateway-commands",
    ),
    moonrobo_dry_runs_path: moonrobo_product_artifact_for_workspace_root(
      root, "dry-runs",
    ),
    moonrobo_approvals_path: moonrobo_product_artifact_for_workspace_root(
      root, "approvals",
    ),
    moonrobo_robo_loops_path: moonrobo_product_artifact_for_workspace_root(
      root, "robo-loops",
    ),
    moonrobo_robo_turns_path: moonrobo_product_artifact_for_workspace_root(
      root, "robo-turns",
    ),
    moonrobo_prove_loop_path: moonrobo_product_artifact_for_workspace_root(
      root, "prove-loop",
    ),
    moonrobo_proof_sessions_path: moonrobo_product_artifact_for_workspace_root(
      root, "proof-sessions",
    ),
    moonrobo_live_exercises_path: moonrobo_product_artifact_for_workspace_root(
      root, "live-exercises",
    ),
    moonrobo_bridge_dispatches_path: moonrobo_product_artifact_for_workspace_root(
      root, "bridge-dispatches",
    ),
    moonrobo_bridge_contracts_path: moonrobo_product_artifact_for_workspace_root(
      root, "bridge-contracts",
    ),
    moonrobo_runtime_supervisor_path: moonrobo_product_artifact_for_workspace_root(
      root, "runtime-supervisor",
    ),
    moonrobo_runtime_validation_path: moonrobo_product_artifact_for_workspace_root(
      root, "runtime-validation",
    ),
    moonrobo_runtime_calibration_path: moonrobo_product_artifact_for_workspace_root(
      root, "runtime-calibration",
    ),
    moonrobo_runtime_health_path: moonrobo_product_artifact_for_workspace_root(
      root, "runtime-health",
    ),
    moonclaw_product_home: moonclaw_product_home_for_workspace_root(root),
    moonclaw_robot_routine_runs_path: moonclaw_product_artifact_for_workspace_root(
      root, "robot-routine-runs",
    ),
  }
}

///|
pub fn product_homes() -> MoonroboProductHomes {
  product_homes_for_workspace_root(active_workspace_root())
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
  can_submit_gateway_command : Bool,
) -> String {
  if ready {
    "complete"
  } else if can_submit_gateway_command && completed >= total - 2 {
    "command-ready"
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
    "command-ready" =>
      "Moonrobo can run the bounded gateway command; continue with \{next_route} to collect sustained proof."
    "agent-loop-forming" =>
      "Moonrobo has \{completed}/\{total} first-loop capabilities; continue with \{next_route}."
    _ =>
      "Moonrobo still needs foundation evidence; continue with \{next_route}."
  }
}

///|
pub fn project(input : MoonroboProductStatusInput) -> MoonroboProductStatus {
  let has_routine_loop = input.latest_gateway_command_path != "" &&
    input.latest_robo_loop_path != ""
  let physical_feedback_ready = input.loop_ready &&
    (input.physical_execution_allowed || input.proof_session_feedback_closed)
  let physical_feedback_evidence_path = if input.proof_session_feedback_closed &&
    input.latest_proof_session_path != "" {
    input.latest_proof_session_path
  } else {
    input.latest_task_execution_path
  }
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
      "/api/moonrobo/ask",
      "A user task message is persisted through MoonBook.",
      "Ask Robo so the task, memory, loop proof, readiness, and decision stay in one response.",
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
      "moonclaw-gateway-command",
      "MoonClaw can use Moonrobo as the robot gateway",
      has_routine_loop,
      input.latest_gateway_command_path,
      "/api/moonrobo/gateway/command",
      "MoonClaw routine can submit robot commands through the Moonrobo gateway.",
      "Submit the next MoonClaw-authored robot command through Moonrobo.",
    ),
    capability(
      "live-runtime-ready",
      "Live runtime is ready for bounded proof work",
      input.can_submit_gateway_command,
      input.latest_proof_session_path,
      "/api/moonrobo/live-readiness",
      "The live runtime can run the bounded gateway command path.",
      "Collect runtime validation or calibration evidence.",
    ),
    capability(
      "physical-feedback-verified", "Physical execution feedback is verified", physical_feedback_ready,
      physical_feedback_evidence_path, "/api/moonrobo/executions/feedback", "Verified task execution and physical feedback close the loop.",
      "Capture matched runtime and physical feedback for an executed task.",
    ),
  ]
  let completed = completed_count(capabilities)
  let total = capabilities.length()
  let ready = completed == total
  let next_route = first_blocked_route(capabilities, input.next_route)
  let status = status_text(
    ready,
    completed,
    total,
    input.can_submit_gateway_command,
  )
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
    product_homes: product_homes_for_workspace_root(input.root),
    capabilities,
    message: status_message(status, completed, total, next_route),
  }
}
