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
  status : String
  ready_for_live_sdk : Bool
  check_count : Int
  pass_count : Int
  warn_count : Int
  fail_count : Int
  checks : Array[RuntimeValidationCheck]
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
  {
    report_id,
    generated_at_ms,
    runtime_id: plan.runtime_id,
    robot_id: plan.robot_id,
    bridge_id: plan.bridge_id,
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
  let ready = sample_count >= required_sample_count &&
    sample_count > 0 &&
    blocked_sample_count == 0
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
