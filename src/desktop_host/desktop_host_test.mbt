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
  )
  let text = @desktop_host.lepus_project_json(config).stringify(indent=2)
  assert_true(text.contains("\"productName\": \"Moonrobo\""))
  assert_true(text.contains("\"assetProtocol\": \"lepus\""))
  assert_true(text.contains("\"readinessPath\": \"/__moonrobo_health\""))
  assert_true(text.contains("\"/api/cockpit/snapshot\"") == false)
  assert_true(text.contains("\"/tmp/moonrobo-sidecar\""))
  assert_true(text.contains("\"serve\""))
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
fn test_ascii(text : String) -> Bytes {
  Bytes::makei(text.length(), index => text.unsafe_get(index).to_int().to_byte())
}

///|
async fn fetch_contains(
  path : String,
  port : Int,
  expected : String,
  markers : Array[String],
) -> Unit {
  let (response, body) = @http.get(test_ascii("http://127.0.0.1\{path}"), port~)
  assert_eq(response.code, 200)
  assert_true(@utf8.decode_lossy(body).contains(expected))
  markers.push(expected)
}

///|
test "desktop host serves browser burst" {
  let port = 5531
  let server = @desktop_host.Server::new("127.0.0.1", port) catch {
    error => fail("desktop host test bind failed: \{error}")
  }
  let config = @desktop_host.config(
    "examples/noetix-e1",
    ui_root="ui/rabbita-cockpit",
    host="127.0.0.1",
    port~,
  )
  let markers : Array[String] = []
  @async.with_event_loop(root => {
    root.spawn_bg(no_wait=true, allow_failure=true, async fn() {
      server.serve(root, config)
    })
    @async.sleep(50)
    @async.with_task_group(group => {
      group.spawn_bg(async fn() {
        fetch_contains("/", port, "<!doctype html>", markers)
      })
      group.spawn_bg(async fn() {
        fetch_contains(
          "/__moonrobo_health", port, "\"service\": \"moonrobo\"", markers,
        )
      })
      group.spawn_bg(async fn() {
        fetch_contains(
          "/api/health", port, "\"snapshot_path\": \"/api/cockpit/snapshot\"", markers,
        )
      })
      group.spawn_bg(async fn() {
        fetch_contains(
          "/api/cockpit/snapshot", port, "\"robot_id\": \"noetix-e1-lab-01\"", markers,
        )
      })
    })
    server.close()
    @async.sleep(20)
  })
  assert_eq(markers.length(), 4)
}
