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
  latest_routine_path : String
  latest_live_proof_path : String
  next_route : String
  checks : Array[PlatformLoopProofCheck]
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn platform_loop_proof_path() -> String {
  "/api/moonrobo/loop-proof"
}

///|
fn json_paths(root : String, relative : String) -> Array[String] {
  let dir = @runtime.robobook_path(root, relative)
  if !@fsx.path_exists(dir) {
    return []
  }
  let names = @fsx.read_dir(dir) catch { _ => return [] }
  names.sort()
  let paths : Array[String] = []
  for name in names {
    if name.has_suffix(".json") {
      paths.push(@runtime.robobook_path(root, "\{relative}/\{name}"))
    }
  }
  paths
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
pub fn platform_loop_proof_response(root : String) -> HostApiResponse {
  let book = match @runtime.load_robobook(root) {
    Ok(book) => book
    Err(issue) =>
      return error_response(500, issue.code, issue.path, issue.message)
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
  let live_proof_paths = json_paths(root, "runs/live-proof")
  let routine_paths = json_paths(root, "runs/moonclaw-robot-routines")
  let verified_executions = verified_execution_count(root)
  let latest_execution_path = latest_path(execution_paths)
  let latest_routine_path = latest_path(routine_paths)
  let latest_live_proof_path = latest_path(live_proof_paths)
  let checks = [
    proof_check(
      "digital-physical-map",
      "One robot profile is mapped into Moontown",
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
      "moonclaw-robot-routine",
      "MoonClaw can use Moonrobo as the robot gateway",
      !routine_paths.is_empty(),
      moonclaw_robot_routine_path(),
      latest_routine_path,
      "A MoonClaw robot routine artifact proves the closed routine lane ran.",
      "Run the MoonClaw robot routine once from Rabbita or the CLI.",
    ),
    proof_check(
      "live-proof",
      "Moonrobo produces live proof for the routine",
      !live_proof_paths.is_empty(),
      platform_live_proof_path(),
      latest_live_proof_path,
      "A live-proof artifact records task-loop, readiness, and execution evidence.",
      "Run a robot routine or live proof to produce a proof artifact.",
    ),
    proof_check(
      "physical-feedback-verified",
      "Physical execution feedback is verified",
      verified_executions > 0,
      task_executions_path(),
      latest_execution_path,
      "At least one task execution has verified runtime and physical feedback.",
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
    "Moonrobo closed-loop goal is proven for this RoboBook root."
  } else {
    "Moonrobo loop is \{completed}/\{total} proven; continue with \{next_route}."
  }
  let response : PlatformLoopProofResponse = {
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
    latest_routine_path,
    latest_live_proof_path,
    next_route,
    checks,
    message,
  }
  json_response(200, response.to_json())
}
