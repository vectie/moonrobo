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
