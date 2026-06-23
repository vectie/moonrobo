///|
test "desktop api recognizes task-message sidecar execution paths" {
  assert_true(
    task_id_from_execute_sidecar_path(
      "/api/moonbook/task-messages/message-walk/execute-sidecar",
    )
    is Some("message-walk"),
  )
  assert_true(
    task_id_from_execute_sidecar_path(
      "/api/moonbook/task-messages/message-walk/execute",
    )
    is None,
  )
}

///|
test "desktop runtime routes use configured bridge endpoint" {
  let cfg = config(
    "examples/noetix-e1",
    bridge_host="127.0.0.2",
    bridge_port=5999,
  )
  let bridge = desktop_bridge_sidecar_response(cfg)
  assert_eq(bridge.status, 200)
  assert_true(
    bridge.body.contains("\"bridge_base_url\": \"http://127.0.0.2:5999\""),
  )
  assert_true(bridge.body.contains("\"127.0.0.2\""))
  assert_true(bridge.body.contains("\"5999\""))
  let supervisor = desktop_runtime_supervisor_response(cfg)
  assert_eq(supervisor.status, 200)
  assert_true(
    supervisor.body.contains("\"bridge_base_url\": \"http://127.0.0.2:5999\""),
  )
  let script = desktop_runtime_supervisor_script_response(cfg)
  assert_eq(script.status, 200)
  assert_eq(script.content_type, "text/plain")
  assert_true(script.body.contains("http://127.0.0.2:5999/health"))
}

///|
test "desktop runtime launch route writes configured supervisor receipt" {
  let root = "/tmp/moonrobo-desktop-runtime-launch-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create desktop launch test root")
    }
  }
  let profile = @fsx.read_file_to_string("examples/noetix-e1/robot.json") catch {
    _ => fail("failed to read example profile")
  }
  @fsx.write_string_to_file(root + "/robot.json", profile) catch {
    _ => fail("failed to write launch test profile")
  }
  let cfg = config(root, bridge_host="127.0.0.2", bridge_port=5999)
  let response = desktop_runtime_supervisor_launch_response(cfg)
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(
    response.body.contains("\"bridge_base_url\": \"http://127.0.0.2:5999\""),
  )
  assert_true(response.body.contains("\"command\": ["))
  assert_true(
    @fsx.path_exists(
      root +
      "/runs/runtime-supervisor/runtime-supervisor-noetix-e1-lab-01:sdk-e1.sh",
    ),
  )
}
