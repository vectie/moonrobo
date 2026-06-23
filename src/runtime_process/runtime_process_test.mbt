///|
fn native_plan(root : String) -> @supervisor.SupervisorPlan {
  let profile = @core.noetix_e1_profile(
    "native-runtime-test", "Native Runtime Test",
  )
  let process : @bridge_sidecar.RuntimeProcessSpec = {
    process_id: "native-runtime-test:script",
    role: SnapshotCollector,
    command: ["sh", root + "/runtime-loop.sh"],
    env: {},
    cwd: ".",
    output_path: "",
    health_path: "",
    depends_on: [],
    supervision: Manual,
  }
  @supervisor.plan({
    runtime_id: "native-runtime-test",
    robot_id: profile.id,
    bridge_id: profile.bridge.id,
    snapshot_path: "",
    bridge_base_url: "http://127.0.0.1:5999",
    processes: [process],
  })
}

///|
test "runtime process starts and stops active supervisor run" {
  let root = "/tmp/moonrobo-runtime-process-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create runtime process test root")
    }
  }
  @fsx.write_string_to_file(
    root + "/runtime-loop.sh",
    "trap 'exit 0' TERM\nwhile true; do sleep 1; done\n",
  ) catch {
    _ => fail("failed to write runtime process script")
  }
  let run = @runtime_process.start_launch(
    root,
    native_plan(root),
    launch_id="native-runtime-test",
  ).unwrap()
  assert_true(run.pid > 0)
  assert_true(run.running)
  assert_true(@fsx.path_exists(@runtime_launcher.active_run_path(root)))
  let active = @runtime_process.read_active_run(root).unwrap()
  assert_true(active is Some(_))
  let stopped = @runtime_process.stop_active_run(root).unwrap()
  assert_true(stopped.stopped)
}

///|
test "runtime process requires live supervisor before bridge execution" {
  let root = "/tmp/moonrobo-runtime-process-required-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create runtime process required test root")
    }
  }
  let missing = @runtime_process.require_active_run(
    root,
    expected_bridge_base_url="http://127.0.0.1:5999",
  ).unwrap_err()
  assert_eq(missing.http_status, 409)
  assert_eq(missing.code, "runtime-not-running")
  @fsx.write_string_to_file(
    root + "/runtime-loop.sh",
    "trap 'exit 0' TERM\nwhile true; do sleep 1; done\n",
  ) catch {
    _ => fail("failed to write runtime process script")
  }
  let run = @runtime_process.start_launch(
    root,
    native_plan(root),
    launch_id="native-runtime-required-test",
  ).unwrap()
  let mismatch = @runtime_process.require_active_run(
    root,
    expected_bridge_base_url="http://127.0.0.2:5999",
  ).unwrap_err()
  assert_eq(mismatch.http_status, 409)
  assert_eq(mismatch.code, "runtime-bridge-mismatch")
  let active = @runtime_process.require_active_run(
    root,
    expected_bridge_base_url=run.bridge_base_url,
  ).unwrap()
  assert_eq(active.pid, run.pid)
  let stopped = @runtime_process.stop_active_run(root).unwrap()
  assert_true(stopped.stopped)
}
