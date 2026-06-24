///|
pub(all) struct ReadinessCheck {
  code : String
  status : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformReadinessReport {
  report_id : String
  root : String
  robot_id : @core.RobotId
  ready : Bool
  status : String
  check_count : Int
  pass_count : Int
  fail_count : Int
  conversation_turn_count : Int
  memory_card_count : Int
  registered_capability_count : Int
  task_execution_count : Int
  latest_runtime_status : String
  checks : Array[ReadinessCheck]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ReadinessAction {
  action_id : String
  check_code : String
  priority : Int
  title : String
  summary : String
  http_method : String
  route : String
  body_schema : String
  body_template : Json?
  execution_mode : String
  physical_execution_allowed : Bool
  safety_note : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PlatformReadinessPlan {
  plan_id : String
  report_id : String
  status : String
  ready : Bool
  action_count : Int
  blocking_action_count : Int
  next_action : ReadinessAction?
  actions : Array[ReadinessAction]
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct RuntimeCalibrationPlanRecord {
  plan_id : String
  generated_at_ms : Int64
  action_count : Int
  blocking_action_count : Int
  actions : Array[Json]
} derive(FromJson)

///|
priv struct RuntimeCalibrationResolutionRecord {
  plan_id : String
  resolved_at_ms : Int64
  status : String
} derive(FromJson)

///|
priv struct RuntimeValidationSessionRecord {
  generated_at_ms : Int64
  ready_for_live_sdk : Bool
} derive(FromJson)

///|
fn check(
  code : String,
  status : String,
  path : String,
  message : String,
) -> ReadinessCheck {
  { code, status, path, message }
}

///|
fn pass(code : String, path : String, message : String) -> ReadinessCheck {
  check(code, "pass", path, message)
}

///|
fn fail(code : String, path : String, message : String) -> ReadinessCheck {
  check(code, "fail", path, message)
}

///|
fn count_status(checks : Array[ReadinessCheck], status : String) -> Int {
  let mut count = 0
  for item in checks {
    if item.status == status {
      count += 1
    }
  }
  count
}

///|
fn task_message_count(root : String) -> Int {
  match @runtime.list_moonbook_task_message_paths(root) {
    Ok(paths) => paths.length()
    Err(_) => 0
  }
}

///|
fn task_execution_count(root : String) -> Int {
  match @runtime.list_task_execution_snapshot_paths(root) {
    Ok(paths) => paths.length()
    Err(_) => 0
  }
}

///|
fn latest_memory(root : String) -> @moonbook.MoonBookMemoryPack? {
  let paths = match @runtime.list_moonbook_memory_paths(root) {
    Ok(paths) => paths
    Err(_) => return None
  }
  if paths.is_empty() {
    return None
  }
  let text = match
    @runtime.read_moonbook_memory_json_file(paths[paths.length() - 1]) {
    Ok(text) => text
    Err(_) => return None
  }
  let json = @json.parse(text) catch { _ => return None }
  let pack : @moonbook.MoonBookMemoryPack = @json.from_json(json) catch {
    _ => return None
  }
  Some(pack)
}

///|
fn latest_runtime_health(root : String) -> @runtime_health.RuntimeHealthRecord? {
  match @runtime.read_latest_runtime_health(root) {
    Ok(record) => record
    Err(_) => None
  }
}

///|
fn[T : @json.FromJson] read_json_record(path : String) -> T? {
  if !@fsx.path_exists(path) {
    return None
  }
  let text = @fsx.read_file_to_string(path) catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  Some(@json.from_json(json)) catch {
    _ => None
  }
}

///|
fn latest_runtime_calibration_plan(
  root : String,
) -> RuntimeCalibrationPlanRecord? {
  read_json_record(@runtime.latest_runtime_calibration_plan_path(root))
}

///|
fn latest_runtime_calibration_resolution(
  root : String,
) -> RuntimeCalibrationResolutionRecord? {
  read_json_record(@runtime.latest_runtime_calibration_resolution_path(root))
}

///|
fn latest_runtime_validation_session(
  root : String,
) -> RuntimeValidationSessionRecord? {
  read_json_record(@runtime.latest_runtime_validation_session_path(root))
}

///|
fn latest_bridge_contract(root : String) -> @bridge_protocol.BridgeContract? {
  read_json_record(@runtime.latest_bridge_contract_path(root))
}

///|
fn bridge_contract_route_enabled(
  contract : @bridge_protocol.BridgeContract,
  operation : @bridge_protocol.BridgeOperation,
) -> Bool {
  contract.routes.any(route => route.operation == operation && route.enabled)
}

///|
fn bridge_contract_ready(
  root : String,
  profile : @core.RobotProfile,
) -> ReadinessCheck {
  let path = @runtime.latest_bridge_contract_path(root)
  match latest_bridge_contract(root) {
    Some(contract) =>
      if contract.robot_id == profile.id &&
        contract.bridge_id == profile.bridge.id &&
        bridge_contract_route_enabled(contract, ExecuteIntent) &&
        bridge_contract_route_enabled(contract, EmergencyStop) {
        pass(
          "bridge-contract-ready", path, "latest bridge authority contract matches RoboBook and enables physical safety routes",
        )
      } else {
        fail(
          "bridge-contract-ready", path, "latest bridge authority contract does not match RoboBook or does not enable required physical routes",
        )
      }
    None =>
      fail(
        "bridge-contract-ready", path, "bridge authority contract evidence is not persisted",
      )
  }
}

///|
fn calibration_cleared_by_ready_session(
  root : String,
  plan : RuntimeCalibrationPlanRecord,
) -> Bool {
  match latest_runtime_validation_session(root) {
    Some(session) =>
      session.ready_for_live_sdk &&
      session.generated_at_ms > plan.generated_at_ms
    None => false
  }
}

///|
fn calibration_has_blockers(plan : RuntimeCalibrationPlanRecord) -> Bool {
  plan.blocking_action_count > 0 ||
  plan.action_count > 0 ||
  !plan.actions.is_empty()
}

///|
fn calibration_resolution_waiting(
  root : String,
  plan : RuntimeCalibrationPlanRecord,
) -> RuntimeCalibrationResolutionRecord? {
  match latest_runtime_calibration_resolution(root) {
    Some(value) =>
      if value.plan_id == plan.plan_id &&
        value.status == "resolved-pending-validation" {
        Some(value)
      } else {
        None
      }
    _ => None
  }
}

///|
fn calibration_resolution_covers_plan(
  root : String,
  plan : RuntimeCalibrationPlanRecord,
) -> Bool {
  plan.blocking_action_count <= 1 &&
  plan.action_count <= 1 &&
  calibration_resolution_waiting(root, plan) is Some(_)
}

///|
fn runtime_calibration_clear(
  root : String,
  plan : RuntimeCalibrationPlanRecord?,
) -> ReadinessCheck {
  match plan {
    Some(plan) =>
      if calibration_has_blockers(plan) &&
        !calibration_cleared_by_ready_session(root, plan) &&
        !calibration_resolution_covers_plan(root, plan) {
        fail(
          "runtime-calibration-clear",
          @runtime.latest_runtime_calibration_plan_path(root),
          "runtime calibration blockers must be resolved before physical dispatch",
        )
      } else {
        pass(
          "runtime-calibration-clear",
          @runtime.latest_runtime_calibration_plan_path(root),
          "no unresolved runtime calibration blockers are pending",
        )
      }
    _ =>
      pass(
        "runtime-calibration-clear",
        @runtime.latest_runtime_calibration_plan_path(root),
        "no unresolved runtime calibration blockers are pending",
      )
  }
}

///|
fn runtime_validation_current(
  root : String,
  plan : RuntimeCalibrationPlanRecord?,
) -> ReadinessCheck {
  let plan = match plan {
    Some(value) =>
      if calibration_has_blockers(value) &&
        !calibration_cleared_by_ready_session(root, value) {
        value
      } else {
        return pass(
          "runtime-validation-current",
          @runtime.latest_runtime_validation_session_path(root),
          "runtime validation is current for dispatch gating",
        )
      }
    _ =>
      return pass(
        "runtime-validation-current",
        @runtime.latest_runtime_validation_session_path(root),
        "runtime validation is current for dispatch gating",
      )
  }
  let resolution = match latest_runtime_calibration_resolution(root) {
    Some(value) =>
      if value.plan_id == plan.plan_id &&
        value.status == "resolved-pending-validation" {
        value
      } else {
        return pass(
          "runtime-validation-current",
          @runtime.latest_runtime_validation_session_path(root),
          "runtime validation is not waiting on a resolved calibration action",
        )
      }
    _ =>
      return pass(
        "runtime-validation-current",
        @runtime.latest_runtime_validation_session_path(root),
        "runtime validation is not waiting on a resolved calibration action",
      )
  }
  match latest_runtime_validation_session(root) {
    Some(session) if session.generated_at_ms > resolution.resolved_at_ms =>
      pass(
        "runtime-validation-current",
        @runtime.latest_runtime_validation_session_path(root),
        "runtime validation session is newer than the calibration resolution",
      )
    _ =>
      fail(
        "runtime-validation-current",
        @runtime.latest_runtime_validation_session_path(root),
        "runtime calibration was resolved but needs a newer validation session before dispatch",
      )
  }
}

///|
fn tool_registry(root : String) -> @tool_registry.ToolRegistry? {
  match @runtime.read_tool_registry(root) {
    Ok(registry) => Some(registry)
    Err(_) => None
  }
}

///|
fn capability_available(
  registry : @tool_registry.ToolRegistry,
  route : String,
) -> Bool {
  registry.providers.any(fn(provider) {
    provider.capabilities.any(fn(capability) { capability.route == route })
  })
}

///|
fn registry_ready(
  registry : @tool_registry.ToolRegistry?,
  robot_id : @core.RobotId,
) -> ReadinessCheck {
  match registry {
    Some(value) =>
      if value.robot_id == robot_id &&
        capability_available(value, "/api/moonbook/conversation") &&
        capability_available(value, "/api/moontown/tasks/message") &&
        capability_available(value, "/api/moontown/tasks/observe-run") {
        pass(
          "tool-registry-ready", "agents/tool-registry.json", "bounded Moonrobo tool capabilities are registered",
        )
      } else {
        fail(
          "tool-registry-ready", "agents/tool-registry.json", "tool registry is missing required Moonrobo capabilities",
        )
      }
    None =>
      fail(
        "tool-registry-ready", "agents/tool-registry.json", "tool registry is not persisted",
      )
  }
}

///|
fn action(
  action_id : String,
  check_code : String,
  priority : Int,
  title : String,
  summary : String,
  http_method : String,
  route : String,
  body_schema : String,
  body_template : Json?,
  execution_mode : String,
  safety_note : String,
) -> ReadinessAction {
  {
    action_id,
    check_code,
    priority,
    title,
    summary,
    http_method,
    route,
    body_schema,
    body_template,
    execution_mode,
    physical_execution_allowed: false,
    safety_note,
  }
}

///|
fn action_for_check(check : ReadinessCheck) -> ReadinessAction {
  match check.code {
    "robobook-ready" =>
      action(
        "repair-robobook-required-files",
        check.code,
        100,
        "Repair RoboBook required files",
        "Create or repair the selected RoboBook profile, safety policy, bridge config, and evidence directories.",
        "GET",
        "/api/health",
        "none",
        None,
        "robobook-repair",
        "Repair identity and required files before accepting any robot task.",
      )
    "tool-registry-ready" =>
      action(
        "persist-bounded-tool-registry",
        check.code,
        92,
        "Persist bounded tool registry",
        "Register Moonrobo routes as bounded suite tools for MoonClaw, Rabbita, and Moontown.",
        "GET",
        "/api/tools/registry",
        "none",
        None,
        "tool-bootstrap",
        "This only exposes allowlisted routes; it does not grant raw bridge or SDK authority.",
      )
    "moonbook-memory-ready" =>
      action(
        "persist-moonbook-robot-memory",
        check.code,
        88,
        "Persist MoonBook robot memory",
        "Write robot recall cards from the RoboBook evidence projection so agents remember what was observed.",
        "POST",
        "/api/moonbook/remember",
        "none",
        Some({}),
        "memory-bootstrap",
        "Memory persistence is evidence-only and cannot move the physical body.",
      )
    "task-message-present" =>
      action(
        "submit-first-operator-task-message",
        check.code,
        86,
        "Submit first operator task message",
        "Send the first user task message through the MoonBook task-message pipeline.",
        "POST",
        "/api/moontown/tasks/message",
        "TaskMessageRequest",
        Some({
          "message_id": "message-first-operator-task",
          "requested_by": {
            "kind": "operator",
            "id": "operator",
            "display": "Operator",
          },
          "message": "inspect robot status",
          "now_ms": "0",
          "robot_id": "",
        }),
        "task-message",
        "The message is classified and reviewed before any physical execution route can run.",
      )
    "runtime-health-ready" =>
      action(
        "start-supervised-runtime",
        check.code,
        84,
        "Start supervised runtime",
        "Launch or refresh the supervised physical runtime so health evidence can be persisted.",
        "POST",
        "/api/runtime/supervisor/start",
        "none",
        Some({}),
        "runtime-supervision",
        "Starting the supervisor validates process health; task execution still needs the normal review gates.",
      )
    "bridge-contract-ready" =>
      action(
        "persist-live-bridge-contract",
        check.code,
        95,
        "Persist live bridge contract",
        "Run repeated runtime validation so Moonrobo records the live bridge authority contract before dispatch.",
        "POST",
        "/api/runtime/validation/session",
        "RuntimeValidationSessionRequest",
        Some({ "sample_count": 3, "physical_execution_allowed": false }),
        "operator-validation",
        "Contract validation records bridge authority only; task dispatch remains separately gated.",
      )
    "runtime-calibration-clear" =>
      action(
        "resolve-runtime-calibration-blockers",
        check.code,
        96,
        "Resolve runtime calibration blockers",
        "Inspect and resolve the latest runtime calibration plan before any physical dispatch path continues.",
        "GET",
        "/api/agent/runtime-calibration/latest",
        "none",
        None,
        "operator-calibration",
        "Calibration work changes runtime readiness only; physical task dispatch remains separately gated.",
      )
    "runtime-validation-current" =>
      action(
        "rerun-runtime-validation-session",
        check.code,
        94,
        "Rerun runtime validation",
        "Run repeated runtime validation after calibration resolution so the next dispatch uses fresh physical-readiness evidence.",
        "POST",
        "/api/runtime/validation/session",
        "RuntimeValidationSessionRequest",
        Some({ "sample_count": 3, "physical_execution_allowed": false }),
        "operator-validation",
        "Validation probes readiness evidence and must not dispatch physical tasks.",
      )
    "task-execution-ready" =>
      action(
        "execute-reviewed-task-through-gates",
        check.code,
        82,
        "Execute reviewed task through gates",
        "Use the work queue to continue a reviewed MoonBook task through evaluation, dry-run, approval, runtime readiness, and bridge dispatch.",
        "GET",
        "/api/agent/work-queue",
        "none",
        None,
        "operator-review",
        "The work queue describes the next gated action; it must not bypass policy, approval, or runtime validation.",
      )
    _ =>
      action(
        "resolve-\{check.code}",
        check.code,
        50,
        "Resolve readiness blocker",
        check.message,
        "GET",
        "/api/moonrobo/readiness",
        "none",
        None,
        "inspection",
        "Inspect the failed check and rerun readiness after fixing the blocker.",
      )
  }
}

///|
fn contains_action(
  actions : Array[ReadinessAction],
  check_code : String,
) -> Bool {
  actions.any(action => action.check_code == check_code)
}

///|
pub fn plan(report : PlatformReadinessReport) -> PlatformReadinessPlan {
  let actions : Array[ReadinessAction] = []
  for check in report.checks {
    if check.status == "fail" && !contains_action(actions, check.code) {
      actions.push(action_for_check(check))
    }
  }
  actions.sort_by((left, right) => right.priority - left.priority)
  let next_action = actions.get(0)
  {
    plan_id: "moonrobo-readiness-plan-\{report.robot_id}",
    report_id: report.report_id,
    status: if report.ready {
      "ready"
    } else {
      "needs-action"
    },
    ready: report.ready,
    action_count: actions.length(),
    blocking_action_count: actions.length(),
    next_action,
    actions,
  }
}

///|
pub fn report(
  root : String,
  book : @runtime.LoadedRoboBook,
) -> PlatformReadinessReport {
  let task_messages = task_message_count(root)
  let executions = task_execution_count(root)
  let memory = latest_memory(root)
  let health = latest_runtime_health(root)
  let calibration_plan = latest_runtime_calibration_plan(root)
  let registry = tool_registry(root)
  let memory_card_count = match memory {
    Some(pack) => pack.card_count
    None => 0
  }
  let capability_count = match registry {
    Some(value) => value.capability_count
    None => 0
  }
  let runtime_status = match health {
    Some(record) => record.status
    None => "missing"
  }
  let checks : Array[ReadinessCheck] = [
    if book.status.ready {
      pass(
        "robobook-ready", root, "RoboBook profile and required paths are ready",
      )
    } else {
      fail(
        "robobook-ready", root, "RoboBook profile or required paths are not ready",
      )
    },
    if task_messages > 0 {
      pass(
        "task-message-present", "moonbook/task-messages", "MoonBook has persisted task messages",
      )
    } else {
      fail(
        "task-message-present", "moonbook/task-messages", "MoonBook has no persisted task messages",
      )
    },
    if memory_card_count > 0 {
      pass(
        "moonbook-memory-ready", "moonbook/memory", "MoonBook memory contains robot recall cards",
      )
    } else {
      fail(
        "moonbook-memory-ready", "moonbook/memory", "MoonBook memory is not persisted",
      )
    },
    registry_ready(registry, book.profile.id),
    bridge_contract_ready(root, book.profile),
    if runtime_status == "healthy" {
      pass(
        "runtime-health-ready", "runs/runtime-health/latest.json", "runtime health is healthy",
      )
    } else {
      fail(
        "runtime-health-ready", "runs/runtime-health/latest.json", "runtime health is not healthy",
      )
    },
    runtime_calibration_clear(root, calibration_plan),
    runtime_validation_current(root, calibration_plan),
    if executions > 0 {
      pass(
        "task-execution-ready", "runs/task-executions", "task execution evidence is persisted",
      )
    } else {
      fail(
        "task-execution-ready", "runs/task-executions", "no task execution evidence is persisted",
      )
    },
  ]
  let fail_count = count_status(checks, "fail")
  let pass_count = count_status(checks, "pass")
  let ready = fail_count == 0
  {
    report_id: "moonrobo-readiness-\{book.profile.id}",
    root,
    robot_id: book.profile.id,
    ready,
    status: if ready {
      "ready"
    } else {
      "blocked"
    },
    check_count: checks.length(),
    pass_count,
    fail_count,
    conversation_turn_count: task_messages,
    memory_card_count,
    registered_capability_count: capability_count,
    task_execution_count: executions,
    latest_runtime_status: runtime_status,
    checks,
  }
}

///|
pub fn report_json(
  report : PlatformReadinessReport,
  indent? : Int = 2,
) -> String {
  report.to_json().stringify(indent~)
}
