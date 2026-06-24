///|
pub(all) struct RuntimeValidationCheck {
  code : String
  status : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeValidationReport {
  report_id : String
  generated_at_ms : Int64
  runtime_id : String
  robot_id : String
  bridge_id : String
  observed_robot_id : String
  observed_bridge_id : String
  status : String
  ready_for_live_sdk : Bool
  check_count : Int
  pass_count : Int
  warn_count : Int
  fail_count : Int
  checks : Array[RuntimeValidationCheck]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeMappingProof {
  robot_id : String
  bridge_id : String
  sample_count : Int
  matching_sample_count : Int
  mismatch_sample_count : Int
  stable : Bool
  status : String
  first_mismatch_report_id : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeValidationSession {
  session_id : String
  generated_at_ms : Int64
  runtime_id : String
  robot_id : String
  bridge_id : String
  status : String
  ready_for_live_sdk : Bool
  required_sample_count : Int
  sample_count : Int
  ready_sample_count : Int
  blocked_sample_count : Int
  first_blocker_code : String
  mapping_proof : RuntimeMappingProof
  report_ids : Array[String]
  reports : Array[RuntimeValidationReport]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeCalibrationAction {
  action_id : String
  blocker_code : String
  severity : String
  owner : String
  evidence_path : String
  summary : String
  next_step : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeCalibrationPlan {
  plan_id : String
  generated_at_ms : Int64
  session_id : String
  runtime_id : String
  robot_id : String
  bridge_id : String
  status : String
  action_count : Int
  blocking_action_count : Int
  actions : Array[RuntimeCalibrationAction]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct RuntimeCalibrationResolution {
  resolution_id : String
  plan_id : String
  action_id : String
  blocker_code : String
  owner : String
  resolved_by : String
  resolved_at_ms : Int64
  note : String
  evidence_path : String
  next_validation_route : String
  status : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn check(
  code : String,
  status : String,
  path : String,
  message : String,
) -> RuntimeValidationCheck {
  { code, status, path, message }
}

///|
fn pass(
  code : String,
  path : String,
  message : String,
) -> RuntimeValidationCheck {
  check(code, "pass", path, message)
}

///|
fn fail(
  code : String,
  path : String,
  message : String,
) -> RuntimeValidationCheck {
  check(code, "fail", path, message)
}

///|
fn count_status(checks : Array[RuntimeValidationCheck], status : String) -> Int {
  let mut count = 0
  for check in checks {
    if check.status == status {
      count += 1
    }
  }
  count
}

///|
fn first_blocker_code(reports : Array[RuntimeValidationReport]) -> String {
  for report in reports {
    if !report.ready_for_live_sdk {
      for check in report.checks {
        if check.status == "fail" {
          return check.code
        }
      }
      return report.status
    }
  }
  ""
}

///|
fn count_ready_reports(reports : Array[RuntimeValidationReport]) -> Int {
  let mut count = 0
  for report in reports {
    if report.ready_for_live_sdk {
      count += 1
    }
  }
  count
}

///|
fn report_mapping_matches(report : RuntimeValidationReport) -> Bool {
  report.observed_robot_id == report.robot_id &&
  report.observed_bridge_id == report.bridge_id
}

///|
fn runtime_mapping_proof(
  reports : Array[RuntimeValidationReport],
) -> RuntimeMappingProof {
  let sample_count = reports.length()
  let robot_id = match reports.get(0) {
    Some(report) => report.robot_id
    None => ""
  }
  let bridge_id = match reports.get(0) {
    Some(report) => report.bridge_id
    None => ""
  }
  let mut matching_sample_count = 0
  let mut first_mismatch_report_id = ""
  for report in reports {
    if report_mapping_matches(report) {
      matching_sample_count += 1
    } else if first_mismatch_report_id == "" {
      first_mismatch_report_id = report.report_id
    }
  }
  let mismatch_sample_count = sample_count - matching_sample_count
  let stable = sample_count > 0 && mismatch_sample_count == 0
  {
    robot_id,
    bridge_id,
    sample_count,
    matching_sample_count,
    mismatch_sample_count,
    stable,
    status: if stable {
      "stable"
    } else {
      "mismatch"
    },
    first_mismatch_report_id,
    message: if stable {
      "\{matching_sample_count} validation sample(s) matched RoboBook robot \{robot_id} and bridge \{bridge_id}"
    } else if sample_count == 0 {
      "no runtime validation samples were collected"
    } else {
      "\{mismatch_sample_count} validation sample(s) did not match RoboBook robot \{robot_id} and bridge \{bridge_id}"
    },
  }
}

///|
fn contains_action(
  actions : Array[RuntimeCalibrationAction],
  blocker_code : String,
) -> Bool {
  actions.any(action => action.blocker_code == blocker_code)
}

///|
fn calibration_action_for_check(
  check : RuntimeValidationCheck,
) -> RuntimeCalibrationAction {
  match check.code {
    "supervisor-plan-ready" =>
      {
        action_id: "calibrate-supervisor-plan",
        blocker_code: check.code,
        severity: "blocker",
        owner: "runtime",
        evidence_path: check.path,
        summary: "physical runtime supervisor plan is not launch-ready",
        next_step: "inspect the supervisor manifest and fix unavailable process specs before starting hardware",
      }
    "collector-command-ready" =>
      {
        action_id: "calibrate-collector-command",
        blocker_code: check.code,
        severity: "blocker",
        owner: "sdk",
        evidence_path: check.path,
        summary: "SDK telemetry collector command is unavailable",
        next_step: "install or bundle the SDK collector command and rerun runtime validation",
      }
    "writer-command-ready" =>
      {
        action_id: "calibrate-writer-command",
        blocker_code: check.code,
        severity: "blocker",
        owner: "sdk",
        evidence_path: check.path,
        summary: "SDK high-control writer command is unavailable",
        next_step: "install or bundle the SDK high-control writer and rerun runtime validation",
      }
    "bridge-command-ready" =>
      {
        action_id: "calibrate-bridge-command",
        blocker_code: check.code,
        severity: "blocker",
        owner: "bridge",
        evidence_path: check.path,
        summary: "SDK bridge sidecar command is unavailable",
        next_step: "install or bundle the bridge sidecar command and rerun runtime validation",
      }
    "collector-snapshot-ready" =>
      {
        action_id: "calibrate-collector-snapshot",
        blocker_code: check.code,
        severity: "blocker",
        owner: "sdk",
        evidence_path: check.path,
        summary: "SDK collector snapshot is missing",
        next_step: "start the supervised collector and verify it writes the expected snapshot file",
      }
    "collector-snapshot-link" =>
      {
        action_id: "calibrate-collector-snapshot-link",
        blocker_code: check.code,
        severity: "blocker",
        owner: "runtime",
        evidence_path: check.path,
        summary: "SDK collector is not wired to the runtime snapshot path",
        next_step: "align the collector output path with the bridge telemetry snapshot path before enabling live execution",
      }
    "writer-command-outbox-link" =>
      {
        action_id: "calibrate-writer-command-outbox",
        blocker_code: check.code,
        severity: "blocker",
        owner: "sdk",
        evidence_path: check.path,
        summary: "SDK high-control writer is not watching the runtime command outbox",
        next_step: "align the writer input path with the bridge command outbox before enabling live execution",
      }
    "bridge-command-feedback-link" =>
      {
        action_id: "calibrate-bridge-command-feedback",
        blocker_code: check.code,
        severity: "blocker",
        owner: "bridge",
        evidence_path: check.path,
        summary: "SDK bridge is not wired for control-gated command feedback",
        next_step: "launch the bridge in control-gated mode with the same snapshot and command outbox paths as the collector and writer",
      }
    "bridge-contract-ready" =>
      {
        action_id: "calibrate-bridge-contract-ready",
        blocker_code: check.code,
        severity: "blocker",
        owner: "bridge",
        evidence_path: check.path,
        summary: "live bridge authority contract is unavailable",
        next_step: "start the bridge sidecar and confirm GET /contract returns the bridge authority manifest",
      }
    "bridge-contract-identity" =>
      {
        action_id: "calibrate-bridge-contract-identity",
        blocker_code: check.code,
        severity: "blocker",
        owner: "robobook",
        evidence_path: check.path,
        summary: "live bridge contract identity does not match the selected RoboBook",
        next_step: "align the RoboBook robot id and bridge id with the sidecar contract before enabling dispatch",
      }
    "bridge-contract-execute-enabled" =>
      {
        action_id: "calibrate-bridge-contract-execute",
        blocker_code: check.code,
        severity: "blocker",
        owner: "bridge",
        evidence_path: check.path,
        summary: "live bridge contract does not enable ExecuteIntent",
        next_step: "launch the sidecar in control-gated mode and verify ExecuteIntent is enabled in GET /contract",
      }
    "bridge-contract-stop-enabled" =>
      {
        action_id: "calibrate-bridge-contract-stop",
        blocker_code: check.code,
        severity: "blocker",
        owner: "bridge",
        evidence_path: check.path,
        summary: "live bridge contract does not enable EmergencyStop",
        next_step: "launch the sidecar with the command outbox available and verify EmergencyStop is enabled in GET /contract",
      }
    "runtime-active" =>
      {
        action_id: "calibrate-runtime-process",
        blocker_code: check.code,
        severity: "blocker",
        owner: "runtime",
        evidence_path: check.path,
        summary: "physical runtime supervisor is not active",
        next_step: "start the runtime supervisor and confirm the active run receipt records a live PID",
      }
    "bridge-telemetry-healthy" =>
      {
        action_id: "calibrate-bridge-telemetry",
        blocker_code: check.code,
        severity: "blocker",
        owner: "bridge",
        evidence_path: check.path,
        summary: "bridge telemetry is not healthy",
        next_step: "verify bridge host, port, telemetry route, and SDK connectivity before enabling execution",
      }
    "runtime-identity-match" =>
      {
        action_id: "calibrate-runtime-identity",
        blocker_code: check.code,
        severity: "blocker",
        owner: "robobook",
        evidence_path: check.path,
        summary: "runtime telemetry identity does not match the selected RoboBook",
        next_step: "confirm the RoboBook robot id, bridge id, and SDK telemetry source describe the same physical body",
      }
    "runtime-log-ready" =>
      {
        action_id: "calibrate-runtime-log",
        blocker_code: check.code,
        severity: "warning",
        owner: "runtime",
        evidence_path: check.path,
        summary: "runtime supervisor log is missing",
        next_step: "start the supervisor through Moonrobo so stdout and stderr are captured in RoboBook evidence",
      }
    _ =>
      {
        action_id: "calibrate-\{check.code}",
        blocker_code: check.code,
        severity: "blocker",
        owner: "runtime",
        evidence_path: check.path,
        summary: check.message,
        next_step: "inspect the validation evidence and rerun runtime validation after fixing this blocker",
      }
  }
}

///|
pub fn calibration_resolution(
  plan : RuntimeCalibrationPlan,
  action : RuntimeCalibrationAction,
  resolved_by : String,
  resolved_at_ms : Int64,
  note : String,
  next_validation_route : String,
  resolution_id? : String = "runtime-calibration-resolution-\{action.action_id}-\{resolved_at_ms}",
) -> RuntimeCalibrationResolution {
  {
    resolution_id,
    plan_id: plan.plan_id,
    action_id: action.action_id,
    blocker_code: action.blocker_code,
    owner: action.owner,
    resolved_by,
    resolved_at_ms,
    note,
    evidence_path: action.evidence_path,
    next_validation_route,
    status: "resolved-pending-validation",
  }
}

///|
fn process_for_role(
  plan : @supervisor.SupervisorPlan,
  role : @bridge_sidecar.RuntimeProcessRole,
) -> @supervisor.SupervisorProcessStatus? {
  for process in plan.processes {
    if process.role == role {
      return Some(process)
    }
  }
  None
}

///|
fn process_check(
  plan : @supervisor.SupervisorPlan,
  role : @bridge_sidecar.RuntimeProcessRole,
  code : String,
  label : String,
) -> RuntimeValidationCheck {
  match process_for_role(plan, role) {
    None => fail(code, plan.runtime_id, "\{label} process is missing")
    Some(process) =>
      if process.command_available {
        pass(code, process.command_path, "\{label} command is available")
      } else {
        fail(code, process.command_path, "\{label} command is not available")
      }
  }
}

///|
fn command_arg_after(command : Array[String], flag : String) -> String {
  for index in 0..<command.length() {
    if command[index] == flag && index + 1 < command.length() {
      return command[index + 1]
    }
  }
  ""
}

///|
fn command_arg_at(command : Array[String], index : Int) -> String {
  match command.get(index) {
    Some(value) => value
    None => ""
  }
}

///|
fn collector_snapshot_link_check(
  plan : @supervisor.SupervisorPlan,
) -> RuntimeValidationCheck {
  match process_for_role(plan, SnapshotCollector) {
    None =>
      fail(
        "collector-snapshot-link",
        plan.snapshot_path,
        "collector process is missing",
      )
    Some(process) => {
      let output_arg = command_arg_after(process.command, "--output")
      if process.output_path == plan.snapshot_path &&
        output_arg == plan.snapshot_path {
        pass(
          "collector-snapshot-link",
          plan.snapshot_path,
          "collector writes the runtime snapshot path consumed by the bridge",
        )
      } else {
        fail(
          "collector-snapshot-link",
          plan.snapshot_path,
          "collector output \{process.output_path} and command output \{output_arg} do not match runtime snapshot \{plan.snapshot_path}",
        )
      }
    }
  }
}

///|
fn writer_command_path(plan : @supervisor.SupervisorPlan) -> String {
  match process_for_role(plan, HighControlWriter) {
    Some(process) => process.output_path
    None => ""
  }
}

///|
fn writer_command_outbox_link_check(
  plan : @supervisor.SupervisorPlan,
) -> RuntimeValidationCheck {
  match process_for_role(plan, HighControlWriter) {
    None =>
      fail(
        "writer-command-outbox-link", "", "high-control writer process is missing",
      )
    Some(process) => {
      let input_arg = command_arg_after(process.command, "--input")
      if process.output_path != "" && input_arg == process.output_path {
        pass(
          "writer-command-outbox-link",
          process.output_path,
          "writer watches the runtime command outbox",
        )
      } else {
        fail(
          "writer-command-outbox-link",
          process.output_path,
          "writer command input \{input_arg} does not match runtime command outbox \{process.output_path}",
        )
      }
    }
  }
}

///|
fn bridge_command_feedback_link_check(
  plan : @supervisor.SupervisorPlan,
) -> RuntimeValidationCheck {
  match process_for_role(plan, BridgeSidecar) {
    None =>
      fail(
        "bridge-command-feedback-link",
        plan.bridge_base_url,
        "bridge sidecar process is missing",
      )
    Some(process) => {
      let bridge_snapshot_path = command_arg_at(process.command, 5)
      let bridge_mode = command_arg_at(process.command, 6)
      let bridge_command_path = command_arg_at(process.command, 7)
      let expected_command_path = writer_command_path(plan)
      if bridge_snapshot_path == plan.snapshot_path &&
        bridge_mode == "control-gated" &&
        expected_command_path != "" &&
        bridge_command_path == expected_command_path {
        pass(
          "bridge-command-feedback-link",
          plan.bridge_base_url,
          "bridge runs control-gated with the runtime snapshot and command outbox",
        )
      } else {
        fail(
          "bridge-command-feedback-link",
          plan.bridge_base_url,
          "bridge snapshot \{bridge_snapshot_path}, mode \{bridge_mode}, and command outbox \{bridge_command_path} do not match runtime snapshot \{plan.snapshot_path} and writer outbox \{expected_command_path}",
        )
      }
    }
  }
}

///|
fn bridge_contract_route(
  contract : @bridge_protocol.BridgeContract,
  operation : @bridge_protocol.BridgeOperation,
) -> @bridge_protocol.BridgeOperationContract? {
  for route in contract.routes {
    if route.operation == operation {
      return Some(route)
    }
  }
  None
}

///|
fn bridge_contract_available_check(
  plan : @supervisor.SupervisorPlan,
  contract : @bridge_protocol.BridgeContract?,
) -> RuntimeValidationCheck {
  match contract {
    Some(_) =>
      pass(
        "bridge-contract-ready",
        "\{plan.bridge_base_url}/contract",
        "bridge authority contract is reachable",
      )
    None =>
      fail(
        "bridge-contract-ready",
        "\{plan.bridge_base_url}/contract",
        "bridge authority contract was not probed",
      )
  }
}

///|
fn bridge_contract_identity_check(
  plan : @supervisor.SupervisorPlan,
  contract : @bridge_protocol.BridgeContract?,
) -> RuntimeValidationCheck {
  match contract {
    Some(contract) if contract.robot_id == plan.robot_id &&
      contract.bridge_id == plan.bridge_id =>
      pass(
        "bridge-contract-identity",
        "\{plan.bridge_base_url}/contract",
        "bridge authority contract matches the selected RoboBook identity",
      )
    Some(contract) =>
      fail(
        "bridge-contract-identity",
        "\{plan.bridge_base_url}/contract",
        "bridge contract robot \{contract.robot_id} bridge \{contract.bridge_id} does not match RoboBook robot \{plan.robot_id} bridge \{plan.bridge_id}",
      )
    None =>
      fail(
        "bridge-contract-identity",
        "\{plan.bridge_base_url}/contract",
        "bridge identity cannot be validated without a contract",
      )
  }
}

///|
fn bridge_contract_operation_check(
  plan : @supervisor.SupervisorPlan,
  contract : @bridge_protocol.BridgeContract?,
  operation : @bridge_protocol.BridgeOperation,
  code : String,
  label : String,
) -> RuntimeValidationCheck {
  match contract {
    Some(contract) =>
      match bridge_contract_route(contract, operation) {
        Some(route) if route.can_move_hardware && route.enabled =>
          pass(code, route.route.path, "bridge contract enables \{label}")
        Some(route) =>
          fail(
            code,
            route.route.path,
            "bridge contract route \{route.route.path} does not enable \{label}",
          )
        None =>
          fail(
            code,
            "\{plan.bridge_base_url}/contract",
            "bridge contract does not expose \{label}",
          )
      }
    None =>
      fail(
        code,
        "\{plan.bridge_base_url}/contract",
        "bridge \{label} cannot be validated without a contract",
      )
  }
}

///|
fn active_runtime_check(
  health : @runtime_process.RuntimeHealthSnapshot?,
) -> RuntimeValidationCheck {
  match health {
    Some(snapshot) if snapshot.active && snapshot.running =>
      pass(
        "runtime-active",
        snapshot.runtime_id,
        "runtime supervisor is active and running",
      )
    Some(snapshot) =>
      fail(
        "runtime-active",
        snapshot.runtime_id,
        "runtime supervisor is not running",
      )
    None => fail("runtime-active", "", "runtime health snapshot is unavailable")
  }
}

///|
fn healthy_bridge_check(
  health : @runtime_process.RuntimeHealthSnapshot?,
) -> RuntimeValidationCheck {
  match health {
    Some(snapshot) if snapshot.status == "healthy" =>
      pass(
        "bridge-telemetry-healthy",
        snapshot.telemetry_path,
        "bridge telemetry is healthy",
      )
    Some(snapshot) =>
      fail(
        "bridge-telemetry-healthy",
        snapshot.telemetry_path,
        "bridge telemetry status is \{snapshot.status}",
      )
    None =>
      fail("bridge-telemetry-healthy", "", "bridge telemetry was not probed")
  }
}

///|
fn identity_check(
  plan : @supervisor.SupervisorPlan,
  health : @runtime_process.RuntimeHealthSnapshot?,
) -> RuntimeValidationCheck {
  match health {
    Some(snapshot) if snapshot.robot_id == plan.robot_id &&
      snapshot.bridge_id == plan.bridge_id =>
      pass(
        "runtime-identity-match",
        plan.runtime_id,
        "runtime telemetry matches the selected RoboBook robot and bridge",
      )
    Some(snapshot) =>
      fail(
        "runtime-identity-match",
        plan.runtime_id,
        "runtime telemetry robot \{snapshot.robot_id} bridge \{snapshot.bridge_id} does not match RoboBook robot \{plan.robot_id} bridge \{plan.bridge_id}",
      )
    None =>
      fail(
        "runtime-identity-match",
        plan.runtime_id,
        "runtime identity cannot be validated without telemetry",
      )
  }
}

///|
pub fn validation_report(
  plan : @supervisor.SupervisorPlan,
  generated_at_ms : Int64,
  health? : @runtime_process.RuntimeHealthSnapshot? = None,
  bridge_contract? : @bridge_protocol.BridgeContract? = None,
  log_path? : String = "",
  log_exists? : Bool = false,
  report_id? : String = "runtime-validation-\{plan.runtime_id}-\{generated_at_ms}",
) -> RuntimeValidationReport {
  let checks : Array[RuntimeValidationCheck] = []
  if plan.ready {
    checks.push(
      pass(
        "supervisor-plan-ready",
        plan.runtime_id,
        "supervisor manifest is ready",
      ),
    )
  } else {
    checks.push(
      fail(
        "supervisor-plan-ready",
        plan.runtime_id,
        "supervisor manifest is blocked",
      ),
    )
  }
  checks.push(
    process_check(
      plan,
      SnapshotCollector,
      "collector-command-ready",
      "collector",
    ),
  )
  checks.push(
    process_check(plan, HighControlWriter, "writer-command-ready", "writer"),
  )
  checks.push(
    process_check(plan, BridgeSidecar, "bridge-command-ready", "bridge"),
  )
  checks.push(collector_snapshot_link_check(plan))
  checks.push(writer_command_outbox_link_check(plan))
  checks.push(bridge_command_feedback_link_check(plan))
  checks.push(bridge_contract_available_check(plan, bridge_contract))
  checks.push(bridge_contract_identity_check(plan, bridge_contract))
  checks.push(
    bridge_contract_operation_check(
      plan,
      bridge_contract,
      ExecuteIntent,
      "bridge-contract-execute-enabled",
      "ExecuteIntent",
    ),
  )
  checks.push(
    bridge_contract_operation_check(
      plan,
      bridge_contract,
      EmergencyStop,
      "bridge-contract-stop-enabled",
      "EmergencyStop",
    ),
  )
  if plan.snapshot_ready {
    checks.push(
      pass(
        "collector-snapshot-ready",
        plan.snapshot_path,
        "collector snapshot exists",
      ),
    )
  } else {
    checks.push(
      fail(
        "collector-snapshot-ready",
        plan.snapshot_path,
        "collector snapshot is missing",
      ),
    )
  }
  checks.push(active_runtime_check(health))
  checks.push(healthy_bridge_check(health))
  checks.push(identity_check(plan, health))
  if log_path != "" && log_exists {
    checks.push(
      pass("runtime-log-ready", log_path, "runtime supervisor log exists"),
    )
  } else {
    checks.push(
      fail("runtime-log-ready", log_path, "runtime supervisor log is missing"),
    )
  }
  let pass_count = count_status(checks, "pass")
  let warn_count = count_status(checks, "warn")
  let fail_count = count_status(checks, "fail")
  let ready = fail_count == 0
  let observed_robot_id = match health {
    Some(snapshot) => snapshot.robot_id
    None => ""
  }
  let observed_bridge_id = match health {
    Some(snapshot) => snapshot.bridge_id
    None => ""
  }
  {
    report_id,
    generated_at_ms,
    runtime_id: plan.runtime_id,
    robot_id: plan.robot_id,
    bridge_id: plan.bridge_id,
    observed_robot_id,
    observed_bridge_id,
    status: if ready {
      "ready"
    } else {
      "blocked"
    },
    ready_for_live_sdk: ready,
    check_count: checks.length(),
    pass_count,
    warn_count,
    fail_count,
    checks,
  }
}

///|
pub fn validation_session(
  reports : Array[RuntimeValidationReport],
  generated_at_ms : Int64,
  required_sample_count? : Int = reports.length(),
  session_id? : String = "runtime-validation-session-\{generated_at_ms}",
) -> RuntimeValidationSession {
  let sample_count = reports.length()
  let ready_sample_count = count_ready_reports(reports)
  let blocked_sample_count = sample_count - ready_sample_count
  let mapping_proof = runtime_mapping_proof(reports)
  let ready = sample_count >= required_sample_count &&
    sample_count > 0 &&
    blocked_sample_count == 0 &&
    mapping_proof.stable
  let report_ids : Array[String] = []
  for report in reports {
    report_ids.push(report.report_id)
  }
  let runtime_id = match reports.get(0) {
    Some(report) => report.runtime_id
    None => ""
  }
  let robot_id = match reports.get(0) {
    Some(report) => report.robot_id
    None => ""
  }
  let bridge_id = match reports.get(0) {
    Some(report) => report.bridge_id
    None => ""
  }
  {
    session_id,
    generated_at_ms,
    runtime_id,
    robot_id,
    bridge_id,
    status: if ready {
      "ready"
    } else {
      "blocked"
    },
    ready_for_live_sdk: ready,
    required_sample_count,
    sample_count,
    ready_sample_count,
    blocked_sample_count,
    first_blocker_code: first_blocker_code(reports),
    mapping_proof,
    report_ids,
    reports,
  }
}

///|
pub fn calibration_plan_for_session(
  session : RuntimeValidationSession,
  generated_at_ms : Int64,
  plan_id? : String = "runtime-calibration-\{session.session_id}-\{generated_at_ms}",
) -> RuntimeCalibrationPlan {
  let actions : Array[RuntimeCalibrationAction] = []
  for report in session.reports {
    for check in report.checks {
      if check.status == "fail" && !contains_action(actions, check.code) {
        actions.push(calibration_action_for_check(check))
      }
    }
  }
  let mut blocking_action_count = 0
  for action in actions {
    if action.severity == "blocker" {
      blocking_action_count += 1
    }
  }
  {
    plan_id,
    generated_at_ms,
    session_id: session.session_id,
    runtime_id: session.runtime_id,
    robot_id: session.robot_id,
    bridge_id: session.bridge_id,
    status: if blocking_action_count == 0 {
      "ready"
    } else {
      "needs-calibration"
    },
    action_count: actions.length(),
    blocking_action_count,
    actions,
  }
}
