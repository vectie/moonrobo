///|

///|
fn ensure_dir(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => fail("failed to create test dir: \{path}")
    }
  }
}

///|
fn ensure_release_bins(root : String) -> Unit raise {
  ensure_dir(root)
  ensure_dir(@desktop_bundle.release_bin_dir(root))
  @fsx.write_string_to_file(
    @desktop_bundle.release_desktop_host_path(root),
    "#!/usr/bin/env sh\n",
  ) catch {
    _ => fail("failed to write desktop host test binary")
  }
  @fsx.write_string_to_file(
    @desktop_bundle.release_sdk_bridge_path(root),
    "#!/usr/bin/env sh\n",
  ) catch {
    _ => fail("failed to write sdk bridge test binary")
  }
}

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
    @desktop_bundle.desktop_host_command(config).join(" "),
    "cmd/main/main.mbt serve examples/noetix-e1 ui/rabbita-cockpit 127.0.0.1 5541",
  )
}

///|
test "desktop bundle manifest carries lepus and host contracts" {
  let root = "/tmp/moonrobo-desktop-bundle-test"
  ensure_release_bins(root)
  let config = @desktop_host.config(
    "examples/noetix-e1",
    ui_root="ui/rabbita-cockpit",
    host="127.0.0.1",
    port=5542,
    sidecar_path="cmd/main/main.mbt",
  )
  let text = @desktop_bundle.bundle_manifest_json(config, root).stringify(
    indent=2,
  )
  assert_true(text.contains("\"kind\": \"moonrobo-desktop-bundle\""))
  assert_true(text.contains("\"ready\": true"))
  assert_true(text.contains("lepus.project.json"))
  assert_true(text.contains("moonrobo.desktop-host.json"))
  assert_true(text.contains("moonrobo.release-build.sh"))
  assert_true(text.contains("moonrobo.desktop-launch.sh"))
  assert_true(text.contains("moonrobo.runtime-supervisor.sh"))
  assert_true(text.contains("moonrobo-desktop-host"))
  assert_true(text.contains("moonrobo-sdk-e1-bridge"))
  assert_true(text.contains("\"readinessPath\": \"/__moonrobo_health\""))
  assert_true(text.contains("\"/api/cockpit/snapshot\""))
  assert_true(text.contains("\"bridge_sidecar\""))
  assert_true(text.contains("\"runtime\""))
  assert_true(text.contains("\"runtime_supervisor\""))
  assert_true(text.contains("\"supervisor_runner\""))
  assert_true(text.contains("\"desktop_launch\""))
  assert_true(text.contains("\"launch_command\""))
  assert_true(text.contains("\"desktop_host_command\""))
  assert_true(text.contains("\"release_artifacts\""))
  assert_true(text.contains("\"command\": [\n      \"sh\""))
  assert_true(text.contains("\"role\": \"SnapshotCollector\""))
  assert_true(text.contains("\"role\": \"BridgeSidecar\""))
  assert_true(text.contains("\"action\": \"StartProcess\""))
  assert_true(text.contains("\"execute_path\": \"/intents/execute\""))
}

///|
test "desktop bundle writes descriptor files" {
  let root = "/tmp/moonrobo-desktop-bundle-write-test"
  ensure_release_bins(root)
  let config = @desktop_host.config(
    "examples/noetix-e1",
    ui_root="ui/rabbita-cockpit",
    host="127.0.0.1",
    port=5543,
    sidecar_path="cmd/main/main.mbt",
  )
  let files = @desktop_bundle.write_bundle_files(config, root).unwrap()
  assert_eq(files.length(), 6)
  assert_true(files.contains(@desktop_bundle.lepus_project_path(root)))
  assert_true(files.contains(@desktop_bundle.host_manifest_path(root)))
  assert_true(files.contains(@desktop_bundle.bundle_manifest_path(root)))
  assert_true(files.contains(@desktop_bundle.release_build_path(root)))
  assert_true(files.contains(@desktop_bundle.supervisor_runner_path(root)))
  assert_true(files.contains(@desktop_bundle.desktop_launch_path(root)))
  let manifest = @fsx.read_file_to_string(
    @desktop_bundle.bundle_manifest_path(root),
  ) catch {
    _ => fail("failed to read bundle manifest")
  }
  assert_true(manifest.contains("\"ready\": true"))
  assert_true(manifest.contains("\"sidecar_id\": \"noetix-e1-lab-01:sdk-e1\""))
  assert_true(manifest.contains("moonrobo.release-build.sh"))
  assert_true(manifest.contains("moonrobo.desktop-launch.sh"))
  assert_true(manifest.contains("moonrobo.runtime-supervisor.sh"))
  assert_true(manifest.contains("moonrobo-desktop-host"))
  assert_true(manifest.contains("moonrobo-sdk-e1-bridge"))
  assert_true(manifest.contains("\"command\""))
  assert_true(manifest.contains("\"sh\""))
  let build = @fsx.read_file_to_string(@desktop_bundle.release_build_path(root)) catch {
    _ => fail("failed to read release build script")
  }
  assert_true(build.contains("moon build cmd/main --target native"))
  assert_true(build.contains("moon build cmd/sdk_e1_bridge --target native"))
  assert_true(
    build.contains("cp '_build/native/debug/build/cmd/main/main.exe'"),
  )
  let script = @fsx.read_file_to_string(
    @desktop_bundle.supervisor_runner_path(root),
  ) catch {
    _ => fail("failed to read supervisor runner")
  }
  assert_true(script.contains("#!/usr/bin/env sh"))
  assert_true(script.contains("wait_for_file"))
  assert_true(script.contains("probe_health"))
  assert_true(script.contains("moonrobo-sdk-e1-bridge"))
  assert_true(script.contains("Moonrobo runtime supervisor"))
  let launch = @fsx.read_file_to_string(
    @desktop_bundle.desktop_launch_path(root),
  ) catch {
    _ => fail("failed to read desktop launch script")
  }
  assert_true(launch.contains("#!/usr/bin/env sh"))
  assert_true(launch.contains("moonrobo.runtime-supervisor.sh"))
  assert_true(launch.contains("moonrobo-desktop-host"))
  assert_true(launch.contains("wait \"$HOST_PID\""))
}
