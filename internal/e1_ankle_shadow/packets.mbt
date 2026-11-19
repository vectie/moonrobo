///|
pub const RAD : Double = 0.017453292519943295

///|
pub const CONFIRM_NS : Int64 = 6000000L

///|
/// Native E1 status validated by the fixed decoder, in SDK slot order.
pub(all) struct Packet {
  seq : Int32
  source_ns : Int64
  arrival_ns : Int64
  q : Array[Double]
  qd : Array[Double]
  error : Array[Int32]
} derive(FromJson)

///|
pub(all) enum Verdict {
  Use
  Wait
  Stop(String, Int32)
}

///|
pub struct Detector {
  baseline : Packet
  confirm_isolated : Bool
  suspended : Bool
  mut healthy_streak : Int32
  mut good : Packet
  mut last : Packet?
  mut pending : Packet?
  mut left_events : Int32
  mut right_only_events : Int32
  mut max_confirmation_ns : Int64
}

///|
pub fn Detector::new(
  first : Packet,
  confirm_isolated~ : Bool = false,
  suspended~ : Bool = false,
) -> Detector {
  {
    baseline: first,
    confirm_isolated,
    suspended,
    healthy_streak: 0,
    good: first,
    last: None,
    pending: None,
    left_events: 0,
    right_only_events: 0,
    max_confirmation_ns: 0L,
  }
}

///|
/// Capture a new hold reference from the latest validated sample without
/// discarding continuity or the stationary history needed to confirm a spike.
/// Provisional and unobserved samples cannot become a hold reference.
/// As with observe, callers must terminate on Stop rather than reuse a detector.
pub fn Detector::begin_hold(self : Detector) -> Detector raise {
  guard self.pending is None &&
    self.last is Some(last) &&
    last.seq == self.good.seq &&
    self.healthy_streak > 0 else {
    fail("hold reference requires current validated telemetry")
  }
  {
    baseline: self.good,
    confirm_isolated: self.confirm_isolated,
    suspended: self.suspended,
    healthy_streak: self.healthy_streak,
    good: self.good,
    last: self.last,
    pending: None,
    left_events: 0,
    right_only_events: 0,
    max_confirmation_ns: 0L,
  }
}

///|
/// Sign and approximate size of the four changes in the earlier, independent
/// Ethernet audit. These are replay hypotheses for this E1 at this pose.
fn near_step(
  p : Packet,
  before : Packet,
  slot : Int32,
  degrees : Double,
) -> Bool {
  (p.q[slot] - before.q[slot] - degrees * RAD).abs() <= 0.15 * RAD
}

///|
fn known_ankle_step(p : Packet, before : Packet, left : Bool) -> Bool {
  let dt = (p.source_ns - before.source_ns).to_double() / 1.0e9
  let slow = [10, 21].all(slot => {
    before.qd[slot].abs().max(p.qd[slot].abs()) * dt < 0.1 * RAD
  })
  slow &&
  near_step(p, before, 20, -0.46) &&
  near_step(p, before, 21, -3.59) &&
  (!left || (near_step(p, before, 9, 0.23) && near_step(p, before, 10, -9.22)))
}

///|
/// The reboot transient's measured displacements, relative to the preceding
/// good packet. Small stance adjustments must not require a new absolute pose.
/// This grants only Wait; the next packet must recover before any target uses it.
fn known_reboot_step(p : Packet, before : Packet) -> Bool {
  // Select the reboot capture family by its stable left-ankle reference.
  // Right-ankle stance varies slightly as the factory controller stands.
  if (before.q[9] / RAD + 9.209261566).abs() > 0.15 ||
    (before.q[10] / RAD - 2.109822671).abs() > 0.15 {
    return false
  }
  if !slow_standing_ankles(before, p) {
    return false
  }
  let mut mask = 0
  for
    bit, (slot, degrees) in [
      (9, 1.198706425),
      (10, -12.371662805),
      (20, 1.637482011),
      (21, -5.180925187),
    ] {
    if (p.q[slot] - before.q[slot]).abs() <= 0.1 * RAD {
      continue
    }
    if !near_step(p, before, slot, degrees) {
      return false
    }
    mask = mask | (1 << bit)
  }
  // Ankle components may update independently in the same transient. Each
  // changed component must match its own measured displacement; no arbitrary
  // outlier or newly measured pose is substituted into the outgoing targets.
  mask != 0
}

///|
priv enum StandingAnkles {
  Nominal(Int32)
  Spike(Int32)
  Unknown
}

///|
/// Two independently captured standing poses, before and after the reboot.
/// Each bit selects the observed alternate value in SDK order 9, 10, 20, 21.
/// Keep the pose identity so a recovery cannot cross between recordings.
fn standing_ankles_at(p : Packet, pose : Int32) -> StandingAnkles {
  if p.q.length() != 24 {
    return Unknown
  }
  let angles = if pose == 0 {
    [
      (9, -8.79273, -7.52971),
      (10, 2.22618, -9.91213),
      (20, -5.76529, -3.98889),
      (21, -3.13875, -7.42043),
    ]
  } else {
    // 2026-11-19 capture, sequences 267509 / 267510 / 267511.
    // All four angles returned exactly in the following packet, 2.932 ms later.
    [
      (9, -9.209261566, -8.010555142),
      (10, 2.109822671, -10.261840134),
      (20, -6.566201157, -4.928719147),
      (21, -2.895199770, -8.076124958),
    ]
  }
  // Reboot captures include encoder quantization and small stance changes.
  // Use the existing 0.15-degree signature tolerance for this capture family;
  // the one-degree drift and 0.1-degree recovery bounds remain independent.
  let tolerance = if pose == 0 { 0.02 } else { 0.15 }
  let mut mask = 0
  for bit, (slot, nominal, alternate) in angles {
    let degrees = p.q[slot] / RAD
    if (degrees - alternate).abs() <= tolerance {
      mask = mask | (1 << bit)
    } else if !((degrees - nominal).abs() <= tolerance) {
      return Unknown
    }
  }
  if pose == 1 {
    return if mask == 0 { Nominal(pose) } else { Spike(pose) }
  }
  match mask {
    0 => Nominal(pose)
    4 | 12 | 14 | 15 => Spike(pose)
    13 => if pose == 0 { Spike(pose) } else { Unknown }
    _ => Unknown
  }
}

///|
fn standing_ankles(p : Packet) -> StandingAnkles {
  match standing_ankles_at(p, 0) {
    Unknown => standing_ankles_at(p, 1)
    found => found
  }
}

///|
fn same_standing_recovery(suspect : Packet, next : Packet) -> Bool {
  match (standing_ankles(suspect), standing_ankles(next)) {
    (Spike(a), Nominal(b)) => a == b
    _ => false
  }
}

///|
pub fn Packet::starts_on_standing_spike(self : Packet) -> Bool {
  standing_ankles(self) is Spike(_)
}

///|
fn slow_standing_ankles(a : Packet, b : Packet) -> Bool {
  let dt = (b.source_ns - a.source_ns).to_double() / 1.0e9
  [9, 10, 20, 21].all(slot => {
    a.qd[slot].abs().max(b.qd[slot].abs()) * dt < 0.1 * RAD
  })
}

///|
fn status_check(p : Packet) -> Verdict {
  if p.q.length() != 24 || p.qd.length() != 24 || p.error.length() != 24 {
    return Stop("incomplete status", -1)
  }
  for slot in 0..<24 {
    let q = p.q[slot]
    let v = p.qd[slot]
    if p.error[slot] != 0 || q - q != 0.0 || v - v != 0.0 {
      return Stop("invalid motor status", slot)
    }
  }
  Use
}

///|
fn consecutive(
  a : Packet,
  b : Packet,
  maximum_gap~ : Int64 = CONFIRM_NS,
) -> Bool {
  let source_gap = b.source_ns - a.source_ns
  let host_gap = b.arrival_ns - a.arrival_ns
  b.seq == a.seq + 1 &&
  source_gap > 0L &&
  host_gap > 0L &&
  source_gap <= maximum_gap &&
  host_gap <= maximum_gap
}

///|
/// With no preceding good sample, only the independently observed nominal
/// standing pose can seed a baseline after a recognized startup transient.
pub fn Packet::confirms_standing_start(self : Packet, first : Packet) -> Bool {
  guard status_check(first) is Use &&
    status_check(self) is Use &&
    same_standing_recovery(first, self) &&
    consecutive(first, self) &&
    slow_standing_ankles(first, self) else {
    return false
  }
  for i, q in first.q {
    if !(i is (9 | 10 | 20 | 21)) && (q - self.q[i]).abs() > 0.1 * RAD {
      return false
    }
  }
  true
}

///|
/// Process every adjacent packet, including the ones between elbow ticks.
/// The caller terminates permanently on Stop. Wait releases no sample.
pub fn Detector::observe(self : Detector, p : Packet) -> Verdict {
  let health = status_check(p)
  if health is Stop(_, _) {
    return health
  }
  if self.last is Some(prev) {
    // Suspended assessment has no provisional ankle confirmation. Its packet
    // cadence follows the same 40 ms freshness bound as the command path.
    let maximum_gap = if self.suspended { 40000000L } else { CONFIRM_NS }
    if !consecutive(prev, p, maximum_gap~) {
      return Stop("packet continuity lost", -1)
    }
  } else if !self.suspended && self.baseline.starts_on_standing_spike() {
    return Stop("unconfirmed standing ankle baseline", -1)
  }
  self.last = Some(p)
  if self.suspended {
    for slot in 0..<24 {
      if @elbow.leg_slot(slot) && !@elbow.leg_position_in_range(slot, p.q[slot]) {
        return Stop("leg feedback outside SDK joint range", slot)
      }
    }
    self.good = p
    self.healthy_streak = (self.healthy_streak + 1).min(2)
    return Use
  }
  let mut ankle_slot : Int32? = None
  for slot in 0..<23 {
    if slot != @elbow.ELBOW_SLOT &&
      (p.q[slot] - self.baseline.q[slot]).abs() > RAD {
      match slot {
        9 | 10 | 20 | 21 => if ankle_slot is None { ankle_slot = Some(slot) }
        _ => return Stop("stationary joint outside tolerance", slot)
      }
    }
  }
  if self.pending is Some(suspect) {
    if ankle_slot is Some(slot) {
      return Stop("ankle excursion persisted", slot)
    }
    let bilateral = [9, 10].any(i => {
      (suspect.q[i] - self.baseline.q[i]).abs() > RAD
    })
    if !slow_standing_ankles(suspect, p) ||
      (
        !self.confirm_isolated &&
        standing_ankles(suspect) is Spike(0) &&
        !same_standing_recovery(suspect, p)
      ) {
      return Stop(
        "standing ankles did not recover",
        if bilateral {
          9
        } else {
          20
        },
      )
    }
    let affected = if bilateral || self.confirm_isolated {
      [9, 10, 20, 21]
    } else {
      [20, 21]
    }
    for slot in affected {
      if (p.q[slot] - self.good.q[slot]).abs() > 0.1 * RAD {
        return Stop("ankle did not return to previous pose", slot)
      }
    }
    if bilateral {
      self.left_events += 1
    } else {
      self.right_only_events += 1
    }
    self.max_confirmation_ns = self.max_confirmation_ns.max(
      p.arrival_ns - suspect.arrival_ns,
    )
    self.pending = None
    self.healthy_streak = 0
  } else if ankle_slot is Some(slot) {
    if self.confirm_isolated {
      // Only an abrupt, velocity-inconsistent ankle-only sample is provisional.
      // Gradual baseline drift still fails on its first over-limit packet.
      for ankle in [9, 10, 20, 21] {
        if (p.q[ankle] - self.baseline.q[ankle]).abs() > RAD &&
          (p.q[ankle] - self.good.q[ankle]).abs() <= RAD {
          return Stop("gradual ankle drift", ankle)
        }
      }
      if self.healthy_streak < 2 {
        return Stop("ankle excursion lacks stationary history", slot)
      }
      if !slow_standing_ankles(self.good, p) {
        return Stop("ankle excursion corroborated by velocity", slot)
      }
      self.pending = Some(p)
      self.healthy_streak = 0
      return Wait
    }
    let standing = match
      (
        standing_ankles(self.baseline),
        standing_ankles(self.good),
        standing_ankles(p),
      ) {
      (Nominal(a), Nominal(b), Spike(c)) =>
        a == b && b == c && slow_standing_ankles(self.good, p)
      _ => false
    }
    let old_pose = (p.q[9] - self.baseline.q[9]).abs() <= RAD &&
      (p.q[20] - self.baseline.q[20]).abs() <= RAD &&
      (p.q[21] - self.baseline.q[21]).abs() > RAD &&
      known_ankle_step(p, self.good, slot == 10)
    if !standing && !old_pose && !known_reboot_step(p, self.good) {
      return Stop("unrecognized ankle excursion", slot)
    }
    self.pending = Some(p)
    return Wait
  }
  self.good = p
  self.healthy_streak = (self.healthy_streak + 1).min(2)
  Use
}

///|
pub extend Packet with @json.FromJson::{from_json}
