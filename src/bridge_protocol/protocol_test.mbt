///|
fn profile() -> @core.RobotProfile {
  @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
}

///|
test "bridge protocol validates dry-run request" {
  let robot = profile()
  let intent = @core.command_intent(
    "intent-bridge-test",
    robot.id,
    "control.high.walk",
    @core.operator_requester("test"),
    parameters={ "x": "0.1", "yaw": "0.0", "duration_ms": "500" },
  )
  let request = @bridge_protocol.dry_run_request(
    "request-dry-run", robot, intent, 100L,
  )
  assert_true(@bridge_protocol.operation_mutates(request.operation))
  assert_eq(@bridge_protocol.route_for_request(request).http_method, "POST")
  assert_eq(
    @bridge_protocol.route_for_request(request).path,
    "/intents/dry-run",
  )
  assert_true(@bridge_protocol.validate_request(robot, request) is Ok(_))
  let decoded = @bridge_protocol.parse_request(
    @bridge_protocol.request_json(request),
  ).unwrap()
  assert_eq(decoded.request_id, request.request_id)
  assert_true(decoded.operation == DryRunIntent)
}

///|
test "bridge protocol rejects unsafe request shapes" {
  let robot = profile()
  let missing_intent = @bridge_protocol.bridge_request(
    "request-missing-intent",
    robot,
    ExecuteIntent,
    100L,
  )
  match @bridge_protocol.validate_request(robot, missing_intent) {
    Err(issue) => assert_eq(issue.code, "intent-missing")
    Ok(_) => fail("expected execute request without intent to fail")
  }
  let unsupported_intent = @core.command_intent(
    "intent-unsupported",
    robot.id,
    "control.high.fly",
    @core.operator_requester("test"),
  )
  let unsupported = @bridge_protocol.execute_request(
    "request-unsupported", robot, unsupported_intent, 100L,
  )
  match @bridge_protocol.validate_request(robot, unsupported) {
    Err(issue) => assert_eq(issue.code, "unsupported-capability")
    Ok(_) => fail("expected unsupported capability to fail")
  }
}

///|
test "bridge protocol serializes telemetry response" {
  let robot = profile()
  let request = @bridge_protocol.telemetry_request(
    "request-telemetry", robot, 200L,
  )
  let telemetry = @core.empty_telemetry_frame(
    "frame-1",
    robot.id,
    robot.bridge.id,
    200L,
  )
  let response = @bridge_protocol.telemetry_response(request, telemetry)
  let decoded = @bridge_protocol.parse_response(
    @bridge_protocol.response_json(response),
  ).unwrap()
  assert_true(decoded.status == Accepted)
  assert_true(decoded.telemetry is Some(_))
  match decoded.telemetry {
    Some(frame) => assert_eq(frame.frame_id, "frame-1")
    None => fail("expected telemetry frame")
  }
}

///|
test "bridge protocol expands session stop route" {
  let robot = profile()
  let start = @bridge_protocol.start_observe_request(
    "request-start-session", robot, "session-1", 250L,
  )
  assert_eq(@bridge_protocol.route_for_request(start).path, "/sessions/observe")
  assert_true(@bridge_protocol.validate_request(robot, start) is Ok(_))
  let request = @bridge_protocol.bridge_request(
    "request-stop-session",
    robot,
    StopSession,
    300L,
    session_id="session-1",
  )
  assert_eq(
    @bridge_protocol.route_for_request(request).path,
    "/sessions/session-1/stop",
  )
  assert_true(@bridge_protocol.validate_request(robot, request) is Ok(_))
}
