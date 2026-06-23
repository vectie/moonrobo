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
test "sdk e1 bridge rejects execution while read only" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let intent = @core.command_intent(
    "intent-sidecar-execute",
    profile.id,
    "control.high.walk",
    @core.operator_requester("sidecar-test"),
  )
  let request = @bridge_protocol.execute_request(
    "request-sidecar-execute", profile, intent, 12L,
  )
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
