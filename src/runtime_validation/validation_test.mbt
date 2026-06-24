///|
fn validation_plan(snapshot_ready? : Bool = true) -> @supervisor.SupervisorPlan {
  @supervisor.plan(
    @bridge_sidecar.runtime_spec_for_profile(
      @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01"),
      "examples/noetix-e1",
    ),
    snapshot_ready~,
  )
}

///|
fn healthy_snapshot(
  plan : @supervisor.SupervisorPlan,
) -> @runtime_process.RuntimeHealthSnapshot {
  {
    active: true,
    status: "healthy",
    running: true,
    pid: 42,
    launch_id: "runtime-validation-test",
    runtime_id: plan.runtime_id,
    bridge_base_url: plan.bridge_base_url,
    telemetry_ok: true,
    telemetry_status: "telemetry-ok",
    telemetry_message: "bridge telemetry is reachable",
    telemetry_path: "/telemetry/latest",
    telemetry_frame_id: "frame-validation",
    telemetry_captured_at_ms: 9000L,
    robot_id: plan.robot_id,
    bridge_id: plan.bridge_id,
    run: None,
  }
}

///|
test "runtime validation report passes only with live graph evidence" {
  let plan = validation_plan()
  let report = @runtime_validation.validation_report(
    plan,
    9000L,
    health=Some(healthy_snapshot(plan)),
    log_path="/tmp/moonrobo-runtime.log",
    log_exists=true,
  )
  assert_eq(report.status, "ready")
  assert_true(report.ready_for_live_sdk)
  assert_eq(report.observed_robot_id, plan.robot_id)
  assert_eq(report.observed_bridge_id, plan.bridge_id)
  assert_eq(report.fail_count, 0)
  assert_eq(report.check_count, 12)
  assert_true(
    report.checks.any(check => {
      check.code == "collector-snapshot-link" && check.status == "pass"
    }),
  )
  assert_true(
    report.checks.any(check => {
      check.code == "writer-command-outbox-link" && check.status == "pass"
    }),
  )
  assert_true(
    report.checks.any(check => {
      check.code == "bridge-command-feedback-link" && check.status == "pass"
    }),
  )
}

///|
test "runtime validation report blocks missing snapshot and telemetry" {
  let plan = validation_plan(snapshot_ready=false)
  let report = @runtime_validation.validation_report(
    plan,
    9100L,
    health=None,
    log_path="",
    log_exists=false,
  )
  assert_eq(report.status, "blocked")
  assert_true(!report.ready_for_live_sdk)
  assert_true(report.fail_count >= 4)
}

///|
test "runtime validation blocks incoherent command feedback graph" {
  let plan = validation_plan()
  let processes = plan.processes.map(fn(process) {
    if process.role == BridgeSidecar {
      {
        ..process,
        command: [
          "moonrobo-sdk-e1-bridge", "serve", "examples/noetix-e1", "127.0.0.1", "5391",
          "/tmp/wrong-snapshot.json", "read-only", "/tmp/wrong-command.json",
        ],
      }
    } else {
      process
    }
  })
  let broken = { ..plan, processes, }
  let report = @runtime_validation.validation_report(
    broken,
    9150L,
    health=Some(healthy_snapshot(plan)),
    log_path="/tmp/moonrobo-runtime.log",
    log_exists=true,
  )
  assert_eq(report.status, "blocked")
  assert_true(!report.ready_for_live_sdk)
  assert_true(
    report.checks.any(check => {
      check.code == "bridge-command-feedback-link" && check.status == "fail"
    }),
  )
}

///|
test "runtime validation session requires all samples ready" {
  let plan = validation_plan()
  let ready_a = @runtime_validation.validation_report(
    plan,
    9200L,
    health=Some(healthy_snapshot(plan)),
    log_path="/tmp/moonrobo-runtime-a.log",
    log_exists=true,
    report_id="runtime-validation-ready-a",
  )
  let ready_b = @runtime_validation.validation_report(
    plan,
    9201L,
    health=Some(healthy_snapshot(plan)),
    log_path="/tmp/moonrobo-runtime-b.log",
    log_exists=true,
    report_id="runtime-validation-ready-b",
  )
  let session = @runtime_validation.validation_session(
    [ready_a, ready_b],
    9300L,
    required_sample_count=2,
    session_id="runtime-validation-session-ready",
  )
  assert_eq(session.status, "ready")
  assert_true(session.ready_for_live_sdk)
  assert_eq(session.ready_sample_count, 2)
  assert_eq(session.blocked_sample_count, 0)
  assert_true(session.mapping_proof.stable)
  assert_eq(session.mapping_proof.status, "stable")
  assert_eq(session.mapping_proof.matching_sample_count, 2)
  assert_eq(session.mapping_proof.mismatch_sample_count, 0)
  assert_eq(session.report_ids.length(), 2)
}

///|
test "runtime validation session blocks telemetry identity mismatch" {
  let plan = validation_plan()
  let wrong_health = { ..healthy_snapshot(plan), robot_id: "other-robot" }
  let mismatch = @runtime_validation.validation_report(
    plan,
    9250L,
    health=Some(wrong_health),
    log_path="/tmp/moonrobo-runtime-mismatch.log",
    log_exists=true,
    report_id="runtime-validation-identity-mismatch",
  )
  assert_eq(mismatch.status, "blocked")
  assert_true(!mismatch.ready_for_live_sdk)
  assert_eq(mismatch.observed_robot_id, "other-robot")
  assert_eq(mismatch.observed_bridge_id, plan.bridge_id)
  let session = @runtime_validation.validation_session(
    [mismatch],
    9251L,
    required_sample_count=1,
    session_id="runtime-validation-session-identity-mismatch",
  )
  assert_eq(session.status, "blocked")
  assert_true(!session.ready_for_live_sdk)
  assert_true(!session.mapping_proof.stable)
  assert_eq(session.mapping_proof.status, "mismatch")
  assert_eq(session.mapping_proof.matching_sample_count, 0)
  assert_eq(session.mapping_proof.mismatch_sample_count, 1)
  assert_eq(
    session.mapping_proof.first_mismatch_report_id,
    "runtime-validation-identity-mismatch",
  )
}

///|
test "runtime validation session records first blocker" {
  let plan = validation_plan(snapshot_ready=false)
  let blocked = @runtime_validation.validation_report(
    plan,
    9400L,
    health=None,
    log_path="",
    log_exists=false,
    report_id="runtime-validation-blocked",
  )
  let session = @runtime_validation.validation_session(
    [blocked],
    9500L,
    required_sample_count=1,
    session_id="runtime-validation-session-blocked",
  )
  assert_eq(session.status, "blocked")
  assert_true(!session.ready_for_live_sdk)
  assert_eq(session.blocked_sample_count, 1)
  assert_eq(session.first_blocker_code, "collector-snapshot-ready")
}

///|
test "runtime calibration plan turns validation blockers into actions" {
  let plan = validation_plan(snapshot_ready=false)
  let blocked = @runtime_validation.validation_report(
    plan,
    9600L,
    health=None,
    log_path="",
    log_exists=false,
    report_id="runtime-validation-calibration-blocked",
  )
  let session = @runtime_validation.validation_session(
    [blocked, blocked],
    9700L,
    required_sample_count=2,
    session_id="runtime-validation-session-calibration",
  )
  let calibration = @runtime_validation.calibration_plan_for_session(
    session,
    9800L,
    plan_id="runtime-calibration-test",
  )
  assert_eq(calibration.status, "needs-calibration")
  assert_eq(calibration.session_id, "runtime-validation-session-calibration")
  assert_true(calibration.action_count >= 4)
  assert_true(
    calibration.actions.any(action => {
      action.blocker_code == "collector-snapshot-ready" && action.owner == "sdk"
    }),
  )
  assert_true(
    calibration.actions.any(action => {
      action.blocker_code == "runtime-active" && action.owner == "runtime"
    }),
  )
  assert_eq(
    calibration.actions
    .filter(action => action.blocker_code == "runtime-active")
    .length(),
    1,
  )
  let runtime_action = calibration.actions.filter(action => {
      action.blocker_code == "runtime-active"
    })[0]
  let resolution = @runtime_validation.calibration_resolution(
    calibration, runtime_action, "operator", 9900L, "started runtime supervisor and collected new evidence",
    "/api/runtime/validation/session",
  )
  assert_eq(resolution.plan_id, "runtime-calibration-test")
  assert_eq(resolution.action_id, runtime_action.action_id)
  assert_eq(resolution.blocker_code, "runtime-active")
  assert_eq(resolution.status, "resolved-pending-validation")
  assert_eq(resolution.next_validation_route, "/api/runtime/validation/session")
}
