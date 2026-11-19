///|
/// Fixed SDK 3.1 layout verified against the E1 status stream on the Atlas host.
/// The model name l_arm_elbow_pitch_joint corresponds to arm_l4_joint.
pub const ELBOW_SLOT : Int32 = 3

///|
pub const FRAMES : Int32 = 751

///|
pub const DT_MS : Int32 = 20

///|
const RAD : Double = 0.017453292519943295

///|
pub(all) struct Clip {
  joint : String
  step_ms : Int32
  offset_degrees : Array[Double]
} derive(FromJson)

///|
pub extend Clip with @json.FromJson::{from_json}

///|
pub(all) struct Motor {
  id : Int32
  position : Double
  velocity : Double
  error : Int32
} derive(FromJson)

///|
pub extend Motor with @json.FromJson::{from_json}

///|
pub(all) struct Sample {
  source_ns : Int64
  receipt_ms : Int64
  motors : Array[Motor]
} derive(FromJson)

///|
pub extend Sample with @json.FromJson::{from_json}

///|
pub fn leg_slot(slot : Int32) -> Bool {
  (slot >= 5 && slot <= 10) || (slot >= 16 && slot <= 21)
}

///|
/// SDK development guide dated 29 January 2026, joint table on pages 10–11.
/// Bounds use the degree column, avoiding the typo in right hip yaw radians.
pub fn leg_position_in_range(slot : Int32, position : Double) -> Bool {
  let (minimum, maximum) = match slot {
    5 => (-40.0, 53.0)
    6 => (-40.0, 35.0)
    7 | 18 => (-85.0, 50.0)
    8 | 19 => (0.0, 135.0)
    9 | 20 => (-58.0, 24.0)
    10 => (-90.0, 90.0)
    16 => (-53.0, 40.0)
    17 => (-35.0, 40.0)
    21 => (-15.0, 15.0)
    _ => return false
  }
  finite(position) && position >= minimum * RAD && position <= maximum * RAD
}

///|
/// First frame of the vendor standing example, in SDK ID order. This computes
/// a candidate for commissioning and makes no assumption about the active owner.
pub fn Sample::stand_candidate(self : Sample) -> Array[@low.MotorCommand] raise {
  guard self.motors.length() == 24 else { fail("24 motor statuses required") }
  Array::makei(24, i => {
    let m = self.motors[i]
    guard m.id == i && m.error == 0 && finite(m.position) && finite(m.velocity) else {
      fail("invalid standing sample at slot " + i.to_string())
    }
    {
      position: if i == 23 {
        0.0
      } else {
        m.position
      },
      velocity: 0.0,
      torque: 0.0,
      kp: if i == 23 {
        0.0
      } else {
        50.0
      },
      kd: if i is (9 | 10 | 20 | 21) {
        1.0
      } else {
        5.0
      },
    }
  })
}

///|
fn finite(x : Double) -> Bool {
  x == x && x - x == 0.0
}

///|
/// There is no transport or mode transition in this owner. The baseline must be
/// the complete stationary frame of an already-established hold, in SDK order.
/// Joint status does not contain the active gains, commanded targets or authority.
pub struct Path {
  priv hold : Array[@low.MotorCommand]
  priv offsets : Array[Double]
  priv tracking_tolerance : Double
  priv suspended : Bool
  priv mut initial_positions : Array[Double]
  priv mut previous_target : Double
  priv mut started_ms : Int64
  priv mut previous_ms : Int64
  priv mut previous_source : Int64
  priv mut previous_receipt : Int64
  priv mut step : Int32
  priv mut stopped : Bool
}

///|
fn fold_offset(
  peak : Double,
  frame : Int32,
  frames~ : Int32 = FRAMES,
) -> Double {
  peak /
  2.0 *
  (
    1.0 -
    @math.cos(2.0 * @math.PI * frame.to_double() / (frames - 1).to_double())
  )
}

///|
/// Ninety seconds to fold 90 degrees and ninety seconds to return.
pub fn Clip::slow_fold_return() -> Clip {
  let frames = 180000 / DT_MS + 1
  {
    joint: "l_arm_elbow_pitch_joint",
    step_ms: DT_MS,
    offset_degrees: Array::makei(frames, i => fold_offset(-90.0, i, frames~)),
  }
}

///|
pub fn Clip::gentle() -> Clip {
  {
    joint: "l_arm_elbow_pitch_joint",
    step_ms: DT_MS,
    offset_degrees: Array::makei(FRAMES, i => fold_offset(-5.0, i)),
  }
}

///|
/// Call after validating the clip. Both thresholds are shadow diagnostics.
pub fn Clip::tracking_tolerance_deg(self : Clip) -> Double {
  if self.offset_degrees.get(375) is Some(-5.0) {
    1.0
  } else {
    5.0
  }
}

///|
/// Check the 90-degree site reference or reviewed 5-degree elbow reference.
pub fn Clip::validate(clip : Clip) -> Unit raise {
  let frames = clip.offset_degrees.length()
  let middle = (frames - 1) / 2
  guard clip.joint == "l_arm_elbow_pitch_joint" &&
    clip.step_ms == DT_MS &&
    (frames == FRAMES || frames == 9001) &&
    clip.offset_degrees[0] == 0.0 &&
    (
      clip.offset_degrees[middle] == -90.0 ||
      (frames == FRAMES && clip.offset_degrees[middle] == -5.0)
    ) &&
    clip.offset_degrees[frames - 1] == 0.0 else {
    fail("reviewed left elbow fold-and-return reference required")
  }
  for i, offset in clip.offset_degrees {
    let prescribed = fold_offset(clip.offset_degrees[middle], i, frames~)
    guard finite(offset) && (offset - prescribed).abs() < 1.0e-8 else {
      fail("unexpected fold reference at frame " + i.to_string())
    }
  }
}

///|
pub fn Path::new(
  clip : Clip,
  hold : ArrayView[@low.MotorCommand],
  suspended~ : Bool = false,
) -> Path raise {
  clip.validate()
  guard hold.length() == 24 else {
    fail("complete stationary 24-slot hold required")
  }
  for m in hold {
    guard finite(m.position) &&
      m.velocity == 0.0 &&
      finite(m.torque) &&
      finite(m.kp) &&
      m.kp >= 0.0 &&
      finite(m.kd) &&
      m.kd >= 0.0 else {
      fail("invalid stationary hold")
    }
  }
  guard hold[ELBOW_SLOT].kp > 0.0 else {
    fail("elbow hold has no position gain")
  }
  let start = hold[ELBOW_SLOT].position
  guard clip.offset_degrees.all(d => {
    let target = start + d * RAD
    target >= -2.44 && target <= 0.0
  }) else {
    fail("fold exceeds modeled elbow limits")
  }
  {
    hold: hold.to_owned(),
    tracking_tolerance: clip.tracking_tolerance_deg() * RAD,
    suspended,
    offsets: clip.offset_degrees.map(d => d * RAD),
    initial_positions: [],
    previous_target: start,
    started_ms: 0L,
    previous_ms: 0L,
    previous_source: 0L,
    previous_receipt: 0L,
    step: 0,
    stopped: false,
  }
}

///|
/// Stops and faults latch. Discarding a candidate frame is not a physical stop.
pub fn Path::cancel(self : Path) -> Unit {
  self.stopped = true
}

///|
/// One sample and one candidate per 20 ms tick. now_ms and receipt_ms are in
/// the same host clock domain; source time is only compared with source time.
/// Diagnostic tolerances: 1 degree hold drift, 5 degrees elbow following error,
/// 40 ms receipt age/source gap and half a tick of scheduling jitter.
pub fn Path::next(
  self : Path,
  s : Sample,
  now_ms : Int64,
) -> Array[@low.MotorCommand] raise {
  guard !self.stopped else { fail("elbow path stopped") }
  self.stopped = true
  guard now_ms >= 0L &&
    s.receipt_ms >= 0L &&
    now_ms >= s.receipt_ms &&
    now_ms - s.receipt_ms <= 40L &&
    s.source_ns > 0L else {
    fail("invalid or stale telemetry")
  }
  guard s.motors.length() == 24 else { fail("incomplete motor status") }
  for slot, m in s.motors {
    guard m.id == slot &&
      m.error == 0 &&
      finite(m.position) &&
      finite(m.velocity) else {
      fail("motor ID, status or value invalid at slot " + slot.to_string())
    }
    if self.suspended &&
      leg_slot(slot) &&
      !leg_position_in_range(slot, m.position) {
      fail("leg feedback outside SDK joint range at slot " + slot.to_string())
    }
  }
  if self.step == 0 {
    for slot in 0..<23 {
      if self.suspended && slot != ELBOW_SLOT {
        continue
      }
      guard (self.hold[slot].position - s.motors[slot].position).abs() <= RAD else {
        fail(
          "starting hold disagrees with measured pose at slot " +
          slot.to_string(),
        )
      }
    }
    self.started_ms = now_ms
    self.initial_positions = s.motors.map(m => m.position)
  } else {
    guard now_ms > self.previous_ms &&
      s.receipt_ms > self.previous_receipt &&
      s.source_ns > self.previous_source &&
      s.source_ns - self.previous_source <= 40000000L else {
      fail("telemetry gap, duplicate or clock reversal")
    }
    let actual = now_ms - self.started_ms
    let scheduled = self.step.to_int64() * 20L
    let interval = now_ms - self.previous_ms
    guard actual >= scheduled - 10L &&
      actual <= scheduled + 10L &&
      interval >= 10L &&
      interval <= 30L else {
      fail("missed elbow tick")
    }
  }
  for slot in 0..<23 {
    if !self.suspended &&
      slot != ELBOW_SLOT &&
      (s.motors[slot].position - self.initial_positions[slot]).abs() > RAD {
      fail("stationary joint drift at slot " + slot.to_string())
    }
  }
  let elbow = s.motors[ELBOW_SLOT].position
  guard elbow >= -2.44 && elbow <= 0.0 else {
    fail("measured elbow outside modeled limits")
  }
  guard (elbow - self.previous_target).abs() <= self.tracking_tolerance else {
    fail("elbow following error")
  }
  let target = self.hold[ELBOW_SLOT].position + self.offsets[self.step]
  let result = self.hold.copy()
  result[ELBOW_SLOT] = { ..self.hold[ELBOW_SLOT], position: target, }
  self.previous_target = target
  self.previous_ms = now_ms
  self.previous_receipt = s.receipt_ms
  self.previous_source = s.source_ns
  self.step += 1
  self.stopped = self.step == self.offsets.length()
  result
}
