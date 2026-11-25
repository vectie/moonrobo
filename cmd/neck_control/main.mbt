///|
fn action_from_args(args : Array[String]) -> @neck.Action raise {
  let name = args.get(2).unwrap_or("hold")
  match name {
    "hold" => Hold
    "center" => Center
    "release" => Release
    "joystick" => Joystick(@string.parse_int(args.get(3).unwrap_or("120")))
    "left" | "up" | "right" | "down" => {
      let degrees = @string.parse_int(args.get(3).unwrap_or("1"))
      let direction = match name {
        "left" => @neck.Left
        "up" => @neck.Up
        "right" => @neck.Right
        _ => @neck.Down
      }
      Jog(direction, degrees)
    }
    _ =>
      abort("Expected hold, center, release, left, up, right, down or joystick")
  }
}

///|
fn run_cli() -> Unit raise {
  let args = @env.args()
  let command = args.get(1).unwrap_or("status")
  match command {
    "status" => {
      let log = args
        .get(2)
        .unwrap_or("/home/elf/moonrobo-neck/neck-audit.jsonl")
      println(Json(@neck.execute(Status, None, log)).stringify(indent=2))
    }
    "preflight" => {
      // Timestamp before any UART requests. A remote gate can conservatively
      // age this read-only observation without counting SSH process startup.
      let started_epoch_ms = @neck.epoch_ms()
      let report = @neck.execute(
        Status,
        None,
        "/home/elf/moonrobo-neck/neck-audit.jsonl",
      )
      println(
        (
          {
            "started_epoch_ms": Json(started_epoch_ms),
            "finished_epoch_ms": Json(@neck.epoch_ms()),
            "report": Json(report),
          } : Json).stringify(indent=2),
      )
    }
    "joystick-monitor" =>
      @neck.monitor_joystick(@string.parse_int(args.get(2).unwrap_or("30")))
    "simulate" =>
      println(Json(@neck.simulate(action_from_args(args))).stringify(indent=2))
    "plan" => {
      let action = action_from_args(args)
      let simulation = @neck.simulate(action)
      let p = @neck.profile()
      let intent = @core.command_intent(
        "neck-\{@neck.epoch_ms()}",
        p.id,
        "control.low.neck",
        @core.operator_requester("neck-cli"),
        parameters={ "action": Json(action).stringify() },
      )
      println(
        (
          {
            "physical_execution": Json(false),
            "profile": Json(p),
            "intent": Json(intent),
            "simulation": Json(simulation),
          } : Json).stringify(indent=2),
      )
    }
    "execute" => {
      guard args.length() == 4 else {
        abort(
          "Usage: neck_control execute APPROVED_READY_RECEIPT.json /absolute/audit.jsonl",
        )
      }
      let receipt : @core.RunReceipt = @json.from_json(
        @json.parse(@fs.read_file_to_string(args[2])),
      )
      let action : @neck.Action = @json.from_json(
        @json.parse(receipt.intent.parameters.get("action").unwrap_or("null")),
      )
      println(
        Json(@neck.execute(action, Some(receipt), args[3])).stringify(indent=2),
      )
    }
    _ =>
      abort(
        "Usage: neck_control status [AUDIT] | preflight | joystick-monitor [SECONDS] | simulate|plan DIRECTION [1..5] | simulate|plan joystick [1..300 seconds] | execute RECEIPT AUDIT",
      )
  }
}

///|
fn main {
  run_cli() catch {
    err => {
      println("Neck controller stopped: \{Repr(err)}")
      exit_process(1)
    }
  }
}

///|
extern "c" fn exit_process(code : Int32) -> Unit = "exit"
