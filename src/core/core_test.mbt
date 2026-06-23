///|
test "Noetix E1 profile validates and exposes high leverage capabilities" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let report = @core.validate_robot_profile(profile)
  assert_true(report.valid)
  assert_eq(profile.joints.length(), 24)
  assert_true(@core.profile_supports(profile, "observe.telemetry"))
  assert_true(@core.profile_supports(profile, "control.high.walk"))
  assert_true(@core.profile_supports(profile, "control.low.joint-position"))
}

///|
test "Safety gate requires dry run then approval for high control" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let intent = @core.command_intent(
    "intent-1",
    profile.id,
    "control.high.walk",
    @core.operator_requester("local"),
  )
  let base_context : @core.SafetyContext = {
    profile,
    bridge_health: @core.bridge_ok(
      "sdk-e1",
      profile.id,
      last_telemetry_age_ms=10,
    ),
    approval_id: None,
    dry_run_receipt_id: None,
    developer_gate: false,
  }
  let first = @core.evaluate_intent(base_context, intent)
  assert_true(first.decision == DryRunRequired)
  let after_dry_run = @core.evaluate_intent(
    { ..base_context, dry_run_receipt_id: Some("receipt-dry-run") },
    intent,
  )
  assert_true(after_dry_run.decision == ApprovalRequired)
  let approved = @core.evaluate_intent(
    {
      ..base_context,
      dry_run_receipt_id: Some("receipt-dry-run"),
      approval_id: Some("approval-1"),
    },
    intent,
  )
  assert_true(approved.decision == Allow)
  assert_true(receipt_status_for_verdict(approved) == ReadyForExecution)
  let ready = receipt_from_verdict(
    "receipt-ready",
    profile.bridge.id,
    intent,
    approved,
    10L,
  )
  let executed = executed_receipt(
    "receipt-executed",
    ready,
    20L,
    telemetry_frame_count=1,
  )
  assert_true(executed.status == Executed)
  assert_true(executed.ended_at_ms is Some(20L))
}

///|
test "Safety gate blocks stale telemetry and disabled low control" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let walk = @core.command_intent(
    "intent-2",
    profile.id,
    "control.high.walk",
    @core.operator_requester("local"),
  )
  let stale_context : @core.SafetyContext = {
    profile,
    bridge_health: @core.bridge_ok(
      "sdk-e1",
      profile.id,
      last_telemetry_age_ms=999,
    ),
    approval_id: Some("approval-1"),
    dry_run_receipt_id: Some("receipt-dry-run"),
    developer_gate: false,
  }
  assert_true(
    @core.evaluate_intent(stale_context, walk).reason == StaleTelemetry,
  )
  let low_control = @core.command_intent(
    "intent-3",
    profile.id,
    "control.low.joint-position",
    @core.operator_requester("local"),
  )
  let low_verdict = @core.evaluate_intent(
    {
      ..stale_context,
      bridge_health: @core.bridge_ok(
        "sdk-e1",
        profile.id,
        last_telemetry_age_ms=10,
      ),
    },
    low_control,
  )
  assert_true(low_verdict.reason == DisabledCapability)
}

///|
test "RoboBook readiness combines required paths and profile validity" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let ready = @core.inspect_robobook("examples/noetix-e1", profile, [
    "robot.json", "safety/policy.json", "bridge/bridge.json", "runs/receipts",
  ])
  assert_true(ready.ready)
  let missing = @core.inspect_robobook("examples/noetix-e1", profile, [
    "robot.json",
  ])
  assert_true(!missing.ready)
  assert_eq(missing.missing_paths.length(), 3)
}
