///|
fn is_command(value : String) -> Bool {
  value == "inspect" ||
  value == "mock" ||
  value == "cockpit" ||
  value == "cockpit-sdk-file" ||
  value == "api-snapshot" ||
  value == "api-health" ||
  value == "api-route" ||
  value == "serve" ||
  value == "host-manifest" ||
  value == "desktop-project" ||
  value == "desktop-bundle" ||
  value == "bridge-sidecar" ||
  value == "plan-walk" ||
  value == "bridge-health" ||
  value == "bridge-telemetry" ||
  value == "sdk-health" ||
  value == "sdk-telemetry" ||
  value == "sdk-telemetry-file" ||
  value == "receipts" ||
  value == "receipt" ||
  value == "help"
}

///|
fn cli_arg(args : Array[String], index : Int) -> String? {
  if index < args.length() {
    Some(args[index])
  } else {
    None
  }
}

///|
fn command_index(args : Array[String]) -> Int {
  match cli_arg(args, 0) {
    Some(value) if is_command(value) => 0
    _ => 1
  }
}

///|
fn next_action_text(action : @pipeline.PipelineNextAction) -> String {
  match action {
    Execute => "execute"
    CollectDryRun => "collect-dry-run"
    RequestApproval => "request-approval"
    Stop => "stop"
  }
}

///|
fn run_status_text(status : @core.RunStatus) -> String {
  match status {
    Denied => "denied"
    WaitingForApproval => "waiting-for-approval"
    WaitingForDryRun => "waiting-for-dry-run"
    ReadyForExecution => "ready-for-execution"
    Executed => "executed"
    Failed => "failed"
  }
}

///|
fn load_or_print(root : String) -> @runtime.LoadedRobotBook? {
  match @runtime.load_robotbook(root) {
    Ok(book) => Some(book)
    Err(issue) => {
      println(
        "Moonrobo load failed [\{issue.code}] \{issue.path}: \{issue.message}",
      )
      None
    }
  }
}

///|
fn print_usage() -> Unit {
  println("moon run cmd/main -- inspect [robotbook-root]")
  println("moon run cmd/main -- mock [robotbook-root]")
  println("moon run cmd/main -- cockpit [robotbook-root]")
  println(
    "moon run cmd/main -- cockpit-sdk-file [robotbook-root] [snapshot-json]",
  )
  println("moon run cmd/main -- api-snapshot [robotbook-root]")
  println("moon run cmd/main -- api-health [robotbook-root]")
  println(
    "moon run cmd/main -- api-route [robotbook-root] [method] [path] [body-json]",
  )
  println("moon run cmd/main -- serve [robotbook-root] [ui-root] [host] [port]")
  println(
    "moon run cmd/main -- host-manifest [robotbook-root] [ui-root] [host] [port]",
  )
  println(
    "moon run cmd/main -- desktop-project [robotbook-root] [ui-root] [host] [port] [sidecar-path]",
  )
  println(
    "moon run cmd/main -- desktop-bundle [robotbook-root] [ui-root] [host] [port] [sidecar-path] [bundle-root]",
  )
  println("moon run cmd/main -- bridge-sidecar [robotbook-root]")
  println("moon run cmd/main -- plan-walk [robotbook-root]")
  println("moon run cmd/main -- bridge-health [robotbook-root]")
  println("moon run cmd/main -- bridge-telemetry [robotbook-root]")
  println("moon run cmd/main -- sdk-health [robotbook-root]")
  println("moon run cmd/main -- sdk-telemetry [robotbook-root]")
  println(
    "moon run cmd/main -- sdk-telemetry-file [robotbook-root] [snapshot-json]",
  )
  println("moon run cmd/main -- receipts [robotbook-root]")
  println("moon run cmd/main -- receipt [robotbook-root] [receipt-id]")
}

///|
fn inspect(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) => {
      println("Moonrobo RobotBook: \{book.profile.label}")
      println("  root: \{book.root}")
      println("  id: \{book.profile.id}")
      println("  platform: \{book.profile.platform}")
      println("  ready: \{book.status.ready}")
      println("  joints: \{book.profile.joints.length()}")
      println("  capabilities: \{book.profile.capabilities.length()}")
      println("  missing_paths: \{book.status.missing_paths.length()}")
      println(
        "  validation_issues: \{book.status.profile_report.issues.length()}",
      )
    }
  }
}

///|
fn mock(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let bridge = @mock_bridge.new(book.profile)
      let frame = @mock_bridge.telemetry_frame(book.profile, bridge, 0L)
      let has_imu = frame.imu is Some(_)
      println("Moonrobo mock frame: \{frame.frame_id}")
      println("  robot: \{frame.robot_id}")
      println("  bridge: \{frame.bridge_id}")
      println("  mode: \{frame.mode}")
      println("  joints: \{frame.joints.length()}")
      println("  imu: \{has_imu}")
    }
  }
}

///|
fn receipts_or_empty(root : String) -> Array[@core.RunReceipt] {
  match @runtime.list_run_receipts(root) {
    Ok(receipts) => receipts
    Err(_) => []
  }
}

///|
fn walk_safety(
  profile : @core.RobotProfile,
  health : @core.BridgeHealth,
) -> @pipeline.PipelineResult {
  let intent = @pipeline.high_walk_intent(
    "intent-cli-cockpit-walk",
    profile.id,
    @core.operator_requester("cli"),
    "0.10",
    "0.00",
    "1000",
  )
  @pipeline.evaluate_request(
    profile, health, intent, "receipt-cli-cockpit-walk", 0L,
  )
}

///|
fn cockpit(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let bridge = @mock_bridge.new(book.profile)
      let health = @mock_bridge.health(book.profile, telemetry_age_ms=0)
      let frame = @mock_bridge.telemetry_frame(book.profile, bridge, 0L)
      let snapshot = @cockpit.snapshot(
        book,
        health,
        frame,
        walk_safety(book.profile, health),
        receipts_or_empty(root),
      )
      println(@cockpit.snapshot_json(snapshot))
    }
  }
}

///|
fn cockpit_sdk_file(root : String, snapshot_path : String) -> Unit {
  if snapshot_path == "" {
    println("Moonrobo SDK snapshot path is required")
    return
  }
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let text = @fsx.read_file_to_string(snapshot_path) catch {
        _ => {
          println("Moonrobo SDK snapshot read failed: \{snapshot_path}")
          return
        }
      }
      let sdk_snapshot = match @sdk_e1.parse_snapshot(text) {
        Ok(snapshot) => snapshot
        Err(issue) => {
          println(
            "Moonrobo SDK snapshot parse failed [\{issue.code}]: \{issue.message}",
          )
          return
        }
      }
      let frame = match @sdk_e1.telemetry_frame(book.profile, sdk_snapshot) {
        Ok(frame) => frame
        Err(issue) => {
          println(
            "Moonrobo SDK adapter failed [\{issue.code}]: \{issue.message}",
          )
          return
        }
      }
      let health = @sdk_e1.health(book.profile, sdk_snapshot)
      let snapshot = @cockpit.snapshot(
        book,
        health,
        frame,
        walk_safety(book.profile, health),
        receipts_or_empty(root),
      )
      println(@cockpit.snapshot_json(snapshot))
    }
  }
}

///|
fn api_snapshot(root : String) -> Unit {
  println(@host_api.snapshot_response(root).body)
}

///|
fn api_health(root : String) -> Unit {
  println(@host_api.health_response(root).body)
}

///|
fn api_route(
  root : String,
  http_method : String,
  path : String,
  body : String,
) -> Unit {
  let response = @host_api.route_with_body(root, http_method, path, body)
  println(response.body)
}

///|
fn parse_port(value : String, fallback : Int) -> Int {
  @string.parse_int(value) catch {
    _ => fallback
  }
}

///|
fn desktop_config(
  root : String,
  ui_root : String,
  host : String,
  port_text : String,
  sidecar_path : String,
) -> @desktop_host.DesktopHostConfig {
  @desktop_host.config(
    root,
    ui_root~,
    host~,
    port=parse_port(port_text, @desktop_host.default_port()),
    sidecar_path~,
  )
}

///|
fn host_manifest(config : @desktop_host.DesktopHostConfig) -> Unit {
  println(@desktop_host.service_manifest_json(config).stringify(indent=2))
}

///|
fn desktop_project(config : @desktop_host.DesktopHostConfig) -> Unit {
  println(@desktop_host.lepus_project_json(config).stringify(indent=2))
}

///|
fn desktop_bundle(
  config : @desktop_host.DesktopHostConfig,
  bundle_root : String,
) -> Unit {
  match @desktop_bundle.write_bundle_files(config, bundle_root) {
    Ok(files) => {
      println(
        @desktop_bundle.bundle_manifest_json(config, bundle_root).stringify(
          indent=2,
        ),
      )
      println("Moonrobo desktop bundle files:")
      for path in files {
        println("  \{path}")
      }
    }
    Err(issue) =>
      println(
        "Moonrobo desktop bundle failed [\{issue.code}] \{issue.path}: \{issue.message}",
      )
  }
}

///|
fn bridge_sidecar(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) =>
      println(
        @bridge_sidecar.spec_json(
          @bridge_sidecar.spec_for_profile(book.profile, root),
        ),
      )
  }
}

///|
fn serve(config : @desktop_host.DesktopHostConfig) -> Unit {
  let server = @desktop_host.Server::new(config.host, config.port) catch {
    error => {
      println(
        "Moonrobo desktop host failed to bind \{config.host}:\{config.port}: \{error}",
      )
      return
    }
  }
  println("Moonrobo desktop host: http://\{config.host}:\{server.port()}/")
  println("RobotBook root: \{config.robotbook_root}")
  println("Rabbita UI root: \{config.ui_root}")
  println("Readiness: \{@desktop_host.readiness_path()}")
  @async.with_event_loop(async fn(group) { server.serve(group, config) }) catch {
    error => println("Moonrobo desktop host stopped: \{error}")
  }
}

///|
fn plan_walk(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let intent = @pipeline.high_walk_intent(
        "intent-cli-plan-walk",
        book.profile.id,
        @core.operator_requester("cli"),
        "0.10",
        "0.00",
        "1000",
      )
      let result = @pipeline.evaluate_request(
        book.profile,
        @mock_bridge.health(book.profile, telemetry_age_ms=10),
        intent,
        "receipt-cli-plan-walk",
        0L,
      )
      println("Moonrobo plan-walk:")
      println("  action: \{next_action_text(result.next_action)}")
      println("  status: \{run_status_text(result.receipt.status)}")
      println("  reason: \{result.verdict.detail}")
      match @runtime.write_run_receipt(root, result.receipt) {
        Ok(path) => println("  receipt: \{path}")
        Err(issue) =>
          println(
            "  receipt_error: [\{issue.code}] \{issue.path}: \{issue.message}",
          )
      }
    }
  }
}

///|
fn bridge_health(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let request = @bridge_protocol.health_request(
        "request-cli-bridge-health",
        book.profile,
        0L,
      )
      let response = @bridge_protocol.health_response(
        request,
        @mock_bridge.health(book.profile),
      )
      println(@bridge_protocol.response_json(response))
    }
  }
}

///|
fn bridge_telemetry(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let bridge = @mock_bridge.new(book.profile)
      let telemetry = @mock_bridge.telemetry_frame(book.profile, bridge, 0L)
      let request = @bridge_protocol.telemetry_request(
        "request-cli-bridge-telemetry",
        book.profile,
        0L,
      )
      let response = @bridge_protocol.telemetry_response(request, telemetry)
      println(@bridge_protocol.response_json(response))
    }
  }
}

///|
fn sdk_snapshot(profile : @core.RobotProfile) -> @sdk_e1.SdkE1Snapshot {
  {
    ..@sdk_e1.default_snapshot("sdk-e1-cli-frame", 0L),
    joints: @sdk_e1.default_joint_states(profile),
  }
}

///|
fn sdk_health(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let response = @sdk_e1.health_response(
        "request-cli-sdk-health",
        book.profile,
        sdk_snapshot(book.profile),
      )
      println(@bridge_protocol.response_json(response))
    }
  }
}

///|
fn sdk_telemetry(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) =>
      match
        @sdk_e1.telemetry_response(
          "request-cli-sdk-telemetry",
          book.profile,
          sdk_snapshot(book.profile),
        ) {
        Ok(response) => println(@bridge_protocol.response_json(response))
        Err(issue) =>
          println(
            "Moonrobo SDK adapter failed [\{issue.code}]: \{issue.message}",
          )
      }
  }
}

///|
fn sdk_telemetry_file(root : String, snapshot_path : String) -> Unit {
  if snapshot_path == "" {
    println("Moonrobo SDK snapshot path is required")
    return
  }
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let text = @fsx.read_file_to_string(snapshot_path) catch {
        _ => {
          println("Moonrobo SDK snapshot read failed: \{snapshot_path}")
          return
        }
      }
      let snapshot = match @sdk_e1.parse_snapshot(text) {
        Ok(snapshot) => snapshot
        Err(issue) => {
          println(
            "Moonrobo SDK snapshot parse failed [\{issue.code}]: \{issue.message}",
          )
          return
        }
      }
      match
        @sdk_e1.telemetry_response(
          "request-cli-sdk-telemetry-file",
          book.profile,
          snapshot,
        ) {
        Ok(response) => println(@bridge_protocol.response_json(response))
        Err(issue) =>
          println(
            "Moonrobo SDK adapter failed [\{issue.code}]: \{issue.message}",
          )
      }
    }
  }
}

///|
fn receipts(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(_) =>
      match @runtime.list_run_receipts(root) {
        Err(issue) =>
          println(
            "Moonrobo receipts failed [\{issue.code}] \{issue.path}: \{issue.message}",
          )
        Ok(receipts) => {
          println("Moonrobo receipts: \{receipts.length()}")
          for receipt in receipts {
            println(
              "  \{receipt.receipt_id} \{run_status_text(receipt.status)} \{receipt.intent.capability}",
            )
          }
        }
      }
  }
}

///|
fn receipt(root : String, receipt_id : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(_) =>
      match @runtime.read_run_receipt(root, receipt_id) {
        Ok(receipt) => println(@runtime.receipt_json(receipt))
        Err(issue) =>
          println(
            "Moonrobo receipt failed [\{issue.code}] \{issue.path}: \{issue.message}",
          )
      }
  }
}

///|
fn main {
  let args = @sys.get_cli_args()
  let index = command_index(args)
  let command = cli_arg(args, index).unwrap_or("inspect")
  let root = cli_arg(args, index + 1).unwrap_or("examples/noetix-e1")
  let receipt_id = cli_arg(args, index + 2).unwrap_or("receipt-cli-plan-walk")
  let snapshot_path = cli_arg(args, index + 2).unwrap_or("")
  let api_method = cli_arg(args, index + 2).unwrap_or("GET")
  let api_path = cli_arg(args, index + 3).unwrap_or(@host_api.snapshot_path())
  let api_body = cli_arg(args, index + 4).unwrap_or("")
  let ui_root = cli_arg(args, index + 2).unwrap_or(
    @desktop_host.default_ui_root(),
  )
  let host = cli_arg(args, index + 3).unwrap_or(@desktop_host.default_host())
  let port = cli_arg(args, index + 4).unwrap_or(
    @desktop_host.default_port().to_string(),
  )
  let sidecar_path = cli_arg(args, index + 5).unwrap_or(
    @desktop_host.default_sidecar_path(),
  )
  let bundle_root = cli_arg(args, index + 6).unwrap_or(
    @desktop_bundle.default_bundle_root(),
  )
  let desktop = desktop_config(root, ui_root, host, port, sidecar_path)
  match command {
    "inspect" => inspect(root)
    "mock" => mock(root)
    "cockpit" => cockpit(root)
    "cockpit-sdk-file" => cockpit_sdk_file(root, snapshot_path)
    "api-snapshot" => api_snapshot(root)
    "api-health" => api_health(root)
    "api-route" => api_route(root, api_method, api_path, api_body)
    "serve" => serve(desktop)
    "host-manifest" => host_manifest(desktop)
    "desktop-project" => desktop_project(desktop)
    "desktop-bundle" => desktop_bundle(desktop, bundle_root)
    "bridge-sidecar" => bridge_sidecar(root)
    "plan-walk" => plan_walk(root)
    "bridge-health" => bridge_health(root)
    "bridge-telemetry" => bridge_telemetry(root)
    "sdk-health" => sdk_health(root)
    "sdk-telemetry" => sdk_telemetry(root)
    "sdk-telemetry-file" => sdk_telemetry_file(root, snapshot_path)
    "receipts" => receipts(root)
    "receipt" => receipt(root, receipt_id)
    "help" => print_usage()
    _ => {
      println("unknown Moonrobo command: \{command}")
      print_usage()
    }
  }
}
