///|
/// Shadow admission remains separate from the finite commissioning request.
pub struct PositionHoldShadow {
  priv state : PositionHoldState
}

///|
pub fn PositionHoldShadow::new(
  settings : PositionHoldSettings,
  baseline : Sample,
  shadow~ : Bool,
) -> Self raise {
  guard shadow else { fail("position-feedback hold is shadow only") }
  { state: PositionHoldState::new(settings, baseline), }
}

///|
pub fn PositionHoldShadow::next(
  self : Self,
  sample : Sample,
  now_ms : Int64,
  shadow~ : Bool,
) -> Array[@low.MotorCommand] raise {
  guard shadow else {
    self.state.stopped = true
    fail("position-feedback hold is shadow only")
  }
  self.state.next(sample, now_ms)
}

///|
/// A request to commission an unqualified hold, never a qualification receipt.
pub(all) struct PositionHoldTrialSettings {
  format : String
  power_qualified : Bool
  maximum_active_ms : Int32
  shadow_audit_sha256 : String
  feedback : PositionHoldSettings
} derive(FromJson, ToJson)

///|
pub extend PositionHoldTrialSettings with @json.FromJson::{from_json}

///|
pub extend PositionHoldTrialSettings with @json.ToJson::{to_json}

///|
pub fn PositionHoldTrialSettings::validate(self : Self) -> Unit raise {
  self.feedback.validate()
  guard self.format == "moonrobo.e1-position-hold-trial.v1" &&
    !self.power_qualified &&
    self.maximum_active_ms == 1000 &&
    self.shadow_audit_sha256.length() == 64 &&
    self.shadow_audit_sha256
    .iter()
    .all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) &&
    self.feedback.integral_gain_nm_per_rad_s == 50.0 &&
    self.feedback.maximum_error_rad == RAD else {
    fail("invalid finite position-hold commissioning request")
  }
  // Only the exact parameters exercised in the fifteen-second shadow may be
  // requested for this first commissioning hold. No tuning is implicit.
  for slot in 0..<24 {
    let budget = if slot is (7 | 8 | 18 | 19) {
      7.5
    } else if slot is (5 | 6 | 16 | 17) {
      4.5
    } else if slot is (9 | 10 | 20 | 21) {
      3.5
    } else {
      0.0
    }
    guard self.feedback.bias_limit_nm[slot] == budget &&
      self.feedback.slew_limit_nm_per_s[slot] == budget else {
      fail("position-hold commissioning parameters differ from tested shadow")
    }
  }
}

///|
pub struct PositionHoldTrial {
  priv state : PositionHoldState
  priv mut started_ms : Int64?
  priv mut stopped : Bool
}

///|
pub fn PositionHoldTrial::new(
  settings : PositionHoldTrialSettings,
  baseline : Sample,
) -> Self raise {
  settings.validate()
  {
    state: PositionHoldState::new(settings.feedback, baseline),
    started_ms: None,
    stopped: false,
  }
}

///|
/// The transport independently validates the request, evidence, fixed targets,
/// integral calculation and deadline. This owner contains no transport.
pub fn PositionHoldTrial::next(
  self : Self,
  sample : Sample,
  now_ms : Int64,
) -> Array[@low.MotorCommand] raise {
  guard !self.stopped else { fail("position-hold trial stopped") }
  self.stopped = true
  let started = self.started_ms.unwrap_or(now_ms)
  guard now_ms >= started && now_ms - started <= 1000L else {
    fail("position-hold commissioning deadline")
  }
  let commands = self.state.next(sample, now_ms)
  self.started_ms = Some(started)
  self.stopped = false
  commands
}
