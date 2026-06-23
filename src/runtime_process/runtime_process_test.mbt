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

///|
test "runtime process projects health from supervisor and telemetry probe" {
  let missing = @runtime_process.runtime_health_snapshot(
    "/tmp/moonrobo-runtime-health-missing-test",
  ).unwrap()
  assert_eq(missing.status, "not-running")
  assert_true(!missing.active)
  let root = "/tmp/moonrobo-runtime-health-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create runtime health test root")
    }
  }
  @fsx.write_string_to_file(
    root + "/runtime-loop.sh",
    "trap 'exit 0' TERM\nwhile true; do sleep 1; done\n",
  ) catch {
    _ => fail("failed to write runtime health script")
  }
  let run = @runtime_process.start_launch(
    root,
    native_plan(root),
    launch_id="native-runtime-health-test",
  ).unwrap()
  let unprobed = @runtime_process.runtime_health_snapshot(root).unwrap()
  assert_eq(unprobed.status, "running-unprobed")
  assert_eq(unprobed.pid, run.pid)
  let frame = @core.empty_telemetry_frame(
    "frame-health-1", "native-runtime-test", "sdk-e1", 9000L,
  )
  let healthy = @runtime_process.runtime_health_snapshot(
    root,
    telemetry_probe=Some(@runtime_process.telemetry_probe_from_frame(frame)),
  ).unwrap()
  assert_eq(healthy.status, "healthy")
  assert_true(healthy.telemetry_ok)
  assert_eq(healthy.telemetry_frame_id, "frame-health-1")
  let unhealthy = @runtime_process.runtime_health_snapshot(
    root,
    telemetry_probe=Some(
      @runtime_process.telemetry_probe_from_error(
        "bridge-connect-failed", "http://127.0.0.1:5999", "failed to connect",
      ),
    ),
  ).unwrap()
  assert_eq(unhealthy.status, "bridge-unhealthy")
  assert_true(!unhealthy.telemetry_ok)
  let stopped = @runtime_process.stop_active_run(root).unwrap()
  assert_true(stopped.stopped)
}
