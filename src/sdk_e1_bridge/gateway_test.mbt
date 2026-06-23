///|
fn gateway_config() -> @sdk_e1_bridge.SdkE1BridgeConfig {
  @sdk_e1_bridge.config("examples/noetix-e1")
}

///|
test "sdk e1 bridge serves health and telemetry" {
  let health = @sdk_e1_bridge.route(
    gateway_config(),
    "GET",
    "/health",
    "",
    now_ms=10L,
  )
  assert_eq(health.status, 200)
  assert_true(health.body.contains("\"operation\": \"Health\""))
  assert_true(health.body.contains("\"bridge_id\": \"sdk-e1\""))
  let telemetry = @sdk_e1_bridge.route(
    gateway_config(),
    "GET",
    "/telemetry/latest",
    "",
    now_ms=11L,
  )
  assert_eq(telemetry.status, 200)
  assert_true(telemetry.body.contains("\"operation\": \"LatestTelemetry\""))
  assert_true(telemetry.body.contains("\"frame_id\": \"sdk-e1-sidecar-11\""))
}

///|
test "sdk e1 bridge metadata reports command mode" {
  let read_only = @sdk_e1_bridge.route(
    gateway_config(),
    "GET",
    "/metadata",
    "",
    now_ms=10L,
  )
  assert_true(read_only.body.contains("\"read_only\": true"))
  let control_gated = @sdk_e1_bridge.route(
    @sdk_e1_bridge.config("examples/noetix-e1", read_only=false),
    "GET",
    "/metadata",
    "",
    now_ms=10L,
  )
  assert_true(control_gated.body.contains("\"read_only\": false"))
}

///|
test "sdk e1 bridge reads telemetry from snapshot file" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let path = "/tmp/moonrobo-sdk-e1-bridge-snapshot-test.json"
  let snapshot = {
    ..@sdk_e1.default_snapshot("sdk-file-frame", 123L, telemetry_age_ms=7),
    joints: @sdk_e1.default_joint_states(profile),
  }
  @fsx.write_string_to_file(path, @sdk_e1.snapshot_json(snapshot)) catch {
    _ => fail("failed to write snapshot file")
  }
  let response = @sdk_e1_bridge.route(
    @sdk_e1_bridge.config("examples/noetix-e1", snapshot_path=path),
    "GET",
    "/telemetry/latest",
    "",
    now_ms=999L,
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"frame_id\": \"sdk-file-frame\""))
  assert_true(response.body.contains("\"captured_at_ms\": \"123\""))
}

///|
test "sdk e1 bridge accepts observation session lifecycle" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let start = @bridge_protocol.start_observe_request(
    "request-sidecar-observe-start", profile, "session-sidecar-observe", 12L,
  )
  let started = @sdk_e1_bridge.route(
    gateway_config(),
    "POST",
    "/sessions/observe",
    @bridge_protocol.request_json(start),
    now_ms=12L,
  )
  assert_eq(started.status, 200)
  assert_true(started.body.contains("\"operation\": \"StartObserve\""))
  assert_true(
    started.body.contains("\"session_id\": \"session-sidecar-observe\""),
  )
  let stop = @bridge_protocol.stop_session_request(
    "request-sidecar-observe-stop", profile, "session-sidecar-observe", 13L,
  )
  let stopped = @sdk_e1_bridge.route(
    gateway_config(),
    "POST",
    "/sessions/session-sidecar-observe/stop",
    @bridge_protocol.request_json(stop),
    now_ms=13L,
  )
  assert_eq(stopped.status, 200)
  assert_true(stopped.body.contains("\"operation\": \"StopSession\""))
}

///|
fn execute_request(
  capability : String,
  x? : String = "0.10",
) -> @bridge_protocol.BridgeRequest {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let intent = @core.command_intent(
    "intent-sidecar-execute",
    profile.id,
    capability,
    @core.operator_requester("sidecar-test"),
    parameters={ "x": x, "yaw": "0.00", "duration_ms": "1000" },
  )
  @bridge_protocol.execute_request(
    "request-sidecar-execute", profile, intent, 12L,
  )
}

///|
test "sdk e1 bridge rejects execution while read only" {
  let request = execute_request("control.high.walk")
  let response = @sdk_e1_bridge.route(
    gateway_config(),
    "POST",
    "/intents/execute",
    @bridge_protocol.request_json(request),
    now_ms=12L,
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"status\": \"Rejected\""))
  assert_true(response.body.contains("read-only"))
}

///|
test "sdk e1 bridge accepts allowlisted high-control command when enabled" {
  let request = execute_request("control.high.walk")
  let command_path = "/tmp/moonrobo-sdk-e1-bridge-command-test.json"
  let response = @sdk_e1_bridge.route(
    @sdk_e1_bridge.config("examples/noetix-e1", read_only=false, command_path~),
    "POST",
    "/intents/execute",
    @bridge_protocol.request_json(request),
    now_ms=12L,
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"status\": \"Accepted\""))
  assert_true(response.body.contains("sdk-e1 high-control WALK"))
  assert_true(response.body.contains("sdk-e1://high-control/WALK"))
  assert_true(response.body.contains(command_path))
  assert_true(
    response.body.contains(
      "\"frame_id\": \"sdk-e1-command-feedback-intent-sidecar-execute-12\"",
    ),
  )
  assert_true(
    response.body.contains("\"command_intent_id\": \"intent-sidecar-execute\""),
  )
  assert_true(
    response.body.contains("\"command_capability\": \"control.high.walk\""),
  )
  assert_true(response.body.contains("\"command_x\": \"0.10\""))
  assert_true(response.body.contains("\"command_duration_ms\": \"1000\""))
  let command_json = @fsx.read_file_to_string(command_path) catch {
    _ => fail("failed to read SDK E1 command file")
  }
  assert_true(command_json.contains("\"action\": \"WALK\""))
  assert_true(
    command_json.contains("\"intent_id\": \"intent-sidecar-execute\""),
  )
}

///|
test "sdk e1 bridge rejects control-gated execution without command path" {
  let request = execute_request("control.high.walk")
  let response = @sdk_e1_bridge.route(
    @sdk_e1_bridge.config("examples/noetix-e1", read_only=false),
    "POST",
    "/intents/execute",
    @bridge_protocol.request_json(request),
    now_ms=12L,
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"status\": \"Rejected\""))
  assert_true(response.body.contains("no command output path"))
}

///|
test "sdk e1 bridge rejects invalid high-control command when enabled" {
  let request = execute_request("control.high.walk", x="fast")
  let response = @sdk_e1_bridge.route(
    @sdk_e1_bridge.config(
      "examples/noetix-e1",
      read_only=false,
      command_path="/tmp/moonrobo-sdk-e1-bridge-invalid-command-test.json",
    ),
    "POST",
    "/intents/execute",
    @bridge_protocol.request_json(request),
    now_ms=12L,
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"status\": \"Rejected\""))
  assert_true(response.body.contains("must be a number"))
}

///|
test "sdk e1 bridge rejects oversized high-control command before outbox write" {
  let command_path = "/tmp/moonrobo-sdk-e1-bridge-oversized-command-test.json"
  let request = execute_request("control.high.walk", x="0.30")
  let response = @sdk_e1_bridge.route(
    @sdk_e1_bridge.config("examples/noetix-e1", read_only=false, command_path~),
    "POST",
    "/intents/execute",
    @bridge_protocol.request_json(request),
    now_ms=12L,
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"status\": \"Rejected\""))
  assert_true(response.body.contains("exceeds profile limit"))
  assert_true(!@fsx.path_exists(command_path))
}

///|
test "sdk e1 bridge writes emergency stop command when control gated" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let request = @bridge_protocol.emergency_stop_request(
    "request-sidecar-emergency", profile, 22L,
  )
  let command_path = "/tmp/moonrobo-sdk-e1-bridge-emergency-test.json"
  let response = @sdk_e1_bridge.route(
    @sdk_e1_bridge.config("examples/noetix-e1", read_only=false, command_path~),
    "POST",
    "/emergency/stop",
    @bridge_protocol.request_json(request),
    now_ms=22L,
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"operation\": \"EmergencyStop\""))
  assert_true(response.body.contains("\"status\": \"Accepted\""))
  assert_true(response.body.contains("\"status\": \"Executed\""))
  assert_true(response.body.contains("control.emergency.stop"))
  assert_true(response.body.contains(command_path))
  assert_true(
    response.body.contains(
      "\"frame_id\": \"sdk-e1-command-feedback-intent-request-sidecar-emergency-emergency-stop-22\"",
    ),
  )
  assert_true(
    response.body.contains("\"command_capability\": \"control.emergency.stop\""),
  )
  let command_json = @fsx.read_file_to_string(command_path) catch {
    _ => fail("failed to read SDK E1 emergency command file")
  }
  assert_true(command_json.contains("\"action\": \"DEFAULT\""))
  assert_true(command_json.contains("\"action_code\": 12"))
  assert_true(command_json.contains("\"vertical\": 0"))
  assert_true(command_json.contains("\"horizontal\": 0"))
}

///|
test "sdk e1 bridge rejects emergency stop while read only" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let request = @bridge_protocol.emergency_stop_request(
    "request-sidecar-emergency-read-only", profile, 22L,
  )
  let response = @sdk_e1_bridge.route(
    gateway_config(),
    "POST",
    "/emergency/stop",
    @bridge_protocol.request_json(request),
    now_ms=22L,
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"status\": \"Rejected\""))
  assert_true(response.body.contains("read-only"))
}
