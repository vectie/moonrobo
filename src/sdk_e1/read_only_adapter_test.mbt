///|
fn profile() -> @core.RobotProfile {
  @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
}

///|
fn snapshot() -> @sdk_e1.SdkE1Snapshot {
  let robot = profile()
  {
    ..@sdk_e1.default_snapshot("sdk-frame-1", 100L, telemetry_age_ms=12),
    joints: @sdk_e1.default_joint_states(robot),
  }
}

///|
test "sdk e1 adapter maps read-only telemetry" {
  let robot = profile()
  let frame = @sdk_e1.telemetry_frame(robot, snapshot()).unwrap()
  assert_eq(frame.frame_id, "sdk-frame-1")
  assert_eq(frame.bridge_id, "sdk-e1")
  assert_eq(frame.mode, "high")
  assert_eq(frame.joints.length(), 24)
  assert_eq(frame.joints[23].name, "waist_2_joint")
  assert_eq(frame.joints[23].index, 23)
  assert_eq(frame.operator_input.get("source").unwrap(), "sdk-e1")
}

///|
test "sdk e1 adapter maps high-control walk command" {
  let intent = @core.command_intent(
    "intent-sdk-e1-walk",
    "noetix-e1-lab-01",
    "control.high.walk",
    @core.operator_requester("sdk-e1-test"),
    parameters={ "x": "0.10", "yaw": "-0.05", "duration_ms": "900" },
  )
  let command = @sdk_e1.high_control_command(intent).unwrap()
  assert_eq(command.action, "WALK")
  assert_eq(command.action_code, 0)
  assert_eq(command.vertical, 0.10)
  assert_eq(command.horizontal, -0.05)
  assert_eq(command.duration_ms, 900)
  assert_true(@sdk_e1.high_control_command_artifact(command).contains("WALK"))
}

///|
test "sdk e1 adapter echoes command intent into feedback telemetry" {
  let robot = profile()
  let intent = @core.command_intent(
    "intent-sdk-e1-feedback",
    robot.id,
    "control.high.walk",
    @core.operator_requester("sdk-e1-test"),
    parameters={ "x": "0.10", "yaw": "-0.05", "duration_ms": "900" },
  )
  let frame = @sdk_e1.command_feedback_frame(
    robot,
    snapshot(),
    intent,
    frame_id="sdk-command-feedback",
    bridge_request_id="request-sdk-e1-feedback",
    receipt_id="receipt-sdk-e1-feedback",
  ).unwrap()
  assert_eq(frame.frame_id, "sdk-command-feedback")
  assert_eq(frame.operator_input.get("source").unwrap(), "sdk-e1")
  assert_eq(
    frame.operator_input.get("command_intent_id").unwrap(),
    "intent-sdk-e1-feedback",
  )
  assert_eq(
    frame.operator_input.get("command_capability").unwrap(),
    "control.high.walk",
  )
  assert_eq(
    frame.operator_input.get("command_bridge_request_id").unwrap(),
    "request-sdk-e1-feedback",
  )
  assert_eq(
    frame.operator_input.get("command_receipt_id").unwrap(),
    "receipt-sdk-e1-feedback",
  )
  assert_eq(frame.operator_input.get("command_x").unwrap(), "0.10")
  assert_eq(frame.operator_input.get("command_yaw").unwrap(), "-0.05")
  assert_eq(frame.operator_input.get("command_duration_ms").unwrap(), "900")
}

///|
test "sdk e1 adapter maps emergency stop command to safe hold envelope" {
  let command = @sdk_e1.emergency_stop_command("request-emergency-test")
  assert_eq(command.intent_id, "intent-request-emergency-test-emergency-stop")
  assert_eq(command.capability, "control.emergency.stop")
  assert_eq(command.action, "DEFAULT")
  assert_eq(command.action_code, 12)
  assert_eq(command.vertical, 0.0)
  assert_eq(command.horizontal, 0.0)
  assert_eq(command.duration_ms, 0)
  assert_true(
    @sdk_e1.high_control_command_artifact(command).contains("DEFAULT"),
  )
}

///|
test "sdk e1 adapter rejects unsupported high-control command" {
  let intent = @core.command_intent(
    "intent-sdk-e1-low",
    "noetix-e1-lab-01",
    "control.low.joint-position",
    @core.operator_requester("sdk-e1-test"),
  )
  let result = @sdk_e1.high_control_command(intent)
  assert_true(result is Err(_))
  match result {
    Err(issue) => assert_eq(issue.code, "unsupported-high-control")
    Ok(_) => fail("expected unsupported command")
  }
}

///|
test "sdk e1 adapter preserves motor errors" {
  let robot = profile()
  let states = @sdk_e1.default_joint_states(robot)
  states[3] = { ..states[3], error: 7 }
  let frame = @sdk_e1.telemetry_frame(robot, { ..snapshot(), joints: states }).unwrap()
  assert_eq(frame.joints[3].error.unwrap(), "sdk-error-7")
}

///|
test "sdk e1 adapter rejects wrong joint count" {
  let robot = profile()
  let bad = { ..snapshot(), joints: [] }
  match @sdk_e1.telemetry_frame(robot, bad) {
    Err(issue) => assert_eq(issue.code, "joint-count-mismatch")
    Ok(_) => fail("expected wrong joint count to fail")
  }
}

///|
test "sdk e1 adapter produces bridge protocol responses" {
  let robot = profile()
  let health = @sdk_e1.health_response("request-sdk-health", robot, snapshot())
  assert_true(health.status == Accepted)
  assert_true(health.health is Some(_))
  let response = @sdk_e1.telemetry_response(
    "request-sdk-telemetry",
    robot,
    snapshot(),
  ).unwrap()
  assert_true(response.status == Accepted)
  assert_true(response.telemetry is Some(_))
}

///|
test "sdk e1 snapshot JSON round trip" {
  let decoded = @sdk_e1.parse_snapshot(@sdk_e1.snapshot_json(snapshot())).unwrap()
  assert_eq(decoded.frame_id, "sdk-frame-1")
  assert_eq(decoded.joints.length(), 24)
  assert_eq(@sdk_e1.mode_text(decoded.mode), "high")
}
