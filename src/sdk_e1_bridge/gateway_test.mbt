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
