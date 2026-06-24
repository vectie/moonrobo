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
fn desktop_runtime_validation_response_sync(
  cfg : DesktopHostConfig,
) -> @host_api.HostApiResponse raise {
  let responses : Array[@host_api.HostApiResponse] = []
  @async.with_event_loop(async fn(_group) {
    responses.push(desktop_runtime_validation_response(cfg))
  }) catch {
    error => fail("desktop runtime validation response failed: \{error}")
  }
  if responses.is_empty() {
    fail("desktop runtime validation response returned no result")
  } else {
    responses[0]
  }
}

///|
fn desktop_runtime_validation_session_response_sync(
  cfg : DesktopHostConfig,
  body : String,
) -> @host_api.HostApiResponse raise {
  let responses : Array[@host_api.HostApiResponse] = []
  @async.with_event_loop(async fn(_group) {
    responses.push(desktop_runtime_validation_session_response(cfg, body))
  }) catch {
    error =>
      fail("desktop runtime validation session response failed: \{error}")
  }
  if responses.is_empty() {
    fail("desktop runtime validation session response returned no result")
  } else {
    responses[0]
  }
}

///|
fn desktop_platform_runtime_proof_response_sync(
  cfg : DesktopHostConfig,
) -> @host_api.HostApiResponse raise {
  let responses : Array[@host_api.HostApiResponse] = []
  @async.with_event_loop(async fn(_group) {
    responses.push(desktop_platform_runtime_proof_response(cfg))
  }) catch {
    error => fail("desktop platform runtime proof response failed: \{error}")
  }
  if responses.is_empty() {
    fail("desktop platform runtime proof response returned no result")
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
fn desktop_runtime_emergency_stop_response_sync(
  cfg : DesktopHostConfig,
  body? : String = "",
) -> @host_api.HostApiResponse raise {
  let responses : Array[@host_api.HostApiResponse] = []
  @async.with_event_loop(async fn(_group) {
    responses.push(desktop_runtime_emergency_stop_response(cfg, body))
  }) catch {
    error => fail("desktop emergency stop response failed: \{error}")
  }
  if responses.is_empty() {
    fail("desktop emergency stop response returned no result")
  } else {
    responses[0]
  }
}

///|
fn desktop_agent_dispatch_next_response_sync(
  cfg : DesktopHostConfig,
  body? : String = "",
) -> @host_api.HostApiResponse raise {
  let responses : Array[@host_api.HostApiResponse] = []
  @async.with_event_loop(async fn(_group) {
    responses.push(desktop_agent_dispatch_next_response(cfg, body))
  }) catch {
    error => fail("desktop agent dispatch response failed: \{error}")
  }
  if responses.is_empty() {
    fail("desktop agent dispatch response returned no result")
  } else {
    responses[0]
  }
}

///|
fn desktop_runtime_execution_preflight_sync(
  cfg : DesktopHostConfig,
) -> @host_api.HostApiResponse? raise {
  let responses : Array[@host_api.HostApiResponse?] = []
  @async.with_event_loop(async fn(_group) {
    responses.push(desktop_runtime_execution_preflight(cfg))
  }) catch {
    error => fail("desktop runtime execution preflight failed: \{error}")
  }
  if responses.is_empty() {
    fail("desktop runtime execution preflight returned no result")
  } else {
    responses[0]
  }
}

///|
fn desktop_runtime_health_snapshot_for_test(
  status : String,
  robot_id? : String = "noetix-e1-lab-01",
  bridge_id? : String = "sdk-e1",
) -> @runtime_process.RuntimeHealthSnapshot {
  {
    active: true,
    status,
    running: true,
    pid: 9001,
    launch_id: "launch-test",
    runtime_id: "noetix-e1-lab-01:sdk-e1",
    bridge_base_url: "http://127.0.0.1:4390",
    telemetry_ok: status == "healthy",
    telemetry_status: if status == "healthy" {
      "telemetry-ok"
    } else {
      "bridge-connect-failed"
    },
    telemetry_message: "test telemetry",
    telemetry_path: "/telemetry/latest",
    telemetry_frame_id: "frame-test",
    telemetry_captured_at_ms: 9000L,
    robot_id,
    bridge_id,
    run: None,
  }
}

///|
test "desktop emergency stop event uses submitted override or fallback timestamp" {
  let fallback = desktop_emergency_stop_event("", 8100L).unwrap()
  assert_eq(fallback.now_ms, 8100L)
  assert_eq(fallback.request_id, "request-emergency-stop-8100")
  let submitted = desktop_emergency_stop_event(
    "{\"request_id\":\"request-emergency-stop-manual\",\"now_ms\":\"8200\"}", 8100L,
  ).unwrap()
  assert_eq(submitted.now_ms, 8200L)
  assert_eq(submitted.request_id, "request-emergency-stop-manual")
  let invalid = desktop_emergency_stop_event("{", 8100L)
  assert_true(invalid is Err(_))
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
test "desktop runtime start route persists runtime health evidence" {
  let root = "/tmp/moonrobo-desktop-runtime-start-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create desktop start test root")
    }
  }
  let profile = @fsx.read_file_to_string("examples/noetix-e1/robot.json") catch {
    _ => fail("failed to read example profile")
  }
  @fsx.write_string_to_file(root + "/robot.json", profile) catch {
    _ => fail("failed to write start test profile")
  }
  ignore(@runtime_process.stop_active_run(root))
  let cfg = config(root, bridge_host="127.0.0.2", bridge_port=5999)
  let response = desktop_runtime_supervisor_start_response(cfg)
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"runtime_health_path\""))
  assert_true(response.body.contains("\"latest_runtime_health_path\""))
  assert_true(response.body.contains("\"status\": \"running-unprobed\""))
  assert_true(@fsx.path_exists(root + "/runs/runtime-health/latest.json"))
  let latest = @runtime.read_latest_runtime_health(root).unwrap().unwrap()
  assert_eq(latest.bridge_base_url, "http://127.0.0.2:5999")
  ignore(@runtime_process.stop_active_run(root))
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
  assert_true(health.body.contains("\"persisted\": true"))
  assert_true(health.body.contains("\"runtime_health_path\""))
  assert_true(health.body.contains("\"active\": false"))
  assert_true(health.body.contains("\"status\": \"not-running\""))
  assert_true(
    @fsx.path_exists(
      "/tmp/moonrobo-desktop-runtime-no-active-test/runs/runtime-health/latest.json",
    ),
  )
  let stop = desktop_runtime_supervisor_stop_response(cfg)
  assert_eq(stop.status, 200)
  assert_true(stop.body.contains("\"stopped\": false"))
  assert_true(stop.body.contains("\"status\": \"not-running\""))
  let log = desktop_runtime_log_response(cfg)
  assert_eq(log.status, 200)
  assert_true(log.body.contains("\"active\": false"))
  assert_true(log.body.contains("\"exists\": false"))
  assert_true(log.body.contains("\"tail\": \"\""))
}

///|
test "desktop agent dispatch keeps latest telemetry when no runtime is active" {
  let root = "/tmp/moonrobo-desktop-agent-dispatch-no-active-runtime-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create desktop dispatch test root")
    }
  }
  let profile = @fsx.read_file_to_string("examples/noetix-e1/robot.json") catch {
    _ => fail("failed to read example profile")
  }
  @fsx.write_string_to_file(root + "/robot.json", profile) catch {
    _ => fail("failed to write desktop dispatch test profile")
  }
  let telemetry_path = @runtime.write_telemetry_frame(
    root,
    "agent-dispatch-test",
    @core.empty_telemetry_frame(
      "frame-before-dispatch", "noetix-e1-lab-01", "sdk-e1", 9001L,
    ),
  ).unwrap()
  ignore(
    @runtime.write_runtime_health(
      root,
      @runtime_health.record(
        9001L, "healthy", true, true, 42, "launch-before-dispatch", "runtime-before-dispatch",
        "noetix-e1-lab-01", "sdk-e1", "http://127.0.0.1:5391", true, "ok", "telemetry healthy",
        telemetry_path, "frame-before-dispatch", 9001L,
      ),
    ).unwrap(),
  )
  let response = desktop_agent_dispatch_next_response_sync(config(root))
  assert_eq(response.status, 409)
  let latest = @runtime.read_latest_runtime_health(root).unwrap().unwrap()
  assert_eq(latest.telemetry_frame_id, "frame-before-dispatch")
  assert_eq(latest.status, "healthy")
}

///|
test "desktop runtime proof requires active live supervisor before generic fallback" {
  let cfg = config("/tmp/moonrobo-desktop-runtime-proof-no-active-test")
  let response = desktop_platform_runtime_proof_response_sync(cfg)
  assert_eq(response.status, 409)
  assert_true(response.body.contains("\"code\": \"runtime-not-running\""))
  assert_true(!response.body.contains("runtime-proof-no-runtime-health"))
}

///|
test "desktop runtime validation route persists blocked readiness report" {
  let root = "/tmp/moonrobo-desktop-runtime-validation-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create desktop runtime validation test root")
    }
  }
  let profile = @fsx.read_file_to_string("examples/noetix-e1/robot.json") catch {
    _ => fail("failed to read example profile")
  }
  @fsx.write_string_to_file(root + "/robot.json", profile) catch {
    _ => fail("failed to write runtime validation test profile")
  }
  let response = desktop_runtime_validation_response_sync(config(root))
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"status\": \"blocked\""))
  assert_true(response.body.contains("\"ready_for_live_sdk\": false"))
  assert_true(response.body.contains("\"runtime-active\""))
  assert_true(@fsx.path_exists(root + "/runs/runtime-validation/latest.json"))
  assert_true(response.body.contains("\"calibration_path\""))
  assert_true(@fsx.path_exists(root + "/runs/runtime-calibration/latest.json"))
  let calibration_text = @fsx.read_file_to_string(
    root + "/runs/runtime-calibration/latest.json",
  ) catch {
    _ => fail("failed to read latest runtime calibration plan")
  }
  assert_true(calibration_text.contains("\"status\": \"needs-calibration\""))
  assert_true(calibration_text.contains("\"runtime-active\""))
}

///|
test "desktop runtime validation session persists repeated samples" {
  let root = "/tmp/moonrobo-desktop-runtime-validation-session-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create desktop runtime validation session test root")
    }
  }
  let profile = @fsx.read_file_to_string("examples/noetix-e1/robot.json") catch {
    _ => fail("failed to read example profile")
  }
  @fsx.write_string_to_file(root + "/robot.json", profile) catch {
    _ => fail("failed to write runtime validation session test profile")
  }
  let response = desktop_runtime_validation_session_response_sync(
    config(root),
    "{\"sample_count\":\"2\"}",
  )
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"persisted\": true"))
  assert_true(response.body.contains("\"sample_count\": 2"))
  assert_true(response.body.contains("\"required_sample_count\": 2"))
  assert_true(response.body.contains("\"blocked_sample_count\": 2"))
  assert_true(response.body.contains("\"status\": \"blocked\""))
  assert_true(response.body.contains("\"runtime-active\""))
  assert_true(
    @fsx.path_exists(root + "/runs/runtime-validation/latest-session.json"),
  )
  assert_true(@fsx.path_exists(root + "/runs/runtime-calibration/latest.json"))
  let session_text = @fsx.read_file_to_string(
    root + "/runs/runtime-validation/latest-session.json",
  ) catch {
    _ => fail("failed to read latest runtime validation session")
  }
  assert_true(session_text.contains("\"sample_count\": 2"))
  assert_true(session_text.contains("\"report_ids\""))
}

///|
test "desktop runtime log route returns bounded active run tail" {
  let root = "/tmp/moonrobo-desktop-runtime-log-test"
  if !@fsx.path_exists(root) {
    @fsx.create_dir(root) catch {
      _ => fail("failed to create desktop runtime log test root")
    }
  }
  @runtime.ensure_process_dirs(root).unwrap()
  let runtime_dir = root + "/runs/runtime-supervisor"
  if !@fsx.path_exists(runtime_dir) {
    @fsx.create_dir(runtime_dir) catch {
      _ => fail("failed to create runtime supervisor fixture dir")
    }
  }
  let plan = @supervisor.plan(
    @bridge_sidecar.runtime_spec_for_profile(
      @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01"),
      root,
    ),
  )
  let log_path = root + "/runs/runtime-supervisor/desktop-runtime-log-test.log"
  let run : @runtime_process.RuntimeSupervisorRun = {
    launch_id: "desktop-runtime-log-test",
    runtime_id: plan.runtime_id,
    pid: 999999,
    running: true,
    status: "running",
    script_path: root + "/runs/runtime-supervisor/desktop-runtime-log-test.sh",
    receipt_path: root +
    "/runs/runtime-supervisor/desktop-runtime-log-test.json",
    log_path,
    bridge_base_url: plan.bridge_base_url,
    command: [
      "sh",
      root + "/runs/runtime-supervisor/desktop-runtime-log-test.sh",
    ],
    plan,
  }
  @fsx.write_string_to_file(
    @runtime_launcher.active_run_path(root),
    run.to_json().stringify(indent=2),
  ) catch {
    _ => fail("failed to write active runtime fixture")
  }
  let lines : Array[String] = []
  for index in 0..<100 {
    lines.push("runtime-log-line-\{index}")
  }
  @fsx.write_string_to_file(log_path, lines.join("\n")) catch {
    _ => fail("failed to write runtime log fixture")
  }
  let response = desktop_runtime_log_response(config(root))
  assert_eq(response.status, 200)
  assert_true(response.body.contains("\"active\": true"))
  assert_true(response.body.contains("\"exists\": true"))
  assert_true(response.body.contains("\"truncated\": true"))
  assert_true(response.body.contains("runtime-log-line-99"))
  assert_true(!response.body.contains("runtime-log-line-0"))
}

///|
test "desktop sidecar execution requires active runtime supervisor" {
  let cfg = config("/tmp/moonrobo-desktop-runtime-required-test")
  let response = desktop_runtime_execution_preflight_sync(cfg).unwrap()
  assert_eq(response.status, 409)
  assert_true(response.body.contains("\"code\": \"runtime-not-running\""))
}

///|
test "desktop sidecar execution requires healthy mapped runtime" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let healthy = desktop_runtime_health_issue_response(
    profile,
    desktop_runtime_health_snapshot_for_test("healthy"),
  )
  assert_true(healthy is None)
  let unhealthy = desktop_runtime_health_issue_response(
    profile,
    desktop_runtime_health_snapshot_for_test("bridge-unhealthy"),
  ).unwrap()
  assert_eq(unhealthy.status, 409)
  assert_true(unhealthy.body.contains("\"code\": \"runtime-not-healthy\""))
  let robot_mismatch = desktop_runtime_health_issue_response(
    profile,
    desktop_runtime_health_snapshot_for_test("healthy", robot_id="other-robot"),
  ).unwrap()
  assert_eq(robot_mismatch.status, 409)
  assert_true(
    robot_mismatch.body.contains("\"code\": \"runtime-robot-mismatch\""),
  )
  let bridge_mismatch = desktop_runtime_health_issue_response(
    profile,
    desktop_runtime_health_snapshot_for_test(
      "healthy",
      bridge_id="other-bridge",
    ),
  ).unwrap()
  assert_eq(bridge_mismatch.status, 409)
  assert_true(
    bridge_mismatch.body.contains("\"code\": \"runtime-bridge-mismatch\""),
  )
}

///|
test "desktop sidecar execution blocks failed runtime validation" {
  let plan = @supervisor.plan(
    @bridge_sidecar.runtime_spec_for_profile(
      @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01"),
      "/tmp/moonrobo-desktop-validation-block-test",
    ),
  )
  let report = @runtime_validation.validation_report(
    plan,
    9200L,
    health=Some(desktop_runtime_health_snapshot_for_test("healthy")),
    log_path="",
    log_exists=false,
  )
  let response = desktop_runtime_validation_block_response(
    report,
    "/tmp/moonrobo-desktop-validation-block-test/runs/runtime-validation/latest.json",
    calibration_path="/tmp/moonrobo-desktop-validation-block-test/runs/runtime-calibration/latest.json",
    latest_calibration_path="/tmp/moonrobo-desktop-validation-block-test/runs/runtime-calibration/latest.json",
  ).unwrap()
  assert_eq(response.status, 409)
  assert_true(
    response.body.contains("\"code\": \"runtime-validation-blocked\""),
  )
  assert_true(response.body.contains("\"ready_for_live_sdk\": false"))
  assert_true(response.body.contains("\"runtime-log-ready\""))
  assert_true(response.body.contains("\"calibration_path\""))
}

///|
test "desktop emergency stop requires active runtime supervisor" {
  let cfg = config("/tmp/moonrobo-desktop-emergency-runtime-required-test")
  let response = desktop_runtime_emergency_stop_response_sync(cfg)
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
