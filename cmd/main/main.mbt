///|
fn is_command(value : String) -> Bool {
  value == "inspect" ||
  value == "mock" ||
  value == "plan-walk" ||
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
  println("moon run cmd/main -- plan-walk [robotbook-root]")
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
fn main {
  let args = @sys.get_cli_args()
  let index = command_index(args)
  let command = cli_arg(args, index).unwrap_or("inspect")
  let root = cli_arg(args, index + 1).unwrap_or("examples/noetix-e1")
  match command {
    "inspect" => inspect(root)
    "mock" => mock(root)
    "plan-walk" => plan_walk(root)
    "help" => print_usage()
    _ => {
      println("unknown Moonrobo command: \{command}")
      print_usage()
    }
  }
}
