///|
/// Calibrated stick values, -1000..1000; positive x is right, y is down.
priv struct StickSample {
  captured_ms : Int64
  x : Int32
  y : Int32
  deadman : Bool
  exit : Bool
} derive(Debug, Eq, ToJson)

///|
priv struct NativeStickSample {
  captured_ms : Int64
  x : Int32
  y : Int32
  min_x : Int32
  max_x : Int32
  min_y : Int32
  max_y : Int32
  zl : Bool
  minus : Bool
} derive(FromJson)

///|
priv struct StickGate {
  mut ready : Bool
  mut active : Bool
  mut last_ms : Int64
}

///|
fn StickGate::new() -> StickGate {
  { ready: false, active: false, last_ms: -1L, }
}

///|
fn check_stick(sample : StickSample, now : Int64) -> Unit raise NeckError {
  guard sample.captured_ms <= now &&
    now - sample.captured_ms <= 150L &&
    sample.x >= -1000 &&
    sample.x <= 1000 &&
    sample.y >= -1000 &&
    sample.y <= 1000 else {
    raise Rejected(
      "Joystick sample stale, future-dated or outside calibrated range",
    )
  }
}

///|
fn StickGate::update(
  self : StickGate,
  sample : StickSample,
  now : Int64,
) -> Unit raise NeckError {
  check_stick(sample, now)
  guard self.last_ms < 0L || (now >= self.last_ms && now - self.last_ms <= 250L) else {
    raise Rejected(
      "Joystick control loop stalled; automatic catch-up forbidden",
    )
  }
  self.last_ms = now
  let neutral = sample.x.abs() <= 200 && sample.y.abs() <= 200
  if !sample.deadman {
    self.active = false
    self.ready = neutral
  } else if !self.active {
    self.active = self.ready && neutral
    self.ready = false
  }
}

///|
fn stick_speed(value : Int32) -> Int32 {
  if value.abs() <= 200 {
    return 0
  }
  let speed = Int32::max(1, (value.abs() - 200) * 20 / 800)
  if value < 0 {
    -speed
  } else {
    speed
  }
}

///|
fn calibrated_axis(
  value : Int32,
  minimum : Int32,
  maximum : Int32,
) -> Int32 raise NeckError {
  guard minimum >= -100000 &&
    maximum <= 100000 &&
    maximum - minimum >= 1000 &&
    value >= minimum &&
    value <= maximum else {
    raise Rejected("Invalid joystick kernel calibration")
  }
  (value - minimum) * 2000 / (maximum - minimum) - 1000
}

///|
fn read_stick(
  device : JoyDevice,
  diagnostic~ : Bool = false,
) -> StickSample raise {
  let raw = joy_read(device)
  guard raw.length() > 0 else {
    raise Transport(
      "Joy-Con input lost or stalled; no automatic reconnect: \{@utf8.decode_lossy(joy_error())}",
    )
  }
  let kernel_sample = @json.parse(@utf8.decode(raw))
  if diagnostic {
    println(
      (
        { "physical_execution": Json(false), "kernel_sample": kernel_sample } :
        Json).stringify(),
    )
  }
  let f : NativeStickSample = @json.from_json(kernel_sample)
  let sample : StickSample = {
    captured_ms: f.captured_ms,
    x: calibrated_axis(f.x, f.min_x, f.max_x),
    y: calibrated_axis(f.y, f.min_y, f.max_y),
    deadman: f.zl,
    exit: f.minus,
  }
  check_stick(sample, clock_ms())
  sample
}

///|
fn open_stick() -> JoyDevice raise NeckError {
  let device = joy_open()
  guard joy_valid(device) != 0 else {
    raise Transport(
      "Cannot open paired left Joy-Con: check Bluetooth, input permissions and competing readers",
    )
  }
  // Match the installed XLeRobot Joy-Con input initialization. The only HID
  // outputs are sensor enable, full report mode and one steady player LED.
  // These are controller input setup, never robot servo commands.
  for (sequence, command, value) in [(0, 0x40, 1), (1, 3, 0x30), (2, 0x30, 1)] {
    let packet : Bytes = [
      1,
      sequence.to_byte(),
      0,
      1,
      0x40,
      0x40,
      0,
      1,
      0x40,
      0x40,
      command.to_byte(),
      value.to_byte(),
    ]
    if command == 0x30 {
      // A concurrent kernel LED request may consume its LED acknowledgement.
      // This cosmetic operation is not evidence that input reporting works.
      guard joy_write_setup(device, packet) == 0 else {
        joy_close(device)
        raise Transport("Joy-Con player LED setup failed")
      }
    } else {
      let reply = joy_setup_reply(device, packet)
      validate_stick_setup_reply(reply, command) catch {
        err => {
          joy_close(device)
          raise err
        }
      }
    }
    sleep_ms(20)
  }
  device
}

///|
fn validate_stick_setup_reply(
  reply : Bytes,
  command : Int32,
) -> Unit raise NeckError {
  guard reply.length() >= 15 &&
    reply[0] == 0x21 &&
    (reply[13].to_int() & 0x80) != 0 &&
    reply[14].to_int() == command else {
    raise Transport("Joy-Con input setup acknowledgement missing or rejected")
  }
}

///|
/// Reads Joy-Con input only. Does not open the servo adapter or enable motors.
/// Minus ends the monitor early. Only this read-only monitor may wait/reopen
/// input after a connection failure. Physical sessions always fault instead.
pub fn monitor_joystick(seconds : Int32) -> Unit raise {
  validate_action(Joystick(seconds))
  let mut device : JoyDevice? = None
  defer (if device is Some(d) { joy_close(d) })
  let end = clock_ms() + seconds.to_int64() * 1000L
  let mut gate = StickGate::new()
  let mut last : (Int32, Int32, Bool, Bool)? = None
  let mut last_printed = 0L
  let mut waiting : String? = None
  while clock_ms() < end {
    let sample = try {
      if device is None {
        device = Some(open_stick())
      }
      let sample = read_stick(device.unwrap(), diagnostic=last is None)
      gate.update(sample, clock_ms())
      sample
    } catch {
      err => {
        let message = "\{Repr(err)}"
        if waiting != Some(message) {
          println(
            (
              {
                "physical_execution": Json(false),
                "waiting_for_input": Json(message),
              } : Json).stringify(),
          )
          waiting = Some(message)
        }
        if device is Some(d) {
          joy_close(d)
        }
        device = None
        gate = StickGate::new()
        last = None
        sleep_ms(200)
        continue
      }
    }
    waiting = None
    let value = (sample.x / 50, sample.y / 50, sample.deadman, gate.active)
    if last != Some(value) || sample.exit || clock_ms() - last_printed >= 1000L {
      println(
        (
          {
            "physical_execution": Json(false),
            "sample": Json(sample),
            "armed_input": Json(gate.active),
          } : Json).stringify(),
      )
      last = Some(value)
      last_printed = clock_ms()
    }
    if sample.exit {
      break
    }
    sleep_ms(50)
  }
}

///|
fn[B : Bus] run_joystick(bus : B, seconds : Int32) -> Report raise {
  validate_action(Joystick(seconds))
  for id in [7, 8] {
    validate_identity(id, bus.transfer(id, 2, [0, 34], 34, 0L))
  }
  let guards = [Guard::new(7), Guard::new(8)]
  let before = guards.map(g => observe(bus, g.id))
  for i in 0..<2 {
    guards[i].check_feedback(before[i], bus.now())
  }
  let gate = StickGate::new()
  let end = bus.now() + seconds.to_int64() * 1000L
  let mut prepared = false
  let mut was_active = false
  while bus.now() < end {
    guard interrupted() == 0 else {
      raise Rejected("Joystick interrupted; no automatic resume")
    }
    let sample = bus.stick()
    if bus.now() >= end {
      break
    }
    gate.update(sample, bus.now())
    if sample.exit {
      break
    }
    if gate.active != was_active {
      bus.event("joystick-enable", {
        "active": Json(gate.active),
        "sample": Json(sample),
      })
      was_active = gate.active
    }
    if gate.active && !prepared {
      // The operator may have idled here for minutes. Validate BOTH fresh
      // axes again before the first preparation write to either motor.
      for g in guards {
        g.check_feedback(observe(bus, g.id), bus.now())
      }
      bus.require_stick()
      for g in guards {
        for
          command in [
            TorqueLimit,
            SpeedLimit,
            Acceleration,
            LatchPresent,
            Enable,
          ] {
          check_active_axes(bus, guards)
          apply(bus, g, command, input_deadline=end)
        }
      }
      prepared = true
      // Preparation can take time. Re-read input instead of using its old stick
      // direction or accumulating time spent arming as movement credit.
      gate.last_ms = bus.now()
      bus.wait(50)
      continue
    }
    if prepared {
      check_active_axes(bus, guards)
      if gate.active {
        for
          (i, speed) in [(0, stick_speed(sample.x)), (1, stick_speed(sample.y))] {
          let g = guards[i]
          if speed != 0 &&
            bus.now() - g.last_step_ms >= (1000 / speed.abs()).to_int64() {
            let next = g.last_goal + (if speed > 0 { 1 } else { -1 })
            // Velocity input stops at the commissioned boundary. Never expand
            // the envelope, wrap, reset zero or queue a destination beyond it.
            if inside(g.id, next) {
              check_stick(sample, bus.now())
              check_active_axes(bus, guards)
              bus.event("joystick-step", {
                "id": Json(g.id),
                "goal": Json(next),
                "sample": Json(sample),
              })
              apply(
                bus,
                g,
                Step(next),
                input_deadline=Int64::min(sample.captured_ms + 150L, end),
              )
            }
          }
        }
      }
    }
    bus.wait(50)
  }
  let after = guards.map(g => observe(bus, g.id))
  if prepared {
    for i in 0..<2 {
      guards[i].check_feedback(after[i], bus.now())
    }
  }
  let report = {
    action: Joystick(seconds),
    completed: true,
    holding: prepared,
    before,
    after,
  }
  bus.event("completed-holding-no-cleanup-writes", Json(report))
  report
}
