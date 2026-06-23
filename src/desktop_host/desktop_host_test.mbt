///|
test "desktop host defaults describe localhost cockpit service" {
  let config = @desktop_host.default_config("examples/noetix-e1")
  assert_eq(config.host, "127.0.0.1")
  assert_eq(config.port, 5290)
  assert_eq(config.ui_root, "ui/rabbita-cockpit")
  assert_eq(@desktop_host.readiness_path(), "/__moonrobo_health")
  assert_eq(@desktop_host.base_url(config), "http://127.0.0.1:5290")
}

///|
test "desktop host manifest advertises lepus localhost source" {
  let config = @desktop_host.config(
    "examples/noetix-e1",
    ui_root="dist/ui",
    host="127.0.0.1",
    port=5401,
    sidecar_path="/tmp/moonrobo-sidecar",
    bridge_host="127.0.0.2",
    bridge_port=5999,
  )
  let text = @desktop_host.lepus_project_json(config).stringify(indent=2)
  assert_true(text.contains("\"productName\": \"Moonrobo\""))
  assert_true(text.contains("\"assetProtocol\": \"lepus\""))
  assert_true(text.contains("\"readinessPath\": \"/__moonrobo_health\""))
  assert_true(text.contains("\"/api/cockpit/snapshot\"") == false)
  assert_true(text.contains("\"/tmp/moonrobo-sidecar\""))
  assert_true(text.contains("\"serve\""))
  assert_true(text.contains("\"127.0.0.2\""))
  assert_true(text.contains("\"5999\""))
}

///|
test "desktop host service manifest lists runtime api routes" {
  let text = @desktop_host.service_manifest_json(
    @desktop_host.default_config("examples/noetix-e1"),
  ).stringify(indent=2)
  assert_true(text.contains("\"kind\": \"moonrobo-desktop-host\""))
  assert_true(text.contains("\"/api/health\""))
  assert_true(text.contains("\"/api/cockpit/snapshot\""))
  assert_true(text.contains("\"read_only\": true"))
}

///|
test "desktop host static path resolver rejects traversal" {
  assert_true(
    @desktop_host.resolve_static_request_path("ui/dist", "/")
    is Some("ui/dist/index.html"),
  )
  assert_true(
    @desktop_host.resolve_static_request_path("ui/dist/", "/assets/app.js?x=1")
    is Some("ui/dist/assets/app.js"),
  )
  assert_true(
    @desktop_host.resolve_static_request_path("ui/dist", "/../robot.json")
    is None,
  )
  assert_eq(@desktop_host.content_type("main.css"), "text/css; charset=utf-8")
}

///|
test "desktop host describes browser burst routes" {
  let port = 5531
  let config = @desktop_host.config(
    "examples/noetix-e1",
    ui_root="ui/rabbita-cockpit",
    host="127.0.0.1",
    port~,
  )
  let routes = @desktop_host.route_catalog()
  assert_true(routes.any(route => route.path == "/__moonrobo_health"))
  assert_true(routes.any(route => route.path == "/api/moonrobo/readiness"))
  assert_true(routes.any(route => route.path == "/api/moonrobo/bootstrap"))
  assert_true(routes.any(route => route.path == "/api/moonrobo/advance"))
  assert_true(routes.any(route => route.path == "/api/moonrobo/runtime-proof"))
  assert_true(routes.any(route => route.path == "/api/health"))
  assert_true(routes.any(route => route.path == "/api/cockpit/snapshot"))
  assert_true(routes.any(route => route.path == "/api/bridge/sidecar"))
  assert_true(routes.any(route => route.path == "/api/runtime/supervisor"))
  assert_true(
    routes.any(route => route.path == "/api/runtime/supervisor/script"),
  )
  assert_true(
    routes.any(route => route.path == "/api/runtime/supervisor/launch"),
  )
  assert_true(routes.any(route => route.path == "/api/runtime/supervisor/run"))
  assert_true(routes.any(route => route.path == "/api/runtime/health"))
  assert_true(routes.any(route => route.path == "/api/runtime/validation"))
  assert_true(
    routes.any(route => route.path == "/api/runtime/supervisor/start"),
  )
  assert_true(routes.any(route => route.path == "/api/runtime/supervisor/stop"))
  assert_true(routes.any(route => route.path == "/api/runtime/emergency-stop"))
  assert_true(routes.any(route => route.path == "/api/moontown/resident"))
  assert_true(
    routes.any(route => route.path == "/api/datasets/episodes/{session_id}"),
  )
  assert_true(
    routes.any(route => {
      route.path == "/api/datasets/episodes/{session_id}/quality"
    }),
  )
  assert_true(routes.any(route => route.path == "/api/moonstat/status"))
  assert_true(routes.any(route => route.path == "/api/moonbook/memory"))
  assert_true(routes.any(route => route.path == "/api/moonbook/remember"))
  assert_true(routes.any(route => route.path == "/api/moonbook/task-messages"))
  assert_true(routes.any(route => route.path == "/api/moonbook/conversation"))
  assert_true(
    routes.any(route => {
      route.path == "/api/moonbook/task-messages/{task_id}/status"
    }),
  )
  assert_true(
    routes.any(route => {
      route.path == "/api/moonbook/task-messages/{task_id}/execute-sidecar"
    }),
  )
  assert_true(routes.any(route => route.path == "/api/agent/work-queue"))
  assert_true(routes.any(route => route.path == "/api/agent/next-action"))
  assert_true(
    routes.any(route => route.path == "/api/agent/runtime-calibration/latest"),
  )
  assert_true(routes.any(route => route.path == "/api/agent/dispatch-next"))
  assert_true(routes.any(route => route.path == "/api/tools/registry"))
  assert_true(routes.any(route => route.path == "/api/tools/register"))
  assert_true(routes.any(route => route.path == "/api/intents/evaluate"))
  assert_true(routes.any(route => route.path == "/api/intents/dry-run"))
  assert_true(routes.any(route => route.path == "/api/intents/approve"))
  assert_true(routes.any(route => route.path == "/api/intents/execute"))
  assert_true(routes.any(route => route.path == "/api/sessions/observe"))
  assert_true(routes.any(route => route.path == "/api/sessions/{id}/stop"))
  assert_true(routes.any(route => route.path == "/api/moontown/tasks/observe"))
  let project = @desktop_host.lepus_project_json(config).stringify(indent=2)
  assert_true(project.contains("\"path\": \"/\""))
  assert_true(project.contains("\"readinessPath\": \"/__moonrobo_health\""))
  assert_true(project.contains("\"serve\""))
  let manifest = @desktop_host.service_manifest_json(config).stringify(indent=2)
  assert_true(
    manifest.contains(
      "\"bridge_sidecar_manifest_path\": \"/api/bridge/sidecar\"",
    ),
  )
  assert_true(
    manifest.contains(
      "\"physical_runtime_manifest_path\": \"/api/bridge/sidecar\"",
    ),
  )
  assert_true(
    manifest.contains("\"bridge_base_url\": \"http://127.0.0.1:5391\""),
  )
}
