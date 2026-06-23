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
  assert_eq(report.fail_count, 0)
  assert_eq(report.check_count, 9)
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
