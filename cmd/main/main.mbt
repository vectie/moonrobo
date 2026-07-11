///|
fn is_command(value : String) -> Bool {
  value == "inspect" ||
  value == "build-design" ||
  value == "validate-design" ||
  value == "mock" ||
  value == "cockpit" ||
  value == "cockpit-sdk-file" ||
  value == "resident" ||
  value == "runtime-supervisor" ||
  value == "runtime-supervisor-script" ||
  value == "runtime-supervisor-launch" ||
  value == "runtime-supervisor-status" ||
  value == "runtime-health" ||
  value == "runtime-validation" ||
  value == "runtime-validation-session" ||
  value == "status" ||
  value == "product-status" ||
  value == "readiness" ||
  value == "live-readiness" ||
  value == "live-closure" ||
  value == "session" ||
  value == "loop" ||
  value == "loop-proof" ||
  value == "bootstrap" ||
  value == "runtime-supervisor-start" ||
  value == "runtime-supervisor-stop" ||
  value == "moonclaw-context" ||
  value == "gateway-command" ||
  value == "prove-loop" ||
  value == "proof-session" ||
  value == "proof-sessions" ||
  value == "proof-session-detail" ||
  value == "live-exercises" ||
  value == "live-exercise-detail" ||
  value == "bind-feedback" ||
  value == "resolve-review" ||
  value == "moonstat" ||
  value == "memory" ||
  value == "remember" ||
  value == "platform-queue" ||
  value == "task-status" ||
  value == "tool-registry" ||
  value == "register-tools" ||
  value == "episode" ||
  value == "episode-quality" ||
  value == "message-task" ||
  value == "ask" ||
  value == "turn" ||
  value == "turns" ||
  value == "turn-detail" ||
  value == "loops" ||
  value == "loop-detail" ||
  value == "message-sidecar" ||
  value == "observe-task" ||
  value == "observe-run" ||
  value == "observe-run-sidecar" ||
  value == "execute-message-sidecar" ||
  value == "replay" ||
  value == "annotate-replay" ||
  value == "replay-annotations" ||
  value == "replay-annotation" ||
  value == "ingest-sdk-frame" ||
  value == "api-snapshot" ||
  value == "api-health" ||
  value == "api-route" ||
  value == "serve" ||
  value == "host-manifest" ||
  value == "desktop-project" ||
  value == "desktop-bundle" ||
  value == "bridge-sidecar" ||
  value == "bridge-execute" ||
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
fn load_or_print(root : String) -> @runtime.LoadedRoboBook? {
  match @runtime.load_robobook(root) {
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
  println(
    "moon run cmd/main -- build-design <robot-design.json> <robobook-root>",
  )
  println("moon run cmd/main -- validate-design <robobook-root>")
  println("moon run cmd/main -- inspect [robobook-root]")
  println("moon run cmd/main -- mock [robobook-root]")
  println("moon run cmd/main -- cockpit [robobook-root]")
  println("moon run cmd/main -- resident [robobook-root]")
  println("moon run cmd/main -- runtime-supervisor [robobook-root]")
  println("moon run cmd/main -- runtime-supervisor-script [robobook-root]")
  println("moon run cmd/main -- runtime-supervisor-launch [robobook-root]")
  println("moon run cmd/main -- runtime-supervisor-status [robobook-root]")
  println(
    "moon run cmd/main -- runtime-health [robobook-root] [bridge-host] [bridge-port]",
  )
  println(
    "moon run cmd/main -- runtime-validation [robobook-root] [bridge-host] [bridge-port]",
  )
  println(
    "moon run cmd/main -- runtime-validation-session [robobook-root] [bridge-host] [bridge-port] [sample-count]",
  )
  println("moon run cmd/main -- status [robobook-root]")
  println("moon run cmd/main -- product-status [robobook-root]")
  println("moon run cmd/main -- readiness [robobook-root]")
  println("moon run cmd/main -- live-readiness [robobook-root]")
  println("moon run cmd/main -- live-closure [robobook-root]")
  println("moon run cmd/main -- session [robobook-root]")
  println("moon run cmd/main -- loop [robobook-root] [message] [now-ms]")
  println("moon run cmd/main -- loop-proof [robobook-root]")
  println("moon run cmd/main -- bootstrap [robobook-root]")
  println("moon run cmd/main -- runtime-supervisor-start [robobook-root]")
  println("moon run cmd/main -- runtime-supervisor-stop [robobook-root]")
  println("moon run cmd/main -- moonclaw-context [robobook-root]")
  println(
    "moon run cmd/main -- gateway-command [robobook-root] [message] [now-ms]",
  )
  println("moon run cmd/main -- prove-loop [robobook-root] [message] [now-ms]")
  println(
    "moon run cmd/main -- proof-session [robobook-root] [message] [now-ms] [iterations]",
  )
  println("moon run cmd/main -- proof-sessions [robobook-root]")
  println(
    "moon run cmd/main -- proof-session-detail [robobook-root] [session-id]",
  )
  println("moon run cmd/main -- live-exercises [robobook-root]")
  println(
    "moon run cmd/main -- live-exercise-detail [robobook-root] [exercise-id]",
  )
  println(
    "moon run cmd/main -- bind-feedback [robobook-root] [snapshot-id] [telemetry-json-file]",
  )
  println(
    "moon run cmd/main -- resolve-review [robobook-root] [review-id] [note]",
  )
  println("moon run cmd/main -- moonstat [robobook-root]")
  println("moon run cmd/main -- memory [robobook-root]")
  println("moon run cmd/main -- remember [robobook-root]")
  println("moon run cmd/main -- handoff [robobook-root]")
  println("moon run cmd/main -- platform-queue [robobook-root]")
  println("moon run cmd/main -- task-status [robobook-root] [task-id]")
  println("moon run cmd/main -- tool-registry [robobook-root]")
  println("moon run cmd/main -- register-tools [robobook-root]")
  println("moon run cmd/main -- episode [robobook-root] [session-id]")
  println("moon run cmd/main -- episode-quality [robobook-root] [session-id]")
  println("moon run cmd/main -- message-task [robobook-root] [message]")
  println("moon run cmd/main -- ask [robobook-root] [message] [now-ms]")
  println("moon run cmd/main -- loops [robobook-root]")
  println("moon run cmd/main -- loop-detail [robobook-root] [loop-id]")
  println("moon run cmd/main -- turn [robobook-root] [message] [now-ms]")
  println("moon run cmd/main -- turns [robobook-root]")
  println("moon run cmd/main -- turn-detail [robobook-root] [turn-id]")
  println(
    "moon run cmd/main -- message-sidecar [robobook-root] [message] [host] [port]",
  )
  println("moon run cmd/main -- observe-task [robobook-root] [task-id]")
  println(
    "moon run cmd/main -- observe-run [robobook-root] [task-id] [frame-count]",
  )
  println(
    "moon run cmd/main -- observe-run-sidecar [robobook-root] [task-id] [frame-count] [host] [port]",
  )
  println(
    "moon run cmd/main -- execute-message-sidecar [robobook-root] [task-id] [host] [port]",
  )
  println(
    "moon run cmd/main -- bridge-execute [robobook-root] [intent-id] [host] [port]",
  )
  println("moon run cmd/main -- replay [robobook-root] [session-id]")
  println(
    "moon run cmd/main -- annotate-replay [robobook-root] [session-id] [frame-id]",
  )
  println(
    "moon run cmd/main -- replay-annotations [robobook-root] [session-id]",
  )
  println(
    "moon run cmd/main -- replay-annotation [robobook-root] [session-id] [annotation-id]",
  )
  println(
    "moon run cmd/main -- ingest-sdk-frame [robobook-root] [session-id] [frame-id]",
  )
  println(
    "moon run cmd/main -- cockpit-sdk-file [robobook-root] [snapshot-json]",
  )
  println("moon run cmd/main -- api-snapshot [robobook-root]")
  println("moon run cmd/main -- api-health [robobook-root]")
  println(
    "moon run cmd/main -- api-route [robobook-root] [method] [path] [body-json]",
  )
  println(
    "moon run cmd/main -- serve [robobook-root] [ui-root] [host] [port] [bridge-host] [bridge-port]",
  )
  println(
    "moon run cmd/main -- host-manifest [robobook-root] [ui-root] [host] [port] [bridge-host] [bridge-port]",
  )
  println(
    "moon run cmd/main -- desktop-project [robobook-root] [ui-root] [host] [port] [sidecar-path] [bridge-host] [bridge-port]",
  )
  println(
    "moon run cmd/main -- desktop-bundle [robobook-root] [ui-root] [host] [port] [sidecar-path] [bundle-root] [bridge-host] [bridge-port]",
  )
  println("moon run cmd/main -- bridge-sidecar [robobook-root]")
  println("moon run cmd/main -- plan-walk [robobook-root]")
  println("moon run cmd/main -- bridge-health [robobook-root]")
  println("moon run cmd/main -- bridge-telemetry [robobook-root]")
  println("moon run cmd/main -- sdk-health [robobook-root]")
  println("moon run cmd/main -- sdk-telemetry [robobook-root]")
  println(
    "moon run cmd/main -- sdk-telemetry-file [robobook-root] [snapshot-json]",
  )
  println("moon run cmd/main -- receipts [robobook-root]")
  println("moon run cmd/main -- receipt [robobook-root] [receipt-id]")
}

///|
fn inspect(root : String) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) => {
      println("Moonrobo RoboBook: \{book.profile.label}")
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
fn build_design(design_path : String, output_root : String) -> Unit {
  let text = @fsx.read_file_to_string(design_path) catch {
    _ => {
      println(
        Json::object({
          "accepted": false,
          "error": "failed to read robot design",
          "path": design_path,
        }).stringify(indent=2),
      )
      @sys.exit(1)
      return
    }
  }
  match @design_builder.build_robobook(text, design_path, output_root) {
    Ok(result) =>
      println(
        Json::object({ "accepted": true, "result": result.to_json() }).stringify(
          indent=2,
        ),
      )
    Err(issue) => {
      println(
        Json::object({ "accepted": false, "issue": issue.to_json() }).stringify(
          indent=2,
        ),
      )
      @sys.exit(1)
    }
  }
}

///|
fn validate_design(root : String) -> Unit {
  match @design_builder.validate_robobook(root) {
    Ok(result) => println(result.stringify(indent=2))
    Err(issue) => {
      println(
        Json::object({ "accepted": false, "issue": issue.to_json() }).stringify(
          indent=2,
        ),
      )
      @sys.exit(1)
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
fn moonclaw_context(root : String) -> Unit {
  println(@host_api.route(root, "GET", @host_api.moonclaw_context_path()).body)
}

///|
fn resolve_review(root : String, review_id : String, note : String) -> Unit {
  let request : @host_api.ReviewResolutionRequest = { note, resolved_at_ms: 0L }
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.review_resolve_path(review_id),
      request.to_json().stringify(),
    ).body,
  )
}

///|
fn moonstat(root : String) -> Unit {
  println(@host_api.moonstat_status_response(root).body)
}

///|
fn memory(root : String) -> Unit {
  println(@host_api.route(root, "GET", @host_api.moonbook_memory_path()).body)
}

///|
fn remember(root : String) -> Unit {
  println(
    @host_api.route(root, "POST", @host_api.moonbook_remember_path()).body,
  )
}

///|
fn handoff(root : String) -> Unit {
  println(@host_api.route(root, "GET", @host_api.robo_handoff_path()).body)
}

///|
fn platform_queue(root : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.robot_platform_queue_path()).body,
  )
}

///|
fn task_status(root : String, task_id : String) -> Unit {
  println(
    @host_api.route(
      root,
      "GET",
      @host_api.moonbook_task_message_status_path(task_id),
    ).body,
  )
}

///|
fn tool_registry(root : String) -> Unit {
  println(@host_api.route(root, "GET", @host_api.tool_registry_path()).body)
}

///|
fn register_tools(root : String) -> Unit {
  let loaded = match load_or_print(root) {
    Some(book) => book
    None => return
  }
  let request : @host_api.ToolRegistrationRequest = {
    provider: @tool_registry.moonrobo_host_provider(loaded.profile.id, 0L),
    now_ms: 0L,
  }
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.tool_register_path(),
      request.to_json().stringify(),
    ).body,
  )
}

///|
fn episode(root : String, session_id : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.dataset_episode_path(session_id)).body,
  )
}

///|
fn episode_quality(root : String, session_id : String) -> Unit {
  println(
    @host_api.route(
      root,
      "GET",
      @host_api.dataset_episode_quality_path(session_id),
    ).body,
  )
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
fn sidecar_status(
  root : String,
  profile : @core.RobotProfile,
) -> @bridge_sidecar.BridgeSidecarStatus {
  let spec = @bridge_sidecar.spec_for_profile(profile, root)
  @bridge_sidecar.status_for_spec(
    spec,
    !spec.command.is_empty() && @fsx.path_exists(spec.command[0]),
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
      let urdf_model = @runtime.read_urdf_model(book)
      let snapshot = @cockpit.snapshot(
        book,
        health,
        sidecar_status(root, book.profile),
        frame,
        walk_safety(book.profile, health),
        receipts_or_empty(root),
        urdf_model~,
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
      let urdf_model = @runtime.read_urdf_model(book)
      let snapshot = @cockpit.snapshot(
        book,
        health,
        sidecar_status(root, book.profile),
        frame,
        walk_safety(book.profile, health),
        receipts_or_empty(root),
        urdf_model~,
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
fn resident(root : String) -> Unit {
  println(@host_api.resident_response(root).body)
}

///|
fn observe_task(root : String, task_id : String) -> Unit {
  let request = @task.observe_task_request(
    task_id,
    "",
    @core.moontown_requester("standing-goal"),
    "scheduled telemetry observation",
    0L,
  )
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moontown_observe_task_path(),
      request.to_json().stringify(),
    ).body,
  )
}

///|
fn message_task(root : String, message : String) -> Unit {
  let now_ms = @env.now().reinterpret_as_int64()
  let request = @task.task_message_request(
    "cli-message-\{now_ms}",
    "",
    @core.operator_requester("cli"),
    message,
    now_ms,
  )
  let response = @host_api.route_with_body(
    root,
    "POST",
    @host_api.moontown_task_message_path(),
    request.to_json().stringify(),
  )
  println(response.body)
  if response.status >= 400 {
    @sys.exit(1)
  }
}

///|
fn ask(root : String, message : String, now_ms : Int64) -> Unit {
  let request = @task.task_message_request(
    "cli-ask-\{now_ms}",
    "",
    @core.operator_requester("cli"),
    message,
    now_ms,
  )
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.robo_ask_path(),
      request.to_json().stringify(),
    ).body,
  )
}

///|
fn turn(root : String, message : String, now_ms : Int64) -> Unit {
  let request : @host_api.RoboTurnRequest = {
    task_message: @task.task_message_request(
      "cli-turn-\{now_ms}",
      "",
      @core.operator_requester("cli"),
      message,
      now_ms,
    ),
    now_ms,
    remember: true,
  }
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.robo_turn_path(),
      request.to_json().stringify(),
    ).body,
  )
}

///|
fn robo_loop_cli(root : String, message : String, now_ms : Int64) -> Unit {
  let request : @host_api.RoboLoopRequest = {
    loop_id: "cli-loop-\{now_ms}",
    turn: Some({
      task_message: @task.task_message_request(
        "cli-loop-\{now_ms}",
        "",
        @core.operator_requester("cli"),
        message,
        now_ms,
      ),
      now_ms,
      remember: true,
    }),
    now_ms,
    remember: true,
  }
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.robo_loop_path(),
      request.to_json().stringify(),
    ).body,
  )
}

///|
fn loops(root : String) -> Unit {
  println(@host_api.route(root, "GET", @host_api.robo_loops_path()).body)
}

///|
fn loop_detail(root : String, loop_id : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.robo_loop_detail_path(loop_id)).body,
  )
}

///|
fn turns(root : String) -> Unit {
  println(@host_api.route(root, "GET", @host_api.robo_turns_path()).body)
}

///|
fn turn_detail(root : String, turn_id : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.robo_turn_detail_path(turn_id)).body,
  )
}

///|
fn robo_session(root : String) -> Unit {
  println(@host_api.route(root, "GET", @host_api.robo_session_path()).body)
}

///|
fn product_status(root : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.moonrobo_product_status_path()).body,
  )
}

///|
fn gateway_status(root : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.moonrobo_gateway_status_path()).body,
  )
}

///|
fn live_readiness(root : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.moonrobo_live_readiness_path()).body,
  )
}

///|
fn parse_ms(value : String, fallback : Int64) -> Int64 {
  (@string.parse_int(value) catch { _ => return fallback }).to_int64()
}

///|
fn gateway_command_body(message : String, now_ms : Int64) -> String {
  let request : @host_api.MoonroboGatewayCommandRequest = {
    command_id: "cli-gateway-command-\{now_ms}",
    robot_id: "",
    requested_by: @core.operator_requester("cli"),
    goal: message,
    now_ms,
    remember: true,
  }
  request.to_json().stringify()
}

///|
fn gateway_command(root : String, message : String, now_ms : Int64) -> Unit {
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moonrobo_gateway_command_path(),
      gateway_command_body(message, now_ms),
    ).body,
  )
}

///|
fn prove_loop_body(message : String, now_ms : Int64) -> String {
  let request : @host_api.PlatformProveLoopRequest = {
    task_message: @task.task_message_request(
      "cli-prove-loop-\{now_ms}",
      "",
      @core.operator_requester("cli"),
      message,
      now_ms,
    ),
    max_steps: 8,
    bootstrap: true,
  }
  request.to_json().stringify()
}

///|
fn prove_loop(root : String, message : String, now_ms : Int64) -> Unit {
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.platform_prove_loop_path(),
      prove_loop_body(message, now_ms),
    ).body,
  )
}

///|
fn proof_session_body(
  message : String,
  now_ms : Int64,
  iterations : Int,
) -> String {
  let request : @host_api.PlatformProofSessionRequest = {
    session_id: "cli-proof-session-\{now_ms}",
    task_message: @task.task_message_request(
      "cli-proof-session-\{now_ms}",
      "",
      @core.operator_requester("cli"),
      message,
      now_ms,
    ),
    iterations,
    max_steps: 8,
    bootstrap: true,
    stop_when_ready: true,
  }
  request.to_json().stringify()
}

///|
fn proof_session(
  root : String,
  message : String,
  now_ms : Int64,
  iterations : Int,
) -> Unit {
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.platform_proof_session_path(),
      proof_session_body(message, now_ms, iterations),
    ).body,
  )
}

///|
fn proof_sessions(root : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.platform_proof_sessions_path()).body,
  )
}

///|
fn proof_session_detail(root : String, session_id : String) -> Unit {
  println(
    @host_api.route(
      root,
      "GET",
      @host_api.platform_proof_session_detail_path(session_id),
    ).body,
  )
}

///|
fn live_exercises(root : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.moonrobo_live_exercises_path()).body,
  )
}

///|
fn live_closure(root : String) -> Unit {
  println(
    @host_api.route(
      root,
      "GET",
      @host_api.moonrobo_live_exercise_closure_path(),
    ).body,
  )
}

///|
fn live_exercise_detail(root : String, exercise_id : String) -> Unit {
  println(
    @host_api.route(
      root,
      "GET",
      @host_api.moonrobo_live_exercise_detail_path(exercise_id),
    ).body,
  )
}

///|
fn bind_feedback(
  root : String,
  snapshot_id : String,
  telemetry_path : String,
) -> Unit {
  let text = @fsx.read_file_to_string(telemetry_path) catch {
    _ => {
      println(
        "{\"code\":\"read-feedback-file\",\"message\":\"failed to read telemetry JSON file\"}",
      )
      return
    }
  }
  let json = @json.parse(text) catch {
    _ => {
      println(
        "{\"code\":\"parse-feedback-file\",\"message\":\"failed to parse telemetry JSON file\"}",
      )
      return
    }
  }
  let telemetry : @core.TelemetryFrame = @json.from_json(json) catch {
    _ => {
      println(
        "{\"code\":\"decode-feedback-file\",\"message\":\"failed to decode telemetry frame\"}",
      )
      return
    }
  }
  let request : @host_api.TaskExecutionFeedbackRequest = {
    snapshot_id,
    telemetry,
    session_id: "",
  }
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.task_execution_feedback_path(),
      request.to_json().stringify(),
    ).body,
  )
}

///|
fn message_sidecar(
  root : String,
  message : String,
  host : String,
  port : Int,
) -> Unit {
  match
    @bridge_execution.run_reviewed_message_with_sidecar(
      root,
      "cli-message",
      message,
      @core.operator_requester("cli"),
      0L,
      @bridge_client.config(host~, port~),
    ) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(issue) => println(issue.to_json().stringify(indent=2))
  }
}

///|
fn observe_run(root : String, task_id : String, frame_count : Int) -> Unit {
  let now_ms = @env.now().reinterpret_as_int64()
  let request : @pipeline.ObservationRunRequest = {
    task_id,
    robot_id: "",
    requester: @core.moontown_requester("standing-goal"),
    goal: "scheduled telemetry observation run",
    now_ms,
    frame_count,
    frame_interval_ms: 1L,
  }
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.moontown_observe_run_path(),
      request.to_json().stringify(),
    ).body,
  )
}

///|
fn sidecar_telemetry_frame(
  client : @bridge_client.BridgeClientConfig,
) -> @core.TelemetryFrame? {
  match @bridge_client.get_telemetry_frame(client) {
    Ok(frame) => Some(frame)
    Err(error) => {
      println(error.to_json().stringify(indent=2))
      None
    }
  }
}

///|
fn collect_sidecar_frames(
  client : @bridge_client.BridgeClientConfig,
  task_id : String,
  frame_count : Int,
) -> Array[@core.TelemetryFrame]? {
  let count = if frame_count < 1 { 1 } else { frame_count }
  let frames : Array[@core.TelemetryFrame] = []
  for index in 0..<count {
    match sidecar_telemetry_frame(client) {
      Some(frame) =>
        frames.push(
          @bridge_client.sampled_telemetry_frame(frame, task_id, index),
        )
      None => return None
    }
  }
  Some(frames)
}

///|
fn observe_run_sidecar(
  root : String,
  task_id : String,
  frame_count : Int,
  host : String,
  port : Int,
) -> Unit {
  let request : @pipeline.ObservationRunRequest = {
    task_id,
    robot_id: "",
    requester: @core.moontown_requester("standing-goal"),
    goal: "sidecar telemetry observation run",
    now_ms: 0L,
    frame_count,
    frame_interval_ms: 1L,
  }
  let frames = match
    collect_sidecar_frames(
      @bridge_client.config(host~, port~),
      request.task_id,
      request.frame_count,
    ) {
    Some(frames) => frames
    None => return
  }
  match
    @pipeline.run_bounded_observation_with_telemetry(root, request, frames) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(issue) =>
      println(
        { "code": issue.code, "path": issue.path, "message": issue.message }
        .to_json()
        .stringify(indent=2),
      )
  }
}

///|
fn bridge_execute(
  root : String,
  intent_id : String,
  host : String,
  port : Int,
) -> Unit {
  let client = @bridge_client.config(host~, port~)
  match
    @runtime_process.require_active_run(
      root,
      expected_bridge_base_url=@bridge_client.bridge_base_url(client),
    ) {
    Ok(_) => ()
    Err(issue) => {
      println(issue.to_json().stringify(indent=2))
      return
    }
  }
  if !runtime_validation_ready_for_cli(root, host, port) {
    return
  }
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let intent = @pipeline.high_walk_intent(
        intent_id,
        book.profile.id,
        @core.operator_requester("cli"),
        "0.10",
        "0.00",
        "1000",
      )
      let request = @bridge_protocol.execute_request(
        "request-cli-execute-\{intent.intent_id}-0",
        book.profile,
        intent,
        0L,
      )
      match @bridge_client.post_execute_intent(client, request) {
        Ok(response) => println(@bridge_protocol.response_json(response))
        Err(issue) => println(issue.to_json().stringify(indent=2))
      }
    }
  }
}

///|
fn execute_message_sidecar(
  root : String,
  task_id : String,
  host : String,
  port : Int,
) -> Unit {
  let client = @bridge_client.config(host~, port~)
  let runtime_log_path = match
    @runtime_process.require_active_run(
      root,
      expected_bridge_base_url=@bridge_client.bridge_base_url(client),
    ) {
    Ok(run) => run.log_path
    Err(issue) => {
      println(issue.to_json().stringify(indent=2))
      return
    }
  }
  if !runtime_validation_ready_for_cli(root, host, port) {
    return
  }
  match
    @bridge_execution.execute_task_message_with_sidecar(
      root,
      task_id,
      client,
      runtime_log_path~,
    ) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(issue) => println(issue.to_json().stringify(indent=2))
  }
}

///|
fn replay(root : String, session_id : String) -> Unit {
  println(@host_api.route(root, "GET", @host_api.replay_path(session_id)).body)
}

///|
fn annotate_replay(
  root : String,
  session_id : String,
  frame_id : String,
) -> Unit {
  let request : @host_api.ReplayAnnotationRequest = {
    annotation_id: "annotation-cli-\{session_id}",
    frame_id,
    label: "usable",
    note: "cli marked replay evidence usable",
    severity: "info",
    requester: @core.operator_requester("cli"),
    created_at_ms: 0L,
  }
  println(
    @host_api.route_with_body(
      root,
      "POST",
      @host_api.replay_annotations_path(session_id),
      request.to_json().stringify(),
    ).body,
  )
}

///|
fn replay_annotations(root : String, session_id : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.replay_annotations_path(session_id)).body,
  )
}

///|
fn replay_annotation(
  root : String,
  session_id : String,
  annotation_id : String,
) -> Unit {
  println(
    @host_api.route(
      root,
      "GET",
      @host_api.replay_annotation_path(session_id, annotation_id),
    ).body,
  )
}

///|
fn ingest_sdk_frame(
  root : String,
  session_id : String,
  frame_id : String,
) -> Unit {
  match load_or_print(root) {
    None => ()
    Some(book) => {
      let snapshot = {
        ..sdk_snapshot(book.profile),
        frame_id,
        captured_at_ms: 1L,
      }
      let frame = match @sdk_e1.telemetry_frame(book.profile, snapshot) {
        Ok(frame) => frame
        Err(issue) => {
          println(
            "Moonrobo SDK adapter failed [\{issue.code}]: \{issue.message}",
          )
          return
        }
      }
      println(
        @host_api.route_with_body(
          root,
          "POST",
          @host_api.observation_frame_path(session_id),
          frame.to_json().stringify(),
        ).body,
      )
    }
  }
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
  bridge_host : String,
  bridge_port_text : String,
) -> @desktop_host.DesktopHostConfig {
  @desktop_host.config(
    root,
    ui_root~,
    host~,
    port=parse_port(port_text, @desktop_host.default_port()),
    sidecar_path~,
    bridge_host~,
    bridge_port=parse_port(
      bridge_port_text,
      @desktop_host.default_bridge_port(),
    ),
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
  println(@host_api.route(root, "GET", @host_api.bridge_sidecar_path()).body)
}

///|
fn runtime_supervisor(root : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.runtime_supervisor_path()).body,
  )
}

///|
fn runtime_supervisor_script(root : String) -> Unit {
  println(
    @host_api.route(root, "GET", @host_api.runtime_supervisor_script_path()).body,
  )
}

///|
fn runtime_supervisor_launch(root : String) -> Unit {
  println(
    @host_api.route(root, "POST", @host_api.runtime_supervisor_launch_path()).body,
  )
}

///|
fn runtime_supervisor_plan_for_root(
  root : String,
) -> @supervisor.SupervisorPlan? {
  match load_or_print(root) {
    None => None
    Some(book) =>
      Some(
        @supervisor.plan(
          @bridge_sidecar.runtime_spec_for_profile(book.profile, root),
        ),
      )
  }
}

///|
fn runtime_validation_log_probe(root : String) -> (String, Bool) {
  match @runtime_process.read_active_run(root) {
    Ok(Some(run)) =>
      (run.log_path, run.log_path != "" && @fsx.path_exists(run.log_path))
    _ => ("", false)
  }
}

///|
fn runtime_validation_health_snapshot(
  root : String,
  bridge_host : String,
  bridge_port : Int,
) -> @runtime_process.RuntimeHealthSnapshot? {
  let probe = match @runtime_process.read_active_run(root) {
    Ok(Some(run)) if run.running => {
      let client = @bridge_client.config(host=bridge_host, port=bridge_port)
      match @bridge_client.get_telemetry_frame(client) {
        Ok(frame) =>
          Some(
            @runtime_process.telemetry_probe_from_frame(
              frame,
              path=client.telemetry_path,
            ),
          )
        Err(issue) =>
          Some(
            @runtime_process.telemetry_probe_from_error(
              issue.code,
              issue.path,
              issue.message,
            ),
          )
      }
    }
    _ => None
  }
  match @runtime_process.runtime_health_snapshot(root, telemetry_probe=probe) {
    Ok(snapshot) => Some(snapshot)
    Err(_) => None
  }
}

///|
fn runtime_validation_report_for_cli(
  root : String,
  bridge_host : String,
  bridge_port : Int,
  generated_at_ms? : Int64 = @env.now().reinterpret_as_int64(),
  report_id? : String? = None,
) -> (@runtime_validation.RuntimeValidationReport, String)? {
  match load_or_print(root) {
    None => None
    Some(book) => {
      let plan = @supervisor.plan(
        @bridge_sidecar.runtime_spec_for_profile(
          book.profile,
          root,
          host=bridge_host,
          port=bridge_port,
        ),
      )
      let health = runtime_validation_health_snapshot(
        root, bridge_host, bridge_port,
      )
      let (log_path, log_exists) = runtime_validation_log_probe(root)
      let report = @runtime_validation.validation_report(
        plan,
        generated_at_ms,
        health~,
        log_path~,
        log_exists~,
        report_id?,
      )
      match
        @runtime.write_runtime_validation_report(
          root,
          report.report_id,
          report.to_json().stringify(indent=2),
        ) {
        Ok(path) => Some((report, path))
        Err(issue) => {
          println(issue.to_json().stringify(indent=2))
          None
        }
      }
    }
  }
}

///|
fn validation_sample_count(value : Int) -> Int {
  if value < 1 {
    1
  } else if value > 20 {
    20
  } else {
    value
  }
}

///|
fn runtime_validation_blocked_json(
  report : @runtime_validation.RuntimeValidationReport,
  report_path : String,
) -> Json {
  {
    "code": "runtime-validation-blocked",
    "path": report_path,
    "message": "runtime validation is \{report.status}; live SDK readiness is required before physical sidecar execution",
    "report": report.to_json(),
  }
}

///|
fn runtime_validation_ready_for_cli(
  root : String,
  bridge_host : String,
  bridge_port : Int,
) -> Bool {
  match runtime_validation_report_for_cli(root, bridge_host, bridge_port) {
    None => false
    Some((report, path)) =>
      if report.ready_for_live_sdk {
        true
      } else {
        println(
          runtime_validation_blocked_json(report, path).stringify(indent=2),
        )
        false
      }
  }
}

///|
fn runtime_supervisor_status(root : String) -> Unit {
  match @runtime_process.read_active_run(root) {
    Ok(Some(run)) => println(run.to_json().stringify(indent=2))
    Ok(None) => {
      let status : Json = { "status": "not-running", "running": false }
      println(status.stringify(indent=2))
    }
    Err(issue) => println(issue.to_json().stringify(indent=2))
  }
}

///|
fn runtime_health(
  root : String,
  bridge_host : String,
  bridge_port : Int,
) -> Unit {
  match runtime_health_from_bridge_json(root, bridge_host, bridge_port) {
    Some(response) => println(response.stringify(indent=2))
    None => {
      let response : Json = {
        "persisted": false,
        "message": "runtime health unavailable",
      }
      println(response.stringify(indent=2))
    }
  }
}

///|
fn runtime_health_from_bridge_json(
  root : String,
  bridge_host : String,
  bridge_port : Int,
) -> Json? {
  let probe = match @runtime_process.read_active_run(root) {
    Ok(Some(run)) if run.running => {
      let client = @bridge_client.config(host=bridge_host, port=bridge_port)
      match @bridge_client.get_telemetry_frame(client) {
        Ok(frame) =>
          Some(
            @runtime_process.telemetry_probe_from_frame(
              frame,
              path=client.telemetry_path,
            ),
          )
        Err(issue) =>
          Some(
            @runtime_process.telemetry_probe_from_error(
              issue.code,
              issue.path,
              issue.message,
            ),
          )
      }
    }
    _ => None
  }
  match @runtime_process.runtime_health_snapshot(root, telemetry_probe=probe) {
    Ok(snapshot) => {
      let record = @runtime_process.runtime_health_record(snapshot)
      match @runtime.write_runtime_health(root, record) {
        Ok(path) => {
          let response : Json = {
            "persisted": true,
            "runtime_health_path": path,
            "latest_runtime_health_path": @runtime.latest_runtime_health_path(
              root,
            ),
            "record": record.to_json(),
            "snapshot": snapshot.to_json(),
          }
          Some(response)
        }
        Err(issue) => Some(issue.to_json())
      }
    }
    Err(issue) => Some(issue.to_json())
  }
}

///|
fn runtime_validation(
  root : String,
  bridge_host : String,
  bridge_port : Int,
) -> Unit {
  match runtime_validation_report_for_cli(root, bridge_host, bridge_port) {
    None => ()
    Some((report, path)) => {
      let response : Json = {
        "persisted": true,
        "report_path": path,
        "latest_report_path": @runtime.latest_runtime_validation_path(root),
        "report": report.to_json(),
      }
      println(response.stringify(indent=2))
    }
  }
}

///|
fn runtime_validation_session(
  root : String,
  bridge_host : String,
  bridge_port : Int,
  sample_count : Int,
) -> Unit {
  let count = validation_sample_count(sample_count)
  let started_at_ms = @env.now().reinterpret_as_int64()
  let reports : Array[@runtime_validation.RuntimeValidationReport] = []
  for index in 0..<count {
    let generated_at_ms = started_at_ms + index.to_int64()
    let report_id = "runtime-validation-sample-\{generated_at_ms}-\{index}"
    match
      runtime_validation_report_for_cli(
        root,
        bridge_host,
        bridge_port,
        generated_at_ms~,
        report_id=Some(report_id),
      ) {
      Some((report, _path)) => reports.push(report)
      None => ()
    }
  }
  let session = @runtime_validation.validation_session(
    reports,
    started_at_ms,
    required_sample_count=count,
    session_id="runtime-validation-session-\{started_at_ms}",
  )
  let calibration = @runtime_validation.calibration_plan_for_session(
    session,
    started_at_ms,
    plan_id="runtime-calibration-\{started_at_ms}",
  )
  match
    @runtime.write_runtime_validation_session(
      root,
      session.session_id,
      session.to_json().stringify(indent=2),
    ) {
    Ok(path) => {
      let calibration_path = match
        @runtime.write_runtime_calibration_plan(
          root,
          calibration.plan_id,
          calibration.to_json().stringify(indent=2),
        ) {
        Ok(path) => path
        Err(issue) => {
          println(issue.to_json().stringify(indent=2))
          ""
        }
      }
      let response : Json = {
        "persisted": true,
        "session_path": path,
        "latest_session_path": @runtime.latest_runtime_validation_session_path(
          root,
        ),
        "calibration_path": calibration_path,
        "latest_calibration_path": @runtime.latest_runtime_calibration_plan_path(
          root,
        ),
        "session": session.to_json(),
        "calibration": calibration.to_json(),
      }
      println(response.stringify(indent=2))
    }
    Err(issue) => println(issue.to_json().stringify(indent=2))
  }
}

///|
fn readiness(root : String) -> Unit {
  println(@host_api.platform_readiness_response(root).body)
}

///|
fn loop_proof(root : String) -> Unit {
  println(@host_api.platform_loop_proof_response(root).body)
}

///|
fn bootstrap(root : String) -> Unit {
  println(@host_api.platform_bootstrap_response(root, "{}").body)
}

///|
fn runtime_supervisor_start(root : String) -> Unit {
  match runtime_supervisor_plan_for_root(root) {
    None => ()
    Some(plan) =>
      match @runtime_process.start_launch(root, plan) {
        Ok(run) => {
          let snapshot = match @runtime_process.runtime_health_snapshot(root) {
            Ok(snapshot) => snapshot
            Err(issue) => {
              println(issue.to_json().stringify(indent=2))
              return
            }
          }
          let record = @runtime_process.runtime_health_record(snapshot)
          match @runtime.write_runtime_health(root, record) {
            Ok(path) => {
              let response : Json = {
                "active": true,
                "persisted": true,
                "runtime_health_path": path,
                "latest_runtime_health_path": @runtime.latest_runtime_health_path(
                  root,
                ),
                "run": run.to_json(),
                "snapshot": snapshot.to_json(),
                "record": record.to_json(),
              }
              println(response.stringify(indent=2))
            }
            Err(issue) => println(issue.to_json().stringify(indent=2))
          }
        }
        Err(issue) => println(issue.to_json().stringify(indent=2))
      }
  }
}

///|
fn runtime_supervisor_stop(root : String) -> Unit {
  match @runtime_process.stop_active_run(root) {
    Ok(result) => println(result.to_json().stringify(indent=2))
    Err(issue) => println(issue.to_json().stringify(indent=2))
  }
}

///|
fn serve(config : @desktop_host.DesktopHostConfig) -> Unit {
  @async.with_event_loop(async fn(group) {
    let server = @desktop_host.Server::new(config.host, config.port) catch {
      error => {
        println(
          "Moonrobo desktop host failed to bind \{config.host}:\{config.port}: \{error}",
        )
        return
      }
    }
    println("Moonrobo desktop host: http://\{config.host}:\{server.port()}/")
    println("RoboBook root: \{config.robobook_root}")
    println("Rabbita UI root: \{config.ui_root}")
    println("Readiness: \{@desktop_host.readiness_path()}")
    server.serve(group, config)
  }) catch {
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
  let build_output_root = cli_arg(args, index + 2).unwrap_or(
    "robots/generated-robobook",
  )
  let receipt_id = cli_arg(args, index + 2).unwrap_or("receipt-cli-plan-walk")
  let review_id = cli_arg(args, index + 2).unwrap_or("review-cli")
  let review_note = cli_arg(args, index + 3).unwrap_or(
    "operator accepted review evidence",
  )
  let task_id = cli_arg(args, index + 2).unwrap_or("standing-goal-cli")
  let task_message = cli_arg(args, index + 2).unwrap_or("inspect robot status")
  let turn_id = cli_arg(args, index + 2).unwrap_or("robo-turn-message-cli")
  let loop_id = cli_arg(args, index + 2).unwrap_or("cli-loop")
  let ask_now_ms = parse_ms(
    cli_arg(args, index + 3).unwrap_or(""),
    @env.now().reinterpret_as_int64(),
  )
  let turn_now_ms = parse_ms(
    cli_arg(args, index + 3).unwrap_or(""),
    @env.now().reinterpret_as_int64(),
  )
  let loop_now_ms = parse_ms(
    cli_arg(args, index + 3).unwrap_or(""),
    @env.now().reinterpret_as_int64(),
  )
  let frame_count = parse_port(cli_arg(args, index + 3).unwrap_or("3"), 3)
  let prove_loop_now_ms = parse_ms(
    cli_arg(args, index + 3).unwrap_or(""),
    @env.now().reinterpret_as_int64(),
  )
  let proof_session_now_ms = parse_ms(
    cli_arg(args, index + 3).unwrap_or(""),
    @env.now().reinterpret_as_int64(),
  )
  let gateway_command_now_ms = parse_ms(
    cli_arg(args, index + 3).unwrap_or(""),
    @env.now().reinterpret_as_int64(),
  )
  let proof_session_iterations = parse_port(
    cli_arg(args, index + 4).unwrap_or("3"),
    3,
  )
  let session_id = cli_arg(args, index + 2).unwrap_or(
    "task-standing-goal-cli-observe",
  )
  let frame_id = cli_arg(args, index + 3).unwrap_or("sdk-e1-cli-frame")
  let annotation_id = cli_arg(args, index + 3).unwrap_or(
    "annotation-cli-\{session_id}",
  )
  let snapshot_path = cli_arg(args, index + 2).unwrap_or("")
  let feedback_snapshot_id = cli_arg(args, index + 2).unwrap_or("")
  let feedback_telemetry_path = cli_arg(args, index + 3).unwrap_or("")
  let proof_session_id = cli_arg(args, index + 2).unwrap_or("proof-session")
  let live_exercise_id = cli_arg(args, index + 2).unwrap_or("live-exercise")
  let api_method = cli_arg(args, index + 2).unwrap_or("GET")
  let api_path = cli_arg(args, index + 3).unwrap_or(@host_api.snapshot_path())
  let api_body = cli_arg(args, index + 4).unwrap_or("")
  let bridge_host = cli_arg(args, index + 4).unwrap_or("127.0.0.1")
  let bridge_port = parse_port(cli_arg(args, index + 5).unwrap_or("5391"), 5391)
  let bridge_execute_host = cli_arg(args, index + 3).unwrap_or("127.0.0.1")
  let bridge_execute_port = parse_port(
    cli_arg(args, index + 4).unwrap_or("5391"),
    5391,
  )
  let message_sidecar_host = cli_arg(args, index + 3).unwrap_or("127.0.0.1")
  let message_sidecar_port = parse_port(
    cli_arg(args, index + 4).unwrap_or("5391"),
    5391,
  )
  let runtime_health_host = cli_arg(args, index + 2).unwrap_or(
    @desktop_host.default_bridge_host(),
  )
  let runtime_health_port = parse_port(
    cli_arg(args, index + 3).unwrap_or(
      @desktop_host.default_bridge_port().to_string(),
    ),
    @desktop_host.default_bridge_port(),
  )
  let runtime_validation_host = cli_arg(args, index + 2).unwrap_or(
    @desktop_host.default_bridge_host(),
  )
  let runtime_validation_port = parse_port(
    cli_arg(args, index + 3).unwrap_or(
      @desktop_host.default_bridge_port().to_string(),
    ),
    @desktop_host.default_bridge_port(),
  )
  let runtime_validation_sample_count = parse_port(
    cli_arg(args, index + 4).unwrap_or("3"),
    3,
  )
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
  let serve_bridge_host = cli_arg(args, index + 5).unwrap_or(
    @desktop_host.default_bridge_host(),
  )
  let serve_bridge_port = cli_arg(args, index + 6).unwrap_or(
    @desktop_host.default_bridge_port().to_string(),
  )
  let project_bridge_host = cli_arg(args, index + 6).unwrap_or(
    @desktop_host.default_bridge_host(),
  )
  let project_bridge_port = cli_arg(args, index + 7).unwrap_or(
    @desktop_host.default_bridge_port().to_string(),
  )
  let bundle_bridge_host = cli_arg(args, index + 7).unwrap_or(
    @desktop_host.default_bridge_host(),
  )
  let bundle_bridge_port = cli_arg(args, index + 8).unwrap_or(
    @desktop_host.default_bridge_port().to_string(),
  )
  let desktop = desktop_config(
    root, ui_root, host, port, sidecar_path, project_bridge_host, project_bridge_port,
  )
  let serve_desktop = desktop_config(
    root,
    ui_root,
    host,
    port,
    @desktop_host.default_sidecar_path(),
    serve_bridge_host,
    serve_bridge_port,
  )
  let bundle_desktop = desktop_config(
    root, ui_root, host, port, sidecar_path, bundle_bridge_host, bundle_bridge_port,
  )
  match command {
    "build-design" => build_design(root, build_output_root)
    "validate-design" => validate_design(root)
    "inspect" => inspect(root)
    "mock" => mock(root)
    "cockpit" => cockpit(root)
    "cockpit-sdk-file" => cockpit_sdk_file(root, snapshot_path)
    "resident" => resident(root)
    "runtime-supervisor" => runtime_supervisor(root)
    "runtime-supervisor-script" => runtime_supervisor_script(root)
    "runtime-supervisor-launch" => runtime_supervisor_launch(root)
    "runtime-supervisor-status" => runtime_supervisor_status(root)
    "runtime-health" =>
      runtime_health(root, runtime_health_host, runtime_health_port)
    "runtime-validation" =>
      runtime_validation(root, runtime_validation_host, runtime_validation_port)
    "runtime-validation-session" =>
      runtime_validation_session(
        root, runtime_validation_host, runtime_validation_port, runtime_validation_sample_count,
      )
    "status" => product_status(root)
    "product-status" => product_status(root)
    "readiness" => readiness(root)
    "gateway-status" => gateway_status(root)
    "live-readiness" => live_readiness(root)
    "live-closure" => live_closure(root)
    "session" => robo_session(root)
    "loop-proof" => loop_proof(root)
    "bootstrap" => bootstrap(root)
    "runtime-supervisor-start" => runtime_supervisor_start(root)
    "runtime-supervisor-stop" => runtime_supervisor_stop(root)
    "moonclaw-context" => moonclaw_context(root)
    "gateway-command" =>
      gateway_command(root, task_message, gateway_command_now_ms)
    "prove-loop" => prove_loop(root, task_message, prove_loop_now_ms)
    "proof-session" =>
      proof_session(
        root, task_message, proof_session_now_ms, proof_session_iterations,
      )
    "proof-sessions" => proof_sessions(root)
    "proof-session-detail" => proof_session_detail(root, proof_session_id)
    "live-exercises" => live_exercises(root)
    "live-exercise-detail" => live_exercise_detail(root, live_exercise_id)
    "bind-feedback" =>
      bind_feedback(root, feedback_snapshot_id, feedback_telemetry_path)
    "resolve-review" => resolve_review(root, review_id, review_note)
    "moonstat" => moonstat(root)
    "memory" => memory(root)
    "remember" => remember(root)
    "handoff" => handoff(root)
    "platform-queue" => platform_queue(root)
    "task-status" => task_status(root, task_id)
    "tool-registry" => tool_registry(root)
    "register-tools" => register_tools(root)
    "episode" => episode(root, session_id)
    "episode-quality" => episode_quality(root, session_id)
    "message-task" => message_task(root, task_message)
    "ask" => ask(root, task_message, ask_now_ms)
    "loop" => robo_loop_cli(root, task_message, loop_now_ms)
    "loops" => loops(root)
    "loop-detail" => loop_detail(root, loop_id)
    "turn" => turn(root, task_message, turn_now_ms)
    "turns" => turns(root)
    "turn-detail" => turn_detail(root, turn_id)
    "message-sidecar" =>
      message_sidecar(
        root, task_message, message_sidecar_host, message_sidecar_port,
      )
    "observe-task" => observe_task(root, task_id)
    "observe-run" => observe_run(root, task_id, frame_count)
    "observe-run-sidecar" =>
      observe_run_sidecar(root, task_id, frame_count, bridge_host, bridge_port)
    "execute-message-sidecar" =>
      execute_message_sidecar(
        root, task_id, bridge_execute_host, bridge_execute_port,
      )
    "bridge-execute" =>
      bridge_execute(root, task_id, bridge_execute_host, bridge_execute_port)
    "replay" => replay(root, session_id)
    "annotate-replay" => annotate_replay(root, session_id, frame_id)
    "replay-annotations" => replay_annotations(root, session_id)
    "replay-annotation" => replay_annotation(root, session_id, annotation_id)
    "ingest-sdk-frame" => ingest_sdk_frame(root, session_id, frame_id)
    "api-snapshot" => api_snapshot(root)
    "api-health" => api_health(root)
    "api-route" => api_route(root, api_method, api_path, api_body)
    "serve" => serve(serve_desktop)
    "host-manifest" => host_manifest(serve_desktop)
    "desktop-project" => desktop_project(desktop)
    "desktop-bundle" => desktop_bundle(bundle_desktop, bundle_root)
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
