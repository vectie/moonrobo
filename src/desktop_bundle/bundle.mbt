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
pub fn sidecar_command(
  config : @desktop_host.DesktopHostConfig,
) -> Array[String] {
  [
    config.sidecar_path,
    "serve",
    config.robobook_root,
    config.ui_root,
    config.host,
    config.port.to_string(),
  ]
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
fn ui_check(ui_root : String) -> BundleCheck {
  let path = @desktop_host.fallback_index_path(ui_root)
  if @fsx.path_exists(path) {
    ok("ui-index", path, "Rabbita entrypoint exists")
  } else {
    fail("ui-index-missing", path, "Rabbita entrypoint is missing")
  }
}

///|
fn sidecar_check(sidecar_path : String) -> BundleCheck {
  if @fsx.path_exists(sidecar_path) {
    ok("sidecar-path", sidecar_path, "desktop sidecar path exists")
  } else {
    fail("sidecar-missing", sidecar_path, "desktop sidecar path is missing")
  }
}

///|
pub fn validate(config : @desktop_host.DesktopHostConfig) -> Array[BundleCheck] {
  [
    robobook_check(config.robobook_root),
    ui_check(config.ui_root),
    sidecar_check(config.sidecar_path),
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
fn bridge_sidecar_json(config : @desktop_host.DesktopHostConfig) -> Json {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) => {
      let spec = @bridge_sidecar.spec_for_profile(
        book.profile,
        config.robobook_root,
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
) -> Result[@supervisor.SupervisorPlan, BundleIssue] {
  match @runtime.load_robobook(config.robobook_root) {
    Ok(book) =>
      Ok(
        @supervisor.plan(
          @bridge_sidecar.runtime_spec_for_profile(
            book.profile,
            config.robobook_root,
          ),
        ),
      )
    Err(error) => Err(issue(error.code, error.path, error.message))
  }
}

///|
fn runtime_supervisor_json(config : @desktop_host.DesktopHostConfig) -> Json {
  match runtime_supervisor_plan(config) {
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
      "path": supervisor_runner_path(bundle_root),
      "purpose": "Moonrobo runtime supervisor runner",
      "content_type": "text/x-shellscript",
    },
  ]
}

///|
pub fn bundle_manifest_json(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Json {
  let checks = validate(config)
  {
    "kind": "moonrobo-desktop-bundle",
    "version": "0.1.0",
    "ready": checks_ready(checks),
    "bundle_root": bundle_root,
    "base_url": @desktop_host.base_url(config),
    "sidecar_command": sidecar_command(config),
    "files": files_json(bundle_root),
    "checks": checks_json(checks),
    "bridge_sidecar": bridge_sidecar_json(config),
    "runtime_supervisor": runtime_supervisor_json(config),
    "supervisor_runner": supervisor_runner_json(bundle_root),
    "host_manifest": @desktop_host.service_manifest_json(config),
    "lepus_project": @desktop_host.lepus_project_json(config),
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
  match runtime_supervisor_plan(config) {
    Ok(plan) =>
      write_text(
        supervisor_runner_path(bundle_root),
        @supervisor.shell_script(plan),
      )
    Err(error) => Err(error)
  }
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
  match
    write_json(
      lepus_project_path(bundle_root),
      @desktop_host.lepus_project_json(config),
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
