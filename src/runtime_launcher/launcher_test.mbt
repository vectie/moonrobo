///|
fn launcher_plan(root : String) -> @supervisor.SupervisorPlan {
  let profile = @core.noetix_e1_profile("launch-test-robot", "Launch Test")
  @supervisor.plan(
    @bridge_sidecar.runtime_spec_for_profile(
      profile,
      root,
      host="127.0.0.2",
      port=5999,
      snapshot_path="/tmp/moonrobo-launch-test.json",
    ),
  )
}

///|
test "runtime launcher persists supervisor script and receipt" {
  let root = "/tmp/moonrobo-runtime-launcher-test"
  let plan = launcher_plan(root)
  let result = @runtime_launcher.prepare_launch(
    root,
    plan,
    launch_id="launch-test",
  ).unwrap()
  assert_true(result.persisted)
  assert_eq(result.command.length(), 2)
  assert_eq(result.command[0], "sh")
  assert_eq(
    result.command[1],
    root + "/.moonsuite/products/moonrobo/runtime-supervisor/launch-test.sh",
  )
  assert_eq(
    result.receipt.log_path,
    root + "/.moonsuite/products/moonrobo/runtime-supervisor/launch-test.log",
  )
  let script = @fsx.read_file_to_string(result.script_path) catch {
    _ => fail("failed to read launch script")
  }
  assert_true(
    script.contains(
      "exec >> '\{root}/.moonsuite/products/moonrobo/runtime-supervisor/launch-test.log' 2>&1",
    ),
  )
  assert_true(script.contains("probe_health 'http://127.0.0.2:5999/health'"))
  let receipt = @fsx.read_file_to_string(result.receipt_path) catch {
    _ => fail("failed to read launch receipt")
  }
  assert_true(receipt.contains("\"status\": \"prepared\""))
  assert_true(
    receipt.contains("\"bridge_base_url\": \"http://127.0.0.2:5999\""),
  )
  assert_true(
    receipt.contains(
      "\"log_path\": \"\{root}/.moonsuite/products/moonrobo/runtime-supervisor/launch-test.log\"",
    ),
  )
  assert_true(receipt.contains("\"command\": ["))
}
