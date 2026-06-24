///|
test "Noetix E1 profile validates and exposes high leverage capabilities" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let report = @core.validate_robot_profile(profile)
  assert_true(report.valid)
  assert_eq(profile.joints.length(), 24)
  assert_true(@core.profile_supports(profile, "observe.telemetry"))
  assert_true(@core.profile_supports(profile, "control.emergency.stop"))
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
    parameters={ "x": "0.10", "yaw": "0.00", "duration_ms": "1000" },
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
  let dispatch = bridge_dispatch_evidence(
    "dispatch-request-execute-intent-1-20",
    "request-execute-intent-1-20",
    profile.bridge.id,
    profile.id,
    "ExecuteIntent",
    "POST",
    "/intents/execute",
    intent.intent_id,
    executed.receipt_id,
    "Accepted",
    "bridge receipt",
    20L,
  )
  assert_eq(dispatch.intent_id, "intent-1")
  assert_eq(dispatch.receipt_id, "receipt-executed")
  let partial = task_execution_snapshot(
    "task-execution-partial", "message-walk", "/moonbook/task-messages/message-walk.json",
    "/runs/receipts/receipt-executed.json", "/runs/bridge-dispatches/dispatch-request-execute-intent-1-20.json",
    "/moonbook/memory/memory.json", executed, dispatch, 21L,
  )
  let partial_proof = task_execution_proof(partial)
  assert_eq(partial_proof.status, "bridge-accepted")
  assert_true(!partial_proof.verified)
  let verified = task_execution_snapshot(
    "task-execution-verified",
    "message-walk",
    "/moonbook/task-messages/message-walk.json",
    "/runs/receipts/receipt-executed.json",
    "/runs/bridge-dispatches/dispatch-request-execute-intent-1-20.json",
    "/moonbook/memory/memory.json",
    executed,
    dispatch,
    22L,
    runtime_health_path="/runs/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    telemetry_frame_id="frame-execution-22",
    telemetry_captured_at_ms=22L,
  )
  let verified_proof = task_execution_proof(verified)
  assert_eq(verified_proof.status, "runtime-healthy")
  assert_true(!verified_proof.verified)
  assert_eq(verified.command_capability, "control.high.walk")
  assert_eq(verified.command_outcome_status, "motion-feedback-observed")
  assert_true(!verified.command_outcome_verified)
  let feedback_frame = {
    ..empty_telemetry_frame(
      "frame-execution-22",
      profile.id,
      profile.bridge.id,
      22L,
    ),
    imu: Some({
      orientation: [1.0, 0.0, 0.0, 0.0],
      angular_velocity: [0.0, 0.0, 0.0],
      linear_acceleration: [0.0, 0.0, 9.8],
    }),
  }
  let observed_outcome = command_outcome_evidence(
    verified,
    Some(feedback_frame),
  )
  assert_eq(observed_outcome.status, "motion-feedback-observed")
  assert_true(!observed_outcome.verified)
  let checked_frame = {
    ..feedback_frame,
    operator_input: {
      "source": "sdk-e1",
      "command_intent_id": intent.intent_id,
      "command_capability": "control.high.walk",
      "command_x": "0.10",
      "command_yaw": "0.00",
      "command_duration_ms": "1000",
    },
  }
  let incomplete_echo = command_outcome_evidence(
    verified,
    Some(checked_frame),
    intent=Some(intent),
  )
  assert_eq(incomplete_echo.status, "motion-feedback-observed")
  assert_true(!incomplete_echo.verified)
  let checked_frame = {
    ..checked_frame,
    operator_input: {
      "source": "sdk-e1",
      "command_intent_id": intent.intent_id,
      "command_capability": "control.high.walk",
      "command_bridge_request_id": dispatch.request_id,
      "command_receipt_id": executed.receipt_id,
      "command_x": "0.10",
      "command_yaw": "0.00",
      "command_duration_ms": "1000",
    },
  }
  let outcome = command_outcome_evidence(
    verified,
    Some(checked_frame),
    intent=Some(intent),
  )
  assert_eq(outcome.status, "motion-feedback-checked")
  assert_true(outcome.verified)
  let checked = task_execution_snapshot(
    "task-execution-checked",
    "message-walk",
    "/moonbook/task-messages/message-walk.json",
    "/runs/receipts/receipt-executed.json",
    "/runs/bridge-dispatches/dispatch-request-execute-intent-1-20.json",
    "/moonbook/memory/memory.json",
    executed,
    dispatch,
    22L,
    runtime_health_path="/runs/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    telemetry_frame_id="frame-execution-22",
    telemetry_captured_at_ms=22L,
    checked_command_outcome_status=outcome.status,
    checked_command_outcome_verified=outcome.verified,
  )
  let checked_proof = task_execution_proof(checked)
  assert_eq(checked_proof.status, "verified")
  assert_true(checked_proof.verified)
  let stale = task_execution_snapshot(
    "task-execution-stale",
    "message-walk",
    "/moonbook/task-messages/message-walk.json",
    "/runs/receipts/receipt-executed.json",
    "/runs/bridge-dispatches/dispatch-request-execute-intent-1-20.json",
    "/moonbook/memory/memory.json",
    executed,
    dispatch,
    22L,
    runtime_health_path="/runs/runtime-health/latest.json",
    runtime_status="healthy",
    runtime_health_persisted=true,
    telemetry_frame_id="frame-before-execution",
    telemetry_captured_at_ms=19L,
  )
  let stale_proof = task_execution_proof(stale)
  assert_eq(stale.physical_feedback_status, "stale")
  assert_eq(stale.command_outcome_status, "unconfirmed")
  let stale_frame = {
    ..feedback_frame,
    frame_id: "frame-before-execution",
    captured_at_ms: 19L,
  }
  let stale_outcome = command_outcome_evidence(stale, Some(stale_frame))
  assert_eq(stale_outcome.status, "feedback-stale")
  assert_true(!stale_outcome.verified)
  assert_eq(stale_proof.status, "runtime-healthy")
  assert_true(!stale_proof.verified)
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
test "Safety gate blocks malformed and oversized high-control motion" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let context : @core.SafetyContext = {
    profile,
    bridge_health: @core.bridge_ok(
      "sdk-e1",
      profile.id,
      last_telemetry_age_ms=10,
    ),
    approval_id: Some("approval-1"),
    dry_run_receipt_id: Some("receipt-dry-run"),
    developer_gate: false,
  }
  let malformed = @core.command_intent(
    "intent-malformed-walk",
    profile.id,
    "control.high.walk",
    @core.operator_requester("local"),
    parameters={ "x": "fast", "yaw": "0.0", "duration_ms": "500" },
  )
  let malformed_verdict = @core.evaluate_intent(context, malformed)
  assert_true(malformed_verdict.decision == Deny)
  assert_true(malformed_verdict.reason == InvalidParameter)
  let oversized = @core.command_intent(
    "intent-oversized-walk",
    profile.id,
    "control.high.walk",
    @core.operator_requester("local"),
    parameters={ "x": "0.30", "yaw": "0.0", "duration_ms": "500" },
  )
  let oversized_verdict = @core.evaluate_intent(context, oversized)
  assert_true(oversized_verdict.decision == Deny)
  assert_true(oversized_verdict.reason == MotionLimitExceeded)
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
