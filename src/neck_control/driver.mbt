///|
priv trait Bus {
  fn transfer(Self, Int32, Int32, Array[Byte], Int32, Int64) -> Bytes raise
  fn now(Self) -> Int64
  fn wait(Self, Int32) -> Unit
  fn event(Self, String, Json) -> Unit raise
  fn stick(Self) -> StickSample raise
  fn require_stick(Self) -> Unit
}

///|
priv struct Serial {
  fd : Int32
  log_path : String
  run_id : String
  mut sequence : Int32
  mut writes : Int32
  joystick : JoyDevice?
  mut stick_required : Bool
}

///|
impl Bus for Serial with fn stick(self) {
  read_stick(self.joystick.unwrap())
}

///|
impl Bus for Serial with fn require_stick(self) {
  self.stick_required = true
}

///|
impl Bus for Serial with fn now(_) {
  clock_ms()
}

///|
impl Bus for Serial with fn wait(_, ms) {
  sleep_ms(ms)
}

///|
impl Bus for Serial with fn event(self, name, detail) {
  self.sequence += 1
  let line : Json = {
    "run_id": Json(self.run_id),
    "sequence": Json(self.sequence),
    "epoch_ms": Json(epoch_ms()),
    "monotonic_ms": Json(clock_ms()),
    "event": Json(name),
    "detail": detail,
  }
  guard audit_append(
      @utf8.encode(self.log_path),
      @utf8.encode(line.stringify()),
    ) ==
    0 else {
    raise Transport(
      "Audit persistence failed: \{@utf8.decode_lossy(native_error())}",
    )
  }
}

///|
impl Bus for Serial with fn transfer(
  self,
  id,
  instruction,
  params,
  count,
  expires_at,
) {
  guard (id == 7 || id == 8) && (instruction == 2 || instruction == 3) else {
    raise Rejected("Unknown ID, broadcast or unsupported instruction")
  }
  if instruction == 3 {
    let permitted = match params {
      [40, 0] => true
      [40, 1] | [41, 3] | [46, 20, 0] | [48, 44, 1] => expires_at > 0L
      [42, low, high] =>
        expires_at > 0L && inside(id, low.to_int() + (high.to_int() << 8))
      _ => false
    }
    guard permitted else {
      raise Rejected("Raw write rejected by transport whitelist")
    }
  }
  let input_expires = if instruction == 3 && self.stick_required {
    let sample = read_stick(self.joystick.unwrap())
    guard sample.deadman && !sample.exit else {
      raise Rejected(
        "Joystick released during dispatch; session stopped without a cleanup write",
      )
    }
    sample.captured_ms + 150L
  } else {
    0L
  }
  let expires_at = if input_expires > 0L {
    Int64::min(expires_at, input_expires)
  } else {
    expires_at
  }
  let tx = request_packet(id, instruction, params)
  self.event("tx-before-send", {
    "id": Json(id),
    "instruction": Json(instruction),
    "parameters": Json(params.map(b => b.to_int())),
    "packet_hex": Json(@hex.encode(tx)),
  })
  if instruction == 3 {
    self.writes += 1
  }
  // Recheck after fsync, immediately before dispatch. A slow audit disk must
  // never turn a fresh authorized sample into a delayed movement command.
  guard expires_at == 0L || clock_ms() <= expires_at else {
    raise Rejected("Feedback expired while persisting command audit")
  }
  let raw = if instruction == 3 && self.stick_required {
    serial_exchange_guarded(
      self.fd,
      tx,
      count + 6,
      expires_at,
      joy_event_fd(self.joystick.unwrap()),
    )
  } else {
    serial_exchange(self.fd, tx, count + 6, expires_at)
  }
  self.event("rx", {
    "id": Json(id),
    "packet_hex": Json(@hex.encode(raw)),
    "transport_error": Json(@utf8.decode_lossy(native_error())),
  })
  response_payload(raw, id, count)
}

///|
fn[B : Bus] observe(bus : B, id : Int32) -> Feedback raise {
  // Timestamp before the request, not after: a delayed response is not fresh.
  let captured = bus.now()
  let data = bus.transfer(id, 2, [33, 38], 38, 0L)
  let frame = decode_feedback(id, data, captured)
  bus.event("feedback", Json(frame))
  frame
}

///|
fn[B : Bus] apply(
  bus : B,
  guard_state : Guard,
  command : Write,
  input_deadline~ : Int64 = 0L,
) -> Unit raise {
  if interrupted() != 0 && command != ReleaseTorque {
    raise Rejected("Operator interrupt; no more position writes")
  }
  let f = observe(bus, guard_state.id)
  guard_state.authorize(f, command, bus.now())
  bus.event("authorized-write", {
    "id": Json(guard_state.id),
    "operation": Json("\{Repr(command)}"),
    "feedback": Json(f),
  })
  bus.transfer(
    guard_state.id,
    3,
    write_parameters(command, f),
    0,
    if command == ReleaseTorque {
      0L
    } else if input_deadline > 0L {
      Int64::min(f.captured_ms + 150L, input_deadline)
    } else {
      f.captured_ms + 150L
    },
  )
  |> ignore
}

///|
fn[B : Bus] check_active_axes(bus : B, guards : Array[Guard]) -> Unit raise {
  for g in guards {
    if g.phase is (Armed | Latched) {
      g.check_feedback(observe(bus, g.id), bus.now())
    }
  }
}

///|
pub(all) struct Report {
  action : Action
  completed : Bool
  holding : Bool
  before : Array[Feedback]
  after : Array[Feedback]
} derive(Debug, ToJson)

///|
fn[B : Bus] run_action(bus : B, action : Action) -> Report raise {
  bus.event("request", Json(action))
  if action is Joystick(seconds) {
    return run_joystick(bus, seconds)
  }
  if action == Release {
    // Emergency release must not depend on a successful identity/telemetry
    // read from an alarming motor. These are the last WRITE operations.
    let mut failed = false
    for id in [7, 8] {
      try bus.transfer(id, 3, [40, 0], 0, 0L) catch {
        _ => failed = true
      } noraise {
        _ => ()
      }
    }
    guard !failed else {
      raise Transport("Torque-off requested for both axes; confirmation failed")
    }
    let after = [observe(bus, 7), observe(bus, 8)]
    guard after.all(f => f.torque == 0) else {
      raise Rejected("Torque-off readback mismatch")
    }
    return { action, completed: true, holding: false, before: [], after, }
  }
  for id in [7, 8] {
    validate_identity(id, bus.transfer(id, 2, [0, 34], 34, 0L))
  }
  let guards = [Guard::new(7), Guard::new(8)]
  let before = guards.map(g => observe(bus, g.id))
  if action == Status {
    return {
      action,
      completed: true,
      holding: before.all(f => {
        f.torque == 1 &&
        f.velocity.abs() <= 3 &&
        f.status == 0 &&
        inside(f.id, f.goal) &&
        (f.goal - f.position).abs() <= 11 &&
        f.speed_limit == 20 &&
        f.torque_limit == 300 &&
        f.acceleration == 3 &&
        bus.now() - f.captured_ms <= 150L
      }),
      before,
      after: before,
    }
  }
  let targets = before.map(f => target(action, f.id, f.position))
  // Validate both axes before configuring either; one bad axis denies the pair.
  for i in 0..<2 {
    guards[i].check_feedback(before[i], bus.now())
  }
  for g in guards {
    for command in [TorqueLimit, SpeedLimit, Acceleration, LatchPresent, Enable] {
      check_active_axes(bus, guards)
      apply(bus, g, command)
    }
  }
  if action == Hold {
    // Hold the latest latched pose, not an earlier preflight reading.
    for i in 0..<2 {
      targets[i] = guards[i].last_goal
    }
  }
  for i in 0..<2 {
    let g = guards[i]
    let desired = targets[i]
    for _ in 0..<120 {
      if g.last_goal == desired {
        break
      }
      bus.wait(50)
      let next = g.last_goal + (if desired > g.last_goal { 1 } else { -1 })
      check_active_axes(bus, guards)
      apply(bus, g, Step(next))
    }
    guard g.last_goal == desired else {
      raise Rejected("Bounded movement step count exceeded")
    }
    let mut settled = 0
    for _ in 0..<40 {
      bus.wait(50)
      let f = observe(bus, g.id)
      check_active_axes(bus, guards)
      g.check_feedback(f, bus.now())
      if (f.position - desired).abs() <= 11 && f.velocity.abs() <= 3 {
        settled += 1
      } else {
        settled = 0
      }
      if settled >= 3 {
        break
      }
    }
    guard settled >= 3 else {
      raise Rejected("Target did not settle; fault latched")
    }
  }
  let after = guards.map(g => observe(bus, g.id))
  for i in 0..<2 {
    guards[i].check_feedback(after[i], bus.now())
  }
  let report = { action, completed: true, holding: true, before, after, }
  bus.event("completed-holding-no-cleanup-writes", Json(report))
  // No register restoration and no hidden torque-off on success or close.
  report
}

///|
pub fn execute(
  action : Action,
  receipt : @core.RunReceipt?,
  log_path : String,
) -> Report raise {
  guard log_path.has_prefix("/") && !log_path.contains("\u{0}") else {
    raise Rejected("Audit path must be absolute")
  }
  let audit : Serial = {
    fd: -1,
    log_path,
    run_id: "\{epoch_ms()}-\{clock_ms()}",
    sequence: 0,
    writes: 0,
    joystick: None,
    stick_required: false,
  }
  audit.event("request-received", Json(action))
  try {
    if action != Status {
      guard receipt is Some(ready) else {
        raise Rejected("Motion needs an approved MoonRobo execution receipt")
      }
      validate_receipt(ready, action, epoch_ms())
    }
  } catch {
    err => {
      audit.event("denied-before-port-open", Json("\{Repr(err)}"))
      raise err
    }
  }
  let fault_path = "/home/elf/moonrobo-neck/inflight-or-fault"
  guard action is (Status | Release) ||
    fault_exists(@utf8.encode(fault_path)) == 0 else {
    audit.event("denied-persistent-fault", Json(fault_path))
    raise Rejected(
      "Persistent fault latch exists; operator review required, no automatic re-arm",
    )
  }
  let device = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5AB0182917-if00"
  let joystick = if action is Joystick(_) { Some(open_stick()) } else { None }
  defer (if joystick is Some(stick) { joy_close(stick) })
  let fd = serial_open(@utf8.encode(device))
  guard fd >= 0 else {
    let reason = @utf8.decode_lossy(native_error())
    audit.event("port-open-failed", Json(reason))
    raise Transport(reason)
  }
  defer serial_close(fd)
  let bus : Serial = {
    fd,
    log_path,
    run_id: audit.run_id,
    sequence: audit.sequence,
    writes: 0,
    joystick,
    stick_required: false,
  }
  bus.event("opened-exclusive", {
    "device": Json(device),
    "action": Json(action),
  })
  try {
    if action != Status {
      guard latch_fault(@utf8.encode(fault_path)) == 0 else {
        raise Transport("Cannot persist pre-actuation crash/fault marker")
      }
      let ready = receipt.unwrap()
      let used = "/home/elf/moonrobo-neck/used-" +
        @hex.encode(@utf8.encode(ready.intent.intent_id))
      guard consume_receipt(@utf8.encode(used)) == 0 else {
        raise Rejected(
          "Execution intent already used or receipt journal unavailable",
        )
      }
    }
    let report = run_action(bus, action)
    guard action == Status || interrupted() == 0 else {
      raise Rejected("Interrupted; fault marker retained, no automatic resume")
    }
    if action != Status && action != Release {
      guard clear_fault(@utf8.encode(fault_path)) == 0 else {
        raise Transport("Completed but crash/fault marker could not be cleared")
      }
    }
    report
  } catch {
    err => {
      bus.event("fault", Json("\{Repr(err)}")) catch {
        _ => ()
      }
      if bus.writes > 0 {
        latch_fault(@utf8.encode(fault_path)) |> ignore
        // No actuator cleanup on faults. In particular, do not drop a loaded
        // camera by releasing torque, or replay any old goal/profile. The last
        // bounded target remains in the servo; explicit Release is separate.
      }
      raise err
    }
  }
}
