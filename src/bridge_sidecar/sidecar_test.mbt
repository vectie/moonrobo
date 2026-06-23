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
  assert_eq(spec.command[1], "serve")
  assert_eq(spec.command[2], "examples/noetix-e1")
  assert_eq(spec.command[3], "127.0.0.1")
  assert_eq(spec.command[4], "5391")
  assert_eq(spec.command[5], "/tmp/moonrobo-sdk-e1.json")
  assert_eq(spec.health_path, "/health")
  assert_eq(spec.telemetry_path, "/telemetry/latest")
  assert_eq(spec.execute_path, "/intents/execute")
  assert_eq(spec.protocol_version, @bridge_protocol.protocol_version())
}

///|
test "sdk e1 runtime spec supervises collector before bridge sidecar" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let runtime = @bridge_sidecar.runtime_spec_for_profile(
    profile,
    "examples/noetix-e1",
    sidecar_path="moonrobo-sdk-e1-bridge",
    collector_path="bridges/sdk_e1/sdk_e1_readonly_bridge.py",
    snapshot_path="/tmp/moonrobo-sdk-e1.json",
  )
  assert_eq(runtime.runtime_id, "noetix-e1-lab-01:sdk-e1")
  assert_eq(runtime.snapshot_path, "/tmp/moonrobo-sdk-e1.json")
  assert_eq(runtime.bridge_base_url, "http://127.0.0.1:5391")
  assert_eq(runtime.processes.length(), 2)
  let collector = runtime.processes[0]
  let bridge = runtime.processes[1]
  assert_true(collector.role == SnapshotCollector)
  assert_eq(collector.command[0], "python3")
  assert_eq(collector.command[1], "bridges/sdk_e1/sdk_e1_readonly_bridge.py")
  assert_true(collector.command.contains("--live"))
  assert_true(collector.command.contains("--output"))
  assert_true(collector.command.contains("/tmp/moonrobo-sdk-e1.json"))
  assert_eq(collector.output_path, "/tmp/moonrobo-sdk-e1.json")
  assert_eq(collector.depends_on.length(), 0)
  assert_true(bridge.role == BridgeSidecar)
  assert_eq(bridge.command[0], "moonrobo-sdk-e1-bridge")
  assert_eq(bridge.command[5], "/tmp/moonrobo-sdk-e1.json")
  assert_eq(bridge.depends_on.length(), 1)
  assert_eq(bridge.depends_on[0], "noetix-e1-lab-01:sdk-e1:collector")
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
