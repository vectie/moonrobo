///|
pub(all) struct BundleCheck {
  code : String
  path : String
  ok : Bool
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BundleIssue {
  code : String
  path : String
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn ok(code : String, path : String, message : String) -> BundleCheck {
  { code, path, ok: true, message }
}

///|
fn fail(code : String, path : String, message : String) -> BundleCheck {
  { code, path, ok: false, message }
}

///|
fn issue(code : String, path : String, message : String) -> BundleIssue {
  { code, path, message }
}

///|
pub fn default_bundle_root() -> String {
  "_build/moonrobo-desktop"
}

///|
pub fn lepus_project_path(bundle_root : String) -> String {
  join_path(bundle_root, "lepus.project.json")
}

///|
pub fn host_manifest_path(bundle_root : String) -> String {
  join_path(bundle_root, "moonrobo.desktop-host.json")
}

///|
pub fn bundle_manifest_path(bundle_root : String) -> String {
  join_path(bundle_root, "moonrobo.desktop-bundle.json")
}

///|
pub fn release_build_path(bundle_root : String) -> String {
  join_path(bundle_root, "moonrobo.release-build.sh")
}

///|
pub fn release_ui_dir(bundle_root : String) -> String {
  join_path(bundle_root, "ui")
}

///|
pub fn release_ui_index_path(bundle_root : String) -> String {
  join_path(release_ui_dir(bundle_root), "index.html")
}

///|
pub fn desktop_launch_path(bundle_root : String) -> String {
  join_path(bundle_root, "moonrobo.desktop-launch.sh")
}

///|
pub fn supervisor_runner_path(bundle_root : String) -> String {
  join_path(bundle_root, "moonrobo.runtime-supervisor.sh")
}

///|
fn trim_trailing_slash(path : String) -> String {
  if path.length() > 1 && path.has_suffix("/") {
    path.trim(chars=['/']).to_owned()
  } else {
    path
  }
}

///|
fn join_path(root : String, leaf : String) -> String {
  trim_trailing_slash(root) + "/" + leaf
}

///|
pub fn release_bin_dir(bundle_root : String) -> String {
  join_path(bundle_root, "bin")
}

///|
pub fn release_desktop_host_path(bundle_root : String) -> String {
  join_path(release_bin_dir(bundle_root), "moonrobo-desktop-host")
}

///|
pub fn release_sdk_bridge_path(bundle_root : String) -> String {
  join_path(release_bin_dir(bundle_root), "moonrobo-sdk-e1-bridge")
}

///|
fn built_desktop_host_path() -> String {
  "_build/native/debug/build/cmd/main/main.exe"
}

///|
fn built_sdk_bridge_path() -> String {
  "_build/native/debug/build/cmd/sdk_e1_bridge/sdk_e1_bridge.exe"
}

///|
fn built_rabbita_dist_path() -> String {
  "ui/rabbita-cockpit/dist"
}

///|
fn rabbita_source_root() -> String {
  "ui/rabbita-cockpit"
}

///|
fn bundle_host_config(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> @desktop_host.DesktopHostConfig {
  if bundle_root == "" {
    config
  } else {
    @desktop_host.config(
      config.robobook_root,
      ui_root=release_ui_dir(bundle_root),
      host=config.host,
      port=config.port,
      sidecar_path=release_desktop_host_path(bundle_root),
    )
  }
}

///|
pub fn desktop_host_command(
  config : @desktop_host.DesktopHostConfig,
  bundle_root? : String = "",
) -> Array[String] {
  let host_config = bundle_host_config(config, bundle_root)
  [
    host_config.sidecar_path,
    "serve",
    host_config.robobook_root,
    host_config.ui_root,
    host_config.host,
    host_config.port.to_string(),
  ]
}

///|
pub fn launch_command(bundle_root : String) -> Array[String] {
  ["sh", desktop_launch_path(bundle_root)]
}

///|
fn robobook_check(root : String) -> BundleCheck {
  match @runtime.load_robobook(root) {
    Ok(book) =>
      if book.status.ready {
        ok("robobook-ready", root, "RoboBook is ready")
      } else {
        fail("robobook-not-ready", root, "RoboBook is missing required files")
      }
    Err(error) => fail(error.code, error.path, error.message)
  }
}

///|
fn ui_check(ui_root : String, bundle_root? : String = "") -> BundleCheck {
  let path = if bundle_root == "" {
    @desktop_host.fallback_index_path(ui_root)
  } else {
    release_ui_index_path(bundle_root)
  }
  if @fsx.path_exists(path) {
    ok("ui-index", path, "Rabbita packaged entrypoint exists")
  } else {
    fail("ui-index-missing", path, "Rabbita packaged entrypoint is missing")
  }
}

///|
fn sidecar_check(sidecar_path : String) -> BundleCheck {
  if @fsx.path_exists(sidecar_path) {
    ok("sidecar-path", sidecar_path, "desktop host command path exists")
  } else {
    fail(
      "sidecar-missing", sidecar_path, "desktop host command path is missing",
    )
  }
}

///|
pub fn validate(
  config : @desktop_host.DesktopHostConfig,
  bundle_root? : String = "",
) -> Array[BundleCheck] {
  [
    robobook_check(config.robobook_root),
    ui_check(config.ui_root, bundle_root~),
    sidecar_check(desktop_host_command(config, bundle_root~)[0]),
  ]
}

///|
pub fn checks_ready(checks : Array[BundleCheck]) -> Bool {
  for check in checks {
    if !check.ok {
      return false
    }
  }
  true
}

///|
fn checks_json(checks : Array[BundleCheck]) -> Array[Json] {
  [
    for check in checks => check.to_json()
  ]
}

///|
fn bridge_sidecar_json(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Json {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) => {
      let spec = @bridge_sidecar.spec_for_profile(
        book.profile,
        config.robobook_root,
        sidecar_path=release_sdk_bridge_path(bundle_root),
      )
      {
        "spec": spec.to_json(),
        "status": @bridge_sidecar.status_for_spec(
          spec,
          !spec.command.is_empty() && @fsx.path_exists(spec.command[0]),
        ).to_json(),
        "runtime": @bridge_sidecar.runtime_spec_for_profile(
          book.profile,
          config.robobook_root,
          sidecar_path=release_sdk_bridge_path(bundle_root),
        ).to_json(),
      }
    }
    Err(error) =>
      {
        "error": {
          "code": error.code,
          "path": error.path,
          "message": error.message,
        },
      }
  }
}

///|
fn runtime_supervisor_plan(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Result[@supervisor.SupervisorPlan, BundleIssue] {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) =>
      Ok(
        @supervisor.plan(
          @bridge_sidecar.runtime_spec_for_profile(
            book.profile,
            config.robobook_root,
            sidecar_path=release_sdk_bridge_path(bundle_root),
          ),
        ),
      )
    Err(error) => Err(issue(error.code, error.path, error.message))
  }
}

///|
fn runtime_supervisor_json(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Json {
  match runtime_supervisor_plan(config, bundle_root) {
    Ok(plan) => plan.to_json()
    Err(error) =>
      {
        "error": {
          "code": error.code,
          "path": error.path,
          "message": error.message,
        },
      }
  }
}

///|
fn supervisor_runner_json(bundle_root : String) -> Json {
  let path = supervisor_runner_path(bundle_root)
  {
    "path": path,
    "command": ["sh", path],
    "content_type": "text/x-shellscript",
  }
}

///|
fn desktop_launch_json(bundle_root : String) -> Json {
  let path = desktop_launch_path(bundle_root)
  {
    "path": path,
    "command": launch_command(bundle_root),
    "content_type": "text/x-shellscript",
  }
}

///|
fn release_artifacts_json(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Json {
  {
    "bin_dir": release_bin_dir(bundle_root),
    "build_commands": [
      ["moon", "build", "cmd/main", "--target", "native"],
      ["moon", "build", "cmd/sdk_e1_bridge", "--target", "native"],
      ["npm", "--prefix", rabbita_source_root(), "run", "build"],
    ],
    "artifacts": [
      {
        "name": "moonrobo-desktop-host",
        "source": built_desktop_host_path(),
        "path": release_desktop_host_path(bundle_root),
        "command": desktop_host_command(config, bundle_root~),
      },
      {
        "name": "moonrobo-sdk-e1-bridge",
        "source": built_sdk_bridge_path(),
        "path": release_sdk_bridge_path(bundle_root),
        "command": @bridge_sidecar.sdk_e1_command(
          config.robobook_root,
          sidecar_path=release_sdk_bridge_path(bundle_root),
        ),
      },
      {
        "name": "moonrobo-rabbita-cockpit",
        "source": built_rabbita_dist_path(),
        "path": release_ui_dir(bundle_root),
        "entrypoint": release_ui_index_path(bundle_root),
      },
    ],
  }
}

///|
fn lepus_project_json(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Json {
  {
    "identifier": "app.vectie.moonrobo",
    "productName": "Moonrobo",
    "version": "0.1.0",
    "runtime": {
      "backend": "system-webview",
      "assetProtocol": "lepus",
      "devtools": false,
    },
    "window": {
      "label": "main",
      "title": "Moonrobo",
      "width": 1280,
      "height": 820,
      "resizable": true,
      "source": {
        "localhost": {
          "host": config.host,
          "port": config.port,
          "path": "/",
          "readinessPath": @desktop_host.readiness_path(),
          "command": launch_command(bundle_root),
        },
      },
    },
    "plugins": [{ "name": "localhost" }, { "name": "serviceDiscovery" }],
    "capabilities": [
      {
        "name": "main",
        "windows": ["main"],
        "permissions": ["localhost", "service-discovery"],
      },
    ],
  }
}

///|
fn files_json(bundle_root : String) -> Array[Json] {
  [
    {
      "path": lepus_project_path(bundle_root),
      "purpose": "Lepus project descriptor",
      "content_type": "application/json",
    },
    {
      "path": host_manifest_path(bundle_root),
      "purpose": "Moonrobo desktop host route manifest",
      "content_type": "application/json",
    },
    {
      "path": bundle_manifest_path(bundle_root),
      "purpose": "Moonrobo bundle manifest",
      "content_type": "application/json",
    },
    {
      "path": release_build_path(bundle_root),
      "purpose": "Moonrobo release binary build script",
      "content_type": "text/x-shellscript",
    },
    {
      "path": release_ui_dir(bundle_root),
      "purpose": "Moonrobo packaged Rabbita cockpit assets",
      "content_type": "text/html",
    },
    {
      "path": supervisor_runner_path(bundle_root),
      "purpose": "Moonrobo runtime supervisor runner",
      "content_type": "text/x-shellscript",
    },
    {
      "path": desktop_launch_path(bundle_root),
      "purpose": "Moonrobo desktop launch script",
      "content_type": "text/x-shellscript",
    },
  ]
}

///|
pub fn bundle_manifest_json(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Json {
  let checks = validate(config, bundle_root~)
  {
    "kind": "moonrobo-desktop-bundle",
    "version": "0.1.0",
    "ready": checks_ready(checks),
    "bundle_root": bundle_root,
    "base_url": @desktop_host.base_url(config),
    "launch_command": launch_command(bundle_root),
    "desktop_host_command": desktop_host_command(config, bundle_root~),
    "release_artifacts": release_artifacts_json(config, bundle_root),
    "files": files_json(bundle_root),
    "checks": checks_json(checks),
    "bridge_sidecar": bridge_sidecar_json(config, bundle_root),
    "runtime_supervisor": runtime_supervisor_json(config, bundle_root),
    "supervisor_runner": supervisor_runner_json(bundle_root),
    "desktop_launch": desktop_launch_json(bundle_root),
    "host_manifest": @desktop_host.service_manifest_json(
      bundle_host_config(config, bundle_root),
    ),
    "lepus_project": lepus_project_json(config, bundle_root),
  }
}

///|
fn ensure_bundle_root(bundle_root : String) -> Result[Unit, BundleIssue] {
  if @fsx.path_exists(bundle_root) {
    Ok(())
  } else {
    @fsx.create_dir(bundle_root) catch {
      _ =>
        return Err(
          issue(
            "create-bundle-root", bundle_root, "failed to create bundle root",
          ),
        )
    }
    Ok(())
  }
}

///|
fn write_json(path : String, value : Json) -> Result[String, BundleIssue] {
  @fsx.write_string_to_file(path, value.stringify(indent=2)) catch {
    _ => return Err(issue("write-json", path, "failed to write JSON file"))
  }
  Ok(path)
}

///|
fn write_text(path : String, value : String) -> Result[String, BundleIssue] {
  @fsx.write_string_to_file(path, value) catch {
    _ => return Err(issue("write-text", path, "failed to write text file"))
  }
  Ok(path)
}

///|
fn write_supervisor_runner(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Result[String, BundleIssue] {
  match runtime_supervisor_plan(config, bundle_root) {
    Ok(plan) =>
      write_text(
        supervisor_runner_path(bundle_root),
        @supervisor.shell_script(plan),
      )
    Err(error) => Err(error)
  }
}

///|
fn release_build_script(bundle_root : String) -> String {
  [
    "#!/usr/bin/env sh",
    "set -eu",
    "",
    "mkdir -p \{shell_quote(release_bin_dir(bundle_root))}",
    "moon build cmd/main --target native",
    "moon build cmd/sdk_e1_bridge --target native",
    "npm --prefix \{shell_quote(rabbita_source_root())} run build",
    "cp \{shell_quote(built_desktop_host_path())} \{shell_quote(release_desktop_host_path(bundle_root))}",
    "cp \{shell_quote(built_sdk_bridge_path())} \{shell_quote(release_sdk_bridge_path(bundle_root))}",
    "rm -rf \{shell_quote(release_ui_dir(bundle_root))}",
    "mkdir -p \{shell_quote(release_ui_dir(bundle_root))}",
    "cp -R \{shell_quote(built_rabbita_dist_path() + "/.")} \{shell_quote(release_ui_dir(bundle_root))}",
    "echo \{shell_quote("Moonrobo release artifacts installed under \{bundle_root}")}",
    "",
  ].join("\n")
}

///|
fn write_release_build(bundle_root : String) -> Result[String, BundleIssue] {
  write_text(release_build_path(bundle_root), release_build_script(bundle_root))
}

///|
fn shell_quote(value : String) -> String {
  "'" + value.replace(old="'", new="'\"'\"'") + "'"
}

///|
fn command_line(command : Array[String]) -> String {
  [ for arg in command => shell_quote(arg) ].join(" ")
}

///|
fn desktop_launch_script(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> String {
  [
    "#!/usr/bin/env sh",
    "set -eu",
    "",
    "RUNTIME_PID=\"\"",
    "HOST_PID=\"\"",
    "",
    "cleanup() {",
    "  if [ -n \"${HOST_PID:-}\" ]; then kill \"$HOST_PID\" 2>/dev/null || true; fi",
    "  if [ -n \"${RUNTIME_PID:-}\" ]; then kill \"$RUNTIME_PID\" 2>/dev/null || true; fi",
    "}",
    "trap cleanup INT TERM EXIT",
    "",
    "echo 'Moonrobo desktop launch: starting physical runtime supervisor'",
    "sh \{shell_quote(supervisor_runner_path(bundle_root))} &",
    "RUNTIME_PID=$!",
    "",
    "echo 'Moonrobo desktop launch: starting desktop host'",
    "\{command_line(desktop_host_command(config, bundle_root~))} &",
    "HOST_PID=$!",
    "",
    "wait \"$HOST_PID\"",
    "",
  ].join("\n")
}

///|
fn write_desktop_launch(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Result[String, BundleIssue] {
  write_text(
    desktop_launch_path(bundle_root),
    desktop_launch_script(config, bundle_root),
  )
}

///|
pub fn write_bundle_files(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Result[Array[String], BundleIssue] {
  match ensure_bundle_root(bundle_root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let written : Array[String] = []
  match write_release_build(bundle_root) {
    Ok(path) => written.push(path)
    Err(error) => return Err(error)
  }
  match
    write_json(
      lepus_project_path(bundle_root),
      lepus_project_json(config, bundle_root),
    ) {
    Ok(path) => written.push(path)
    Err(error) => return Err(error)
  }
  match
    write_json(
      host_manifest_path(bundle_root),
      @desktop_host.service_manifest_json(config),
    ) {
    Ok(path) => written.push(path)
    Err(error) => return Err(error)
  }
  match write_supervisor_runner(config, bundle_root) {
    Ok(path) => written.push(path)
    Err(error) => return Err(error)
  }
  match write_desktop_launch(config, bundle_root) {
    Ok(path) => written.push(path)
    Err(error) => return Err(error)
  }
  match
    write_json(
      bundle_manifest_path(bundle_root),
      bundle_manifest_json(config, bundle_root),
    ) {
    Ok(path) => written.push(path)
    Err(error) => return Err(error)
  }
  Ok(written)
}
