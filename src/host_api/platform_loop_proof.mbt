///|
pub(all) struct PlatformLoopProofCheck {
  code : String
  label : String
  ready : Bool
  evidence_route : String
  evidence_path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformLoopProofResponse {
  status : String
  ready : Bool
  completed_count : Int
  total_count : Int
  percent : Int
  robot_id : @core.RobotId
  root : String
  readiness_status : String
  readiness_pass_count : Int
  readiness_fail_count : Int
  latest_task_execution_path : String
  latest_gateway_command_path : String
  latest_robo_loop_path : String
  next_route : String
  checks : Array[PlatformLoopProofCheck]
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_loop_proof_path() -> String {
  "/api/moonrobo/loop-proof"
}

///|
pub fn platform_prove_loop_path() -> String {
  "/api/moonrobo/prove-loop"
}

///|
fn latest_path(paths : Array[String]) -> String {
  if paths.is_empty() {
    ""
  } else {
    paths[paths.length() - 1]
  }
}

///|
fn verified_execution_count(root : String) -> Int {
  let paths = match @runtime.list_task_execution_snapshot_paths(root) {
    Ok(paths) => paths
    Err(_) => return 0
  }
  let mut count = 0
  for path in paths {
    let snapshot = match @runtime.read_task_execution_snapshot_file(path) {
      Ok(snapshot) => snapshot
      Err(_) => continue
    }
    if @core.task_execution_proof(snapshot).verified {
      count += 1
    }
  }
  count
}

///|
fn latest_feedback_proof_session_path(root : String) -> String {
  let paths = match list_proof_session_paths(root) {
    Ok(paths) => paths
    Err(_) => return ""
  }
  let mut latest = ""
  for path in paths {
    let session = match read_proof_session_file(path) {
      Ok(session) => session
      Err(_) => continue
    }
    if session.feedback_binding_success_count > 0 {
      latest = session.session_path
    }
  }
  latest
}

///|
fn proof_check(
  code : String,
  label : String,
  ready : Bool,
  evidence_route : String,
  evidence_path : String,
  pass_message : String,
  fail_message : String,
) -> PlatformLoopProofCheck {
  {
    code,
    label,
    ready,
    evidence_route,
    evidence_path,
    message: if ready {
      pass_message
    } else {
      fail_message
    },
  }
}

///|
fn completed_count(checks : Array[PlatformLoopProofCheck]) -> Int {
  let mut count = 0
  for check in checks {
    if check.ready {
      count += 1
    }
  }
  count
}

///|
fn first_blocked_route(
  checks : Array[PlatformLoopProofCheck],
  fallback : String,
) -> String {
  for check in checks {
    if !check.ready && check.evidence_route != "" {
      return check.evidence_route
    }
  }
  fallback
}

///|
pub fn platform_loop_proof(
  root : String,
) -> Result[PlatformLoopProofResponse, HostApiResponse] {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return Err(error_response(500, issue.code, issue.path, issue.message))
  }
  let readiness = @readiness.report(root, book)
  let memory_paths = match @runtime.list_moonbook_memory_paths(root) {
    Ok(paths) => paths
    Err(_) => []
  }
  let task_message_paths = match
    @runtime.list_moonbook_task_message_paths(root) {
    Ok(paths) => paths
    Err(_) => []
  }
  let execution_paths = match
    @runtime.list_task_execution_snapshot_paths(root) {
    Ok(paths) => paths
    Err(_) => []
  }
  let gateway_command_paths = match
    @runtime.list_moonrobo_gateway_command_paths(root) {
    Ok(paths) => paths
    Err(_) => []
  }
  let robo_loop_paths = match @runtime.list_robo_loop_paths(root) {
    Ok(paths) => paths
    Err(_) => []
  }
  let verified_executions = verified_execution_count(root)
  let latest_execution_path = latest_path(execution_paths)
  let feedback_session_path = latest_feedback_proof_session_path(root)
  let feedback_verified = verified_executions > 0 || feedback_session_path != ""
  let feedback_evidence_path = if feedback_session_path != "" {
    feedback_session_path
  } else {
    latest_execution_path
  }
  let feedback_evidence_route = if feedback_session_path != "" {
    platform_proof_sessions_path()
  } else {
    task_executions_path()
  }
  let latest_gateway_command_path = latest_path(gateway_command_paths)
  let latest_robo_loop_path = latest_path(robo_loop_paths)
  let checks = [
    proof_check(
      "digital-physical-map",
      "One robot profile is mapped into MoonTown",
      book.status.ready && book.profile.id != "" && book.profile.bridge.id != "",
      resident_path(),
      @runtime.robobook_path(root, "robot.json"),
      "RoboBook identity, required paths, and bridge id are present.",
      "Complete RoboBook identity and required safety/bridge files first.",
    ),
    proof_check(
      "robobook-memory",
      "Robobook decorates MoonBook durable memory",
      !memory_paths.is_empty(),
      moonbook_memory_path(),
      latest_path(memory_paths),
      "MoonBook has durable robot memory cards for the Robo resident.",
      "Persist MoonBook robot memory so MoonClaw has recall before acting.",
    ),
    proof_check(
      "user-message-ledger",
      "User task messages persist through MoonBook",
      !task_message_paths.is_empty(),
      moonbook_task_messages_path(),
      latest_path(task_message_paths),
      "At least one user task message is durably recorded.",
      "Submit a task message so the user/Robo chat becomes actionable memory.",
    ),
    proof_check(
      "moonclaw-gateway-command",
      "MoonClaw can use MoonRobo as the robot gateway",
      !gateway_command_paths.is_empty(),
      moonrobo_gateway_command_path(),
      latest_gateway_command_path,
      "MoonClaw routine can submit robot commands through the MoonRobo gateway.",
      "Submit the next MoonClaw-authored robot command through MoonRobo.",
    ),
    proof_check(
      "robo-loop",
      "MoonRobo produces a canonical loop for the routine",
      latest_robo_loop_path != "",
      robo_loop_path(),
      latest_robo_loop_path,
      "A Robo loop artifact records task ingress, MoonClaw work, session state, and decision evidence.",
      "Run the canonical Robo loop after MoonClaw submits a gateway command.",
    ),
    proof_check(
      "physical-feedback-verified", "Physical execution feedback is verified", feedback_verified,
      feedback_evidence_route, feedback_evidence_path, "At least one task execution has verified runtime and physical feedback.",
      "Capture matched runtime/telemetry feedback for an executed task.",
    ),
  ]
  let completed = completed_count(checks)
  let total = checks.length()
  let ready = completed == total
  let percent = if total == 0 { 0 } else { completed * 100 / total }
  let status = if ready {
    "complete"
  } else if completed >= 3 {
    "operational-unproven"
  } else {
    "incomplete"
  }
  let next_route = first_blocked_route(checks, platform_readiness_path())
  let message = if ready {
    "MoonRobo closed-loop goal is proven for this RoboBook root."
  } else {
    "MoonRobo loop is \{completed}/\{total} proven; continue with \{next_route}."
  }
  Ok({
    status,
    ready,
    completed_count: completed,
    total_count: total,
    percent,
    robot_id: book.profile.id,
    root,
    readiness_status: readiness.status,
    readiness_pass_count: readiness.pass_count,
    readiness_fail_count: readiness.fail_count,
    latest_task_execution_path: latest_execution_path,
    latest_gateway_command_path,
    latest_robo_loop_path,
    next_route,
    checks,
    message,
  })
}

///|
pub fn platform_loop_proof_response(root : String) -> HostApiResponse {
  match platform_loop_proof(root) {
    Ok(response) => json_response(200, response.to_json())
    Err(response) => response
  }
}
