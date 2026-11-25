///|
#derive(Debug)
pub suberror NeckError {
  Rejected(String)
  Transport(String)
}

///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) enum Direction {
  Left
  Up
  Right
  Down
}

///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) enum Action {
  Status
  Hold
  Jog(Direction, Int32)
  Center
  Release
  Joystick(Int32)
  Buttons(Int32)
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct Feedback {
  id : Int32
  captured_ms : Int64
  mode : Int32
  torque : Int32
  acceleration : Int32
  goal : Int32
  goal_time : Int32
  speed_limit : Int32
  torque_limit : Int32
  position : Int32
  velocity : Int32
  load : Int32
  voltage_tenths : Int32
  temperature : Int32
  current_raw : Int32
  status : Int32
}

///|
// A register operation is internal. There is deliberately no bulk-restore,
// arbitrary-address write, factory-reset, or EEPROM-write operation.
#derive(Debug, Eq)
priv enum Write {
  TorqueLimit
  SpeedLimit
  Acceleration
  LatchPresent
  Enable
  Step(Int32)
  ReleaseTorque
}

///|
#derive(Debug, Eq)
priv enum Phase {
  Observed
  Latched
  Armed
  Released
  Faulted
}

///|
priv struct Guard {
  id : Int32
  mut phase : Phase
  mut last_goal : Int32
  mut last_step_ms : Int64
}

///|
fn home(id : Int32) -> Int32 raise NeckError {
  match id {
    7 => 1927
    8 => 2047
    _ => raise Rejected("Only neck IDs 7 and 8 are permitted")
  }
}

///|
fn inside(id : Int32, position : Int32) -> Bool {
  match id {
    7 => position >= 1813 && position <= 2041
    8 => position >= 1933 && position <= 2161
    _ => false
  }
}

///|
fn Guard::new(id : Int32) -> Guard raise NeckError {
  { id, phase: Observed, last_goal: home(id), last_step_ms: 0L, }
}

///|
fn Guard::reject(self : Guard, reason : String) -> Unit raise NeckError {
  self.phase = Faulted
  raise Rejected(reason)
}

///|
fn Guard::check_feedback(
  self : Guard,
  f : Feedback,
  now : Int64,
) -> Unit raise NeckError {
  guard f.id == self.id else {
    self.reject("Motor ID mismatch")
    return
  }
  guard now >= f.captured_ms && now - f.captured_ms <= 150L else {
    self.reject("Feedback stale or from the future")
    return
  }
  guard f.mode == 0 && f.status == 0 else {
    self.reject("Wrong mode or servo alarm")
    return
  }
  guard inside(self.id, f.position) else {
    self.reject("Measured position outside reviewed ten-degree test envelope")
    return
  }
  guard f.voltage_tenths >= 105 &&
    f.voltage_tenths <= 140 &&
    f.temperature < 55 &&
    f.load.abs() < 250 &&
    f.current_raw.abs() < 200 &&
    f.velocity.abs() <= 100 else {
    self.reject("Electrical, temperature, load or velocity limit")
    return
  }
  if self.phase is (Armed | Latched) {
    guard f.goal == self.last_goal && (f.goal - f.position).abs() <= 16 else {
      self.reject("Target changed externally or tracking error")
      return
    }
    guard f.speed_limit == 50 &&
      f.torque_limit == 300 &&
      f.acceleration == 3 &&
      f.goal_time == 0 else {
      self.reject("Motion profile changed or reset")
      return
    }
    if self.phase == Armed && f.torque != 1 {
      self.reject("Unexpected torque change; automatic re-arm forbidden")
    }
  }
}

///|
fn Guard::authorize(
  self : Guard,
  f : Feedback,
  command : Write,
  now : Int64,
) -> Unit raise NeckError {
  // Release is terminal, with no later goal/profile writes, including cleanup.
  if command == ReleaseTorque {
    self.phase = Released
    return
  }
  guard self.phase != Released && self.phase != Faulted else {
    self.reject("Session is released or faulted; writes are latched off")
    return
  }
  self.check_feedback(f, now)
  match command {
    TorqueLimit | SpeedLimit | Acceleration => {
      guard self.phase == Observed else {
        self.reject("Profile writes only during preparation")
        return
      }
      guard f.torque == 0 ||
        (inside(self.id, f.goal) && (f.goal - f.position).abs() <= 16) else {
        self.reject("Already energized with unsafe old goal")
        return
      }
    }
    LatchPresent => {
      guard self.phase == Observed &&
        f.speed_limit == 50 &&
        f.torque_limit == 300 &&
        f.acceleration == 3 &&
        f.goal_time == 0 else {
        self.reject("Bounded profile must be verified BEFORE latching position")
        return
      }
      self.last_goal = f.position
      self.last_step_ms = now
      // A position write may energize the servo even without Enable.
      self.phase = Latched
    }
    Enable => {
      guard self.phase == Latched && (f.goal - f.position).abs() <= 2 else {
        self.reject("Enable requires verified current-position latch")
        return
      }
      self.phase = Armed
    }
    Step(target) => {
      guard self.phase == Armed && inside(self.id, target) && target > 0 else {
        self.reject("Unarmed or out-of-envelope position target")
        return
      }
      guard now - self.last_step_ms >= 50L &&
        (target - self.last_goal).abs() <= 1 else {
        self.reject("One encoder tick per 50 ms maximum; large jumps forbidden")
        return
      }
      self.last_goal = target
      self.last_step_ms = now
    }
    ReleaseTorque => ()
  }
}

///|
fn write_parameters(command : Write, f : Feedback) -> Array[Byte] {
  match command {
    TorqueLimit => [48, 44, 1]
    SpeedLimit => [46, 50, 0]
    Acceleration => [41, 3]
    LatchPresent =>
      [42, (f.position & 255).to_byte(), (f.position >> 8).to_byte()]
    Enable => [40, 1]
    Step(target) => [42, (target & 255).to_byte(), (target >> 8).to_byte()]
    ReleaseTorque => [40, 0]
  }
}

///|
pub fn target(
  action : Action,
  id : Int32,
  start : Int32,
) -> Int32 raise NeckError {
  validate_action(action)
  guard inside(id, start) else {
    raise Rejected("Starting pose outside commissioned envelope")
  }
  let result = match action {
    Jog(direction, degrees) => {
      let ticks = (degrees * 4096 + 180) / 360
      match (direction, id) {
        (Left, 7) | (Up, 8) => start - ticks
        (Right, 7) | (Down, 8) => start + ticks
        _ => start
      }
    }
    Center => home(id)
    _ => start
  }
  guard inside(id, result) else {
    raise Rejected(
      "Target outside reviewed ten-degree test envelope; no clipping or automatic re-zero",
    )
  }
  result
}

///|
pub fn profile() -> @core.RobotProfile {
  let base = @core.noetix_e1_profile("noetix-e1-neck", "elf2-neck-usb")
  {
    ..base,
    label: "E1 external STS3215 neck reviewed ten-degree profile",
    profile_version: 4,
    bridge: {
      id: "elf2-neck-usb",
      kind: UnknownBridge("feetech-neck"),
      config_path: "docs/E1_NECK_CONTROL.md",
    },
    platform: "elf2-rk3588-usb-sts3215",
    joints: [
      @core.joint("neck.pan", 7, min_position=-10.0, max_position=10.0),
      @core.joint("neck.tilt", 8, min_position=-10.0, max_position=10.0),
    ],
    sensors: [@core.sensor("neck.camera", "rgb", "RealSense D455")],
    limits: { ..base.limits, telemetry_freshness_ms: 150, },
    capabilities: [
      @core.capability("observe.neck", Observe, "Read neck telemetry"),
      @core.capability(
        "control.low.neck",
        LowControl,
        "Bounded neck motion",
        requires_approval=true,
        requires_dry_run=true,
      ),
    ],
  }
}

///|
pub fn validate_receipt(
  receipt : @core.RunReceipt,
  action : Action,
  now_ms : Int64,
) -> Unit raise NeckError {
  validate_action(action)
  guard @utf8.encode(receipt.intent.intent_id).length() > 0 &&
    @utf8.encode(receipt.intent.intent_id).length() <= 80 else {
    raise Rejected("Intent ID length is invalid for durable replay protection")
  }
  guard receipt.robot_id == "noetix-e1-neck" &&
    receipt.bridge_id == "elf2-neck-usb" &&
    receipt.intent.robot_id == receipt.robot_id else {
    raise Rejected("Receipt robot/bridge mismatch")
  }
  guard receipt.verdict.decision == Allow &&
    receipt.verdict.robot_id == receipt.robot_id &&
    receipt.verdict.intent_id == receipt.intent.intent_id &&
    receipt.verdict.capability == "control.low.neck" &&
    receipt.intent.capability == "control.low.neck" &&
    receipt.status == ReadyForExecution else {
    raise Rejected("A ready-for-execution MoonRobo safety receipt is required")
  }
  guard now_ms >= receipt.started_at_ms &&
    now_ms - receipt.started_at_ms <= 60_000L else {
    raise Rejected("Execution receipt expired or from the future")
  }
  guard receipt.intent.parameters == intent_parameters(action) else {
    raise Rejected("Receipt does not match the exact action and neck profile")
  }
}

///|
pub fn intent_parameters(
  action : Action,
) -> Map[String, String] raise NeckError {
  validate_action(action)
  {
    "action": Json(action).stringify(),
    "neck_profile_version": "4",
    "neck_travel_limit_degrees": "10",
    "raw_feedback_velocity_limit": "100",
    "servo_speed_limit": "50",
  }
}

///|
fn validate_action(action : Action) -> Unit raise NeckError {
  if action is Jog(_, degrees) {
    guard degrees >= 1 && degrees <= 10 else {
      raise Rejected("Jog requires integer degrees from 1 to 10")
    }
  }
  if action is (Joystick(seconds) | Buttons(seconds)) {
    guard seconds >= 1 && seconds <= 300 else {
      raise Rejected("Live input sessions must last 1..300 seconds")
    }
  }
}
