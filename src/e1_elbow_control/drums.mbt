///|
pub const RIGHT_ELBOW_SLOT : Int32 = 14

///|
/// Four alternating 12-second strokes, with a 10-degree fold per stroke.
pub const DRUM_FRAMES : Int32 = 2401

///|
pub fn drum_offsets(frame : Int32) -> (Double, Double) raise {
  guard frame >= 0 && frame < DRUM_FRAMES else {
    fail("drum frame outside reference")
  }
  if frame == DRUM_FRAMES - 1 {
    return (0.0, 0.0)
  }
  let stroke = frame / 600
  let offset = fold_offset(-10.0, frame % 600, frames=601)
  if stroke % 2 == 0 {
    (offset, 0.0)
  } else {
    (0.0, offset)
  }
}

///|
/// Suspended dual-elbow owner. The other 22 command records remain fixed.
pub struct DrumPath {
  priv hold : Array[@low.MotorCommand]
  priv targets : Array[(Double, Double)]
  priv paced : Bool
  priv mut step : Int32
  priv mut tick : Int32
  priv mut start_ms : Int64
  priv mut previous_ms : Int64
  priv mut previous_source : Int64
  priv mut previous_receipt : Int64
  priv mut previous_left : Double
  priv mut previous_right : Double
  priv mut stopped : Bool
}

///|
pub fn DrumPath::new(hold : ArrayView[@low.MotorCommand]) -> DrumPath raise {
  guard hold.length() == 24 else { fail("24-slot drum hold required") }
  let targets = Array::makei(DRUM_FRAMES, i => {
    let (left, right) = drum_offsets(i)
    (hold[3].position + left * RAD, hold[14].position + right * RAD)
  })
  drum_path(hold, targets, false)
}

///|
fn drum_path(
  hold : ArrayView[@low.MotorCommand],
  targets : Array[(Double, Double)],
  paced : Bool,
) -> DrumPath raise {
  guard hold.length() == 24 else { fail("24-slot drum hold required") }
  for m in hold {
    guard finite(m.position) &&
      m.velocity == 0.0 &&
      m.torque == 0.0 &&
      finite(m.kp) &&
      m.kp >= 0.0 &&
      finite(m.kd) &&
      m.kd >= 0.0 else {
      fail("invalid drum hold")
    }
  }
  guard hold[3].kp > 0.0 && hold[14].kp > 0.0 && targets.length() > 0 else {
    fail("drum elbows require position gain and a reference")
  }
  // Intersection of the SDK [-130,10] degree range and model [-2.44,0].
  for (left, right) in targets {
    guard finite(left) &&
      finite(right) &&
      left >= -130.0 * RAD &&
      left <= 0.0 &&
      right >= -130.0 * RAD &&
      right <= 0.0 else {
      fail("drum stroke outside elbow range")
    }
  }
  {
    hold: hold.to_owned(),
    targets,
    paced,
    step: 0,
    tick: 0,
    start_ms: 0L,
    previous_ms: 0L,
    previous_source: 0L,
    previous_receipt: 0L,
    previous_left: hold[ELBOW_SLOT].position,
    previous_right: hold[RIGHT_ELBOW_SLOT].position,
    stopped: false,
  }
}

///|
pub fn DrumPath::next(
  self : DrumPath,
  s : Sample,
  now_ms : Int64,
) -> Array[@low.MotorCommand] raise {
  guard !self.stopped else { fail("drum path stopped") }
  self.stopped = true
  guard now_ms >= s.receipt_ms &&
    s.receipt_ms >= 0L &&
    now_ms - s.receipt_ms <= 40L &&
    s.source_ns > 0L &&
    s.motors.length() == 24 else {
    fail("invalid or stale drum telemetry")
  }
  for slot, motor in s.motors {
    guard motor.id == slot &&
      motor.error == 0 &&
      finite(motor.position) &&
      finite(motor.velocity) else {
      fail("invalid drum motor at slot " + slot.to_string())
    }
    if leg_slot(slot) && !leg_position_in_range(slot, motor.position) {
      fail("drum leg feedback outside SDK range")
    }
  }
  if self.tick == 0 {
    for slot in [ELBOW_SLOT, RIGHT_ELBOW_SLOT] {
      let initial_tolerance = if self.paced { 5.0 * RAD } else { RAD }
      guard (s.motors[slot].position - self.hold[slot].position).abs() <=
        initial_tolerance else {
        fail("drum starting hold disagrees with telemetry")
      }
    }
    self.start_ms = now_ms
  } else {
    let elapsed = now_ms - self.start_ms
    let scheduled = self.tick.to_int64() * 20L
    let interval = now_ms - self.previous_ms
    let timing_ok = if self.paced {
      interval >= 20L && interval <= 40L
    } else {
      interval >= 10L &&
      interval <= 30L &&
      elapsed >= scheduled - 10L &&
      elapsed <= scheduled + 10L
    }
    guard s.source_ns > self.previous_source &&
      s.source_ns - self.previous_source <= 40000000L &&
      s.receipt_ms > self.previous_receipt &&
      timing_ok else {
      fail("drum telemetry gap or missed tick")
    }
  }
  for slot in [ELBOW_SLOT, RIGHT_ELBOW_SLOT] {
    let position = s.motors[slot].position
    guard position >= -130.0 * RAD && position <= 0.0 else {
      fail("drum measured elbow outside range at slot " + slot.to_string())
    }
    let previous = if slot == ELBOW_SLOT {
      self.previous_left
    } else {
      self.previous_right
    }
    guard (position - previous).abs() <= 5.0 * RAD else {
      fail("drum elbow following error at slot " + slot.to_string())
    }
  }
  let (left, right) = self.targets[self.step]
  let result = self.hold.copy()
  // Advancing the reference must not ask either elbow to exceed the same
  // following tolerance checked above. The transport's duration cap remains.
  if !self.paced ||
    (
      (s.motors[3].position - left).abs() <= 5.0 * RAD &&
      (s.motors[14].position - right).abs() <= 5.0 * RAD
    ) {
    self.previous_left = left
    self.previous_right = right
    self.step += 1
  }
  result[ELBOW_SLOT] = {
    ..self.hold[ELBOW_SLOT],
    position: self.previous_left,
  }
  result[RIGHT_ELBOW_SLOT] = {
    ..self.hold[RIGHT_ELBOW_SLOT],
    position: self.previous_right,
  }
  self.previous_ms = now_ms
  self.previous_source = s.source_ns
  self.previous_receipt = s.receipt_ms
  self.tick += 1
  self.stopped = self.step == self.targets.length()
  result
}
