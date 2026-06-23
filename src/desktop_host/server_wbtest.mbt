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
fn desktop_runtime_health_response_sync(
  cfg : DesktopHostConfig,
) -> @host_api.HostApiResponse raise {
  let responses : Array[@host_api.HostApiResponse] = []
  @async.with_event_loop(async fn(_group) {
    responses.push(desktop_runtime_health_response(cfg))
  }) catch {
    error => fail("desktop runtime health response failed: \{error}")
  }
  if responses.is_empty() {
    fail("desktop runtime health response returned no result")
  } else {
    responses[0]
  }
}

///|
fn desktop_task_message_status_response_sync(
  cfg : DesktopHostConfig,
  path : String,
) -> @host_api.HostApiResponse raise {
  let responses : Array[@host_api.HostApiResponse] = []
  @async.with_event_loop(async fn(_group) {
    responses.push(desktop_task_message_status_response(cfg, path))
  }) catch {
    error => fail("desktop task status response failed: \{error}")
  }
  if responses.is_empty() {
    fail("desktop task status response returned no result")
  } else {
    responses[0]
  }
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

///|
test "desktop runtime process routes report no active supervisor" {
  let cfg = config("/tmp/moonrobo-desktop-runtime-no-active-test")
  let run = desktop_runtime_supervisor_run_response(cfg)
  assert_eq(run.status, 200)
  assert_true(run.body.contains("\"active\": false"))
  assert_true(run.body.contains("\"status\": \"not-running\""))
  let health = desktop_runtime_health_response_sync(cfg)
  assert_eq(health.status, 200)
  assert_true(health.body.contains("\"active\": false"))
  assert_true(health.body.contains("\"status\": \"not-running\""))
  let stop = desktop_runtime_supervisor_stop_response(cfg)
  assert_eq(stop.status, 200)
  assert_true(stop.body.contains("\"stopped\": false"))
  assert_true(stop.body.contains("\"status\": \"not-running\""))
}

///|
test "desktop sidecar execution requires active runtime supervisor" {
  let cfg = config("/tmp/moonrobo-desktop-runtime-required-test")
  let response = desktop_runtime_execution_preflight(cfg).unwrap()
  assert_eq(response.status, 409)
  assert_true(response.body.contains("\"code\": \"runtime-not-running\""))
}

///|
test "desktop task status reports runtime preflight requirement" {
  let root = "/tmp/moonrobo-desktop-task-status-runtime-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create desktop task status test root")
    }
  }
  let profile = @fsx.read_file_to_string("examples/noetix-e1/robot.json") catch {
    _ => fail("failed to read example profile")
  }
  @fsx.write_string_to_file(root + "/robot.json", profile) catch {
    _ => fail("failed to write task status test profile")
  }
  let request_body = "{\"message_id\":\"desktop-status\",\"robot_id\":\"\",\"requested_by\":{\"kind\":\"operator\",\"id\":\"desktop-test\"},\"message\":\"walk forward\",\"now_ms\":\"7100\"}"
  let submitted = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_task_message_path(),
    request_body,
  )
  assert_eq(submitted.status, 200)
  let task_id = "message-desktop-status"
  assert_eq(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_evaluate_path(task_id),
      "",
    ).status,
    200,
  )
  assert_eq(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_dry_run_path(task_id),
      "",
    ).status,
    200,
  )
  assert_eq(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonbook_task_message_approve_path(task_id),
      "",
    ).status,
    200,
  )
  let response = desktop_task_message_status_response_sync(
    config(root),
    @host_api.moonbook_task_message_status_path(task_id),
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"stage\": \"runtime-required\""))
  assert_true(response.body.contains("\"runtime_status\": \"not-running\""))
}
