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
  assert_eq(spec.command[5], ".tmp/products/moonrobo/sdk-e1/snapshot.json")
  assert_eq(spec.command[6], "control-gated")
  assert_eq(spec.command[7], ".tmp/products/moonrobo/sdk-e1/command.json")
  assert_eq(spec.contract_path, "/contract")
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
    writer_path="bridges/sdk_e1/sdk_e1_high_control_writer.py",
    snapshot_path=".tmp/products/moonrobo/sdk-e1/snapshot.json",
    command_path=".tmp/products/moonrobo/sdk-e1/command.json",
  )
  assert_eq(runtime.runtime_id, "noetix-e1-lab-01:sdk-e1")
  assert_eq(
    runtime.snapshot_path,
    ".tmp/products/moonrobo/sdk-e1/snapshot.json",
  )
  assert_eq(runtime.command_path, ".tmp/products/moonrobo/sdk-e1/command.json")
  assert_eq(runtime.bridge_base_url, "http://127.0.0.1:5391")
  assert_eq(runtime.processes.length(), 3)
  let collector = runtime.processes[0]
  let writer = runtime.processes[1]
  let bridge = runtime.processes[2]
  assert_true(collector.role == SnapshotCollector)
  assert_eq(collector.command[0], "python3")
  assert_eq(collector.command[1], "bridges/sdk_e1/sdk_e1_readonly_bridge.py")
  assert_true(collector.command.contains("--live"))
  assert_true(collector.command.contains("--output"))
  assert_true(
    collector.command.contains(".tmp/products/moonrobo/sdk-e1/snapshot.json"),
  )
  assert_eq(
    collector.output_path,
    ".tmp/products/moonrobo/sdk-e1/snapshot.json",
  )
  assert_eq(collector.depends_on.length(), 0)
  assert_true(writer.role == HighControlWriter)
  assert_eq(writer.command[0], "python3")
  assert_eq(writer.command[1], "bridges/sdk_e1/sdk_e1_high_control_writer.py")
  assert_true(writer.command.contains("--watch"))
  assert_true(writer.command.contains("--input"))
  assert_true(
    writer.command.contains(".tmp/products/moonrobo/sdk-e1/command.json"),
  )
  assert_eq(writer.output_path, ".tmp/products/moonrobo/sdk-e1/command.json")
  assert_eq(writer.depends_on.length(), 0)
  assert_true(bridge.role == BridgeSidecar)
  assert_eq(bridge.command[0], "moonrobo-sdk-e1-bridge")
  assert_eq(bridge.command[5], ".tmp/products/moonrobo/sdk-e1/snapshot.json")
  assert_eq(bridge.command[6], "control-gated")
  assert_eq(bridge.command[7], ".tmp/products/moonrobo/sdk-e1/command.json")
  assert_eq(bridge.depends_on.length(), 2)
  assert_eq(bridge.depends_on[0], "noetix-e1-lab-01:sdk-e1:collector")
  assert_eq(bridge.depends_on[1], "noetix-e1-lab-01:sdk-e1:writer")
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
  assert_eq(launchable.contract_path, "/contract")
  let missing = @bridge_sidecar.status_for_spec(spec, false)
  assert_true(missing.state == MissingCommand)
  assert_false(missing.ready_for_execution)
  assert_true(missing.detail.contains("moonrobo-sdk-e1-bridge"))
}
