///|
test "sdk e1 sidecar spec exposes bridge protocol routes" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let spec = @bridge_sidecar.spec_for_profile(
    profile,
    "examples/noetix-e1",
    sidecar_path="moonrobo-sdk-e1-bridge",
  )
  assert_eq(spec.sidecar_id, "noetix-e1-lab-01:sdk-e1")
  assert_eq(spec.command[0], "moonrobo-sdk-e1-bridge")
  assert_true(spec.command.contains("--robot-id"))
  assert_eq(spec.health_path, "/health")
  assert_eq(spec.telemetry_path, "/telemetry/latest")
  assert_eq(spec.execute_path, "/intents/execute")
  assert_eq(spec.protocol_version, @bridge_protocol.protocol_version())
}

///|
test "sidecar status reports launchable and missing commands" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let spec = @bridge_sidecar.spec_for_profile(
    profile,
    "examples/noetix-e1",
    sidecar_path="moonrobo-sdk-e1-bridge",
  )
  let launchable = @bridge_sidecar.status_for_spec(spec, true)
  assert_true(launchable.state == Launchable)
  assert_true(launchable.ready_for_execution)
  let missing = @bridge_sidecar.status_for_spec(spec, false)
  assert_true(missing.state == MissingCommand)
  assert_false(missing.ready_for_execution)
  assert_true(missing.detail.contains("moonrobo-sdk-e1-bridge"))
}
