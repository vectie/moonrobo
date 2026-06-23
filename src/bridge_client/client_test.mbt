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
fn sample_execute_request() -> @bridge_protocol.BridgeRequest {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let intent = @core.command_intent(
    "intent-client-execute",
    profile.id,
    "control.high.walk",
    @core.operator_requester("client-test"),
  )
  @bridge_protocol.execute_request(
    "request-client-execute", profile, intent, 201L,
  )
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

///|
test "bridge client parses execute response envelopes" {
  let request = sample_execute_request()
  let response = @bridge_protocol.rejected_response(
    request, "read-only sidecar",
  )
  let parsed = @bridge_client.execute_response_from_body(
    @bridge_protocol.response_json(response),
  ).unwrap()
  assert_true(parsed.status == Rejected)
  assert_true(parsed.operation == ExecuteIntent)
  assert_eq(parsed.message, "read-only sidecar")
}

///|
test "bridge client rejects non-execute response for execute parser" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let request = @bridge_protocol.telemetry_request(
    "request-client-wrong-op", profile, 202L,
  )
  let response = @bridge_protocol.session_response(request, "not execute")
  let error = @bridge_client.execute_response_from_body(
    @bridge_protocol.response_json(response),
  ).unwrap_err()
  assert_eq(error.code, "bridge-execute-operation-mismatch")
}

///|
test "bridge client refuses non-post bridge requests" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let request = @bridge_protocol.telemetry_request(
    "request-client-get", profile, 203L,
  )
  let error = @bridge_client.post_bridge_request(
    @bridge_client.config(),
    request,
  ).unwrap_err()
  assert_eq(error.code, "bridge-post-route-mismatch")
}
