///|
test "desktop bundle validates launchable local inputs" {
  let config = @desktop_host.config(
    "examples/noetix-e1",
    ui_root="ui/rabbita-cockpit",
    host="127.0.0.1",
    port=5541,
    sidecar_path="cmd/main/main.mbt",
  )
  let checks = @desktop_bundle.validate(config)
  assert_eq(checks.length(), 3)
  assert_true(@desktop_bundle.checks_ready(checks))
  assert_eq(
    @desktop_bundle.sidecar_command(config).join(" "),
    "cmd/main/main.mbt serve examples/noetix-e1 ui/rabbita-cockpit 127.0.0.1 5541",
  )
}

///|
test "desktop bundle manifest carries lepus and host contracts" {
  let config = @desktop_host.config(
    "examples/noetix-e1",
    ui_root="ui/rabbita-cockpit",
    host="127.0.0.1",
    port=5542,
    sidecar_path="cmd/main/main.mbt",
  )
  let text = @desktop_bundle.bundle_manifest_json(
    config, "/tmp/moonrobo-desktop-bundle-test",
  ).stringify(indent=2)
  assert_true(text.contains("\"kind\": \"moonrobo-desktop-bundle\""))
  assert_true(text.contains("\"ready\": true"))
  assert_true(text.contains("lepus.project.json"))
  assert_true(text.contains("moonrobo.desktop-host.json"))
  assert_true(text.contains("\"readinessPath\": \"/__moonrobo_health\""))
  assert_true(text.contains("\"/api/cockpit/snapshot\""))
}

///|
test "desktop bundle writes descriptor files" {
  let root = "/tmp/moonrobo-desktop-bundle-write-test"
  let config = @desktop_host.config(
    "examples/noetix-e1",
    ui_root="ui/rabbita-cockpit",
    host="127.0.0.1",
    port=5543,
    sidecar_path="cmd/main/main.mbt",
  )
  let files = @desktop_bundle.write_bundle_files(config, root).unwrap()
  assert_eq(files.length(), 3)
  assert_true(files.contains(@desktop_bundle.lepus_project_path(root)))
  assert_true(files.contains(@desktop_bundle.host_manifest_path(root)))
  assert_true(files.contains(@desktop_bundle.bundle_manifest_path(root)))
  let manifest = @fsx.read_file_to_string(
    @desktop_bundle.bundle_manifest_path(root),
  ) catch {
    _ => fail("failed to read bundle manifest")
  }
  assert_true(manifest.contains("\"ready\": true"))
}
