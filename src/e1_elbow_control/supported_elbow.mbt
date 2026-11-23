///|
/// Explicit crane-supported commissioning settings, separate from actor
/// qualification and the default one-degree hold profile.
pub(all) struct SupportedElbowSettings {
  format : String
  power_qualified : Bool
  hold_ms : Int32
  motion_ms : Int32
  return_hold_ms : Int32
  maximum_total_ms : Int32
  amplitude_deg : Double
  stationary_tolerance_deg : Double
  following_tolerance_deg : Double
  feedback : PositionHoldSettings
} derive(FromJson, ToJson)

///|
pub extend SupportedElbowSettings with @json.FromJson::{from_json}

///|
pub extend SupportedElbowSettings with @json.ToJson::{to_json}

///|
pub fn SupportedElbowSettings::validate(self : Self) -> Unit raise {
  validate_feedback_budgets(self.feedback, 5.0 * RAD)
  guard self.format == "moonrobo.e1-supported-elbow.v2" &&
    !self.power_qualified &&
    self.hold_ms == 3000 &&
    self.motion_ms == 15000 &&
    self.return_hold_ms == 500 &&
    self.maximum_total_ms == 19000 &&
    self.amplitude_deg == 5.0 &&
    self.stationary_tolerance_deg == 5.0 &&
    self.following_tolerance_deg == 5.0 &&
    self.feedback.maximum_error_rad == 5.0 * RAD else {
    fail("invalid supported elbow request")
  }
}

///|
pub struct SupportedElbowTrial {
  priv state : PositionHoldState
  priv hold : Array[@low.MotorCommand]
  priv offsets : Array[Double]
  priv mut started_ms : Int64?
  priv mut previous_elbow : Double
  priv mut frame : Int32
  priv mut stopped : Bool
}

///|
pub fn SupportedElbowTrial::new(
  settings : SupportedElbowSettings,
  baseline : Sample,
) -> Self raise {
  settings.validate()
  let hold = baseline.stand_candidate()
  guard hold[3].position >= -2.44 + 5.0 * RAD && hold[3].position <= 0.0 else {
    fail("supported elbow path outside limits")
  }
  {
    state: PositionHoldState::new(settings.feedback, baseline),
    hold,
    offsets: Clip::gentle().offset_degrees,
    started_ms: None,
    previous_elbow: hold[3].position,
    frame: -1,
    stopped: false,
  }
}

///|
pub fn SupportedElbowTrial::reference_frame(self : Self) -> Int32 {
  self.frame
}

///|
pub fn SupportedElbowTrial::elapsed_ms(self : Self, now_ms : Int64) -> Int64 {
  now_ms - self.started_ms.unwrap_or(now_ms)
}

///|
/// A fixed reference drives only the left elbow. The live leg feedback is never
/// simulated; shadow merely omits the unexecuted elbow's following check.
pub fn SupportedElbowTrial::next(
  self : Self,
  sample : Sample,
  now_ms : Int64,
  shadow~ : Bool,
) -> Array[@low.MotorCommand] raise {
  guard !self.stopped else { fail("supported elbow stopped") }
  self.stopped = true
  let elapsed = self.elapsed_ms(now_ms)
  guard elapsed >= 0L && elapsed <= 18500L else {
    fail("supported elbow deadline")
  }
  let commands = self.state.next(sample, now_ms)
  let actual = sample.motors[3].position
  guard actual >= -2.44 &&
    actual <= 0.0 &&
    (shadow || (actual - self.previous_elbow).abs() <= 5.0 * RAD) else {
    fail("supported elbow following error")
  }
  let frame = if elapsed < 3000L {
    -1
  } else {
    ((elapsed - 3000L) / 20L).to_int().min(750)
  }
  guard frame >= self.frame && frame - self.frame <= 1 else {
    fail("missed supported elbow reference tick")
  }
  let target = self.hold[3].position +
    (if frame < 0 { 0.0 } else { self.offsets[frame] * RAD })
  commands[3] = { ..commands[3], position: target, }
  self.previous_elbow = target
  self.frame = frame
  if self.started_ms is None {
    self.started_ms = Some(now_ms)
  }
  self.stopped = false
  commands
}
