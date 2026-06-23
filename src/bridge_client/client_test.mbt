///|
fn sample_telemetry_body() -> String {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let request = @bridge_protocol.bridge_request(
    "request-client-telemetry",
    profile,
    LatestTelemetry,
    101L,
  )
  let response = @bridge_protocol.telemetry_response(
    request,
    @core.empty_telemetry_frame(
      "client-frame-1",
      profile.id,
      profile.bridge.id,
      101L,
    ),
  )
  @bridge_protocol.response_json(response)
}

///|
test "bridge client parses telemetry frame response" {
  let frame = @bridge_client.telemetry_frame_from_body(sample_telemetry_body()).unwrap()
  assert_eq(frame.frame_id, "client-frame-1")
  assert_eq(frame.robot_id, "noetix-e1-lab-01")
  assert_eq(frame.bridge_id, "sdk-e1")
}

///|
test "bridge client reports missing telemetry frame" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let request = @bridge_protocol.bridge_request(
    "request-client-health",
    profile,
    Health,
    102L,
  )
  let response = @bridge_protocol.session_response(request, "ok")
  let error = @bridge_client.telemetry_frame_from_body(
    @bridge_protocol.response_json(response),
  ).unwrap_err()
  assert_eq(error.code, "bridge-telemetry-missing")
}

///|
test "bridge client stamps sidecar samples with unique evidence ids" {
  let frame = @bridge_client.telemetry_frame_from_body(sample_telemetry_body()).unwrap()
  let sample = @bridge_client.sampled_telemetry_frame(frame, "task-1", 2)
  assert_eq(sample.frame_id, "sidecar-task-1-2-client-frame-1")
  assert_eq(sample.operator_input.get("source").unwrap(), "sidecar-http")
  assert_eq(
    sample.operator_input.get("source_frame_id").unwrap(),
    "client-frame-1",
  )
}
