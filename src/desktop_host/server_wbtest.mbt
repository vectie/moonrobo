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
