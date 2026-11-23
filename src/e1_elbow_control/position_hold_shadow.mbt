///|
/// Experimental integral-effort feedback with fixed position references. All
/// budgets are explicit shadow settings, not commissioned actuator parameters.
pub(all) struct PositionHoldSettings {
  format : String
  power_qualified : Bool
  integral_gain_nm_per_rad_s : Double
  bias_limit_nm : Array[Double]
  slew_limit_nm_per_s : Array[Double]
  maximum_error_rad : Double
} derive(FromJson, ToJson)

///|
pub extend PositionHoldSettings with @json.FromJson::{from_json}

///|
pub extend PositionHoldSettings with @json.ToJson::{to_json}

///|
pub fn PositionHoldSettings::validate(self : Self) -> Unit raise {
  guard self.format == "moonrobo.e1-position-hold-shadow.v1" &&
    !self.power_qualified &&
    finite(self.integral_gain_nm_per_rad_s) &&
    self.integral_gain_nm_per_rad_s > 0.0 &&
    finite(self.maximum_error_rad) &&
    self.maximum_error_rad > 0.0 &&
    self.maximum_error_rad <= 3.0 * RAD &&
    self.bias_limit_nm.length() == 24 &&
    self.slew_limit_nm_per_s.length() == 24 else {
    fail("invalid position-only hold shadow settings")
  }
  for slot in 0..<24 {
    let limit = self.bias_limit_nm[slot]
    let slew = self.slew_limit_nm_per_s[slot]
    guard finite(limit) && finite(slew) else { fail("nonfinite hold budget") }
    if leg_slot(slot) {
      // Published torque-table values bound this numerical experiment, not
      // permission for continuous effort or powered use on this unit.
      let peak = if slot is (7 | 8 | 18 | 19) {
        150.0
      } else if slot is (5 | 6 | 16 | 17) {
        90.0
      } else {
        70.0
      }
      guard limit > 0.0 && limit <= peak && slew > 0.0 else {
        fail("invalid leg effort budget")
      }
    } else {
      guard limit == 0.0 && slew == 0.0 else {
        fail("position hold may adapt leg effort only")
      }
    }
  }
}

///|
priv struct PositionHoldState {
  settings : PositionHoldSettings
  hold : Array[@low.MotorCommand]
  bias : Array[Double]
  source_start : Int64
  receipt_start : Int64
  mut previous_source : Int64?
  mut previous_receipt : Int64
  mut stopped : Bool
}

///|
fn PositionHoldState::new(
  settings : PositionHoldSettings,
  baseline : Sample,
) -> Self raise {
  settings.validate()
  guard baseline.source_ns > 0L && baseline.receipt_ms >= 0L else {
    fail("invalid position hold baseline clock")
  }
  {
    settings: {
      ..settings,
      bias_limit_nm: settings.bias_limit_nm.copy(),
      slew_limit_nm_per_s: settings.slew_limit_nm_per_s.copy(),
    },
    hold: baseline.stand_candidate(),
    bias: Array::make(24, 0.0),
    source_start: baseline.source_ns,
    receipt_start: baseline.receipt_ms,
    previous_source: None,
    previous_receipt: baseline.receipt_ms,
    stopped: false,
  }
}

///|
/// No torque readback is accepted. The bounded applied bias is the entire
/// integral state, preventing windup behind amplitude or slew saturation.
/// Errors latch; callers must discard the owner after any failure.
fn PositionHoldState::next(
  self : Self,
  sample : Sample,
  now_ms : Int64,
) -> Array[@low.MotorCommand] raise {
  guard !self.stopped else { fail("position hold stopped") }
  self.stopped = true
  guard now_ms >= sample.receipt_ms &&
    now_ms - sample.receipt_ms <= 40L &&
    sample.motors.length() == 24 else {
    fail("invalid or stale position hold input")
  }
  let dt = match self.previous_source {
    None => {
      guard sample.source_ns == self.source_start &&
        sample.receipt_ms == self.receipt_start else {
        fail("position hold must start at its captured reference")
      }
      0.0
    }
    Some(previous) => {
      guard sample.source_ns > previous &&
        sample.source_ns - previous <= 40000000L &&
        sample.receipt_ms > self.previous_receipt &&
        sample.receipt_ms - self.previous_receipt <= 40L else {
        fail("position hold input gap, duplicate or reversal")
      }
      (sample.source_ns - previous).to_double() / 1000000000.0
    }
  }
  // Validate the complete sample before committing any integrator state.
  for slot, motor in sample.motors {
    guard motor.id == slot &&
      motor.error == 0 &&
      finite(motor.position) &&
      finite(motor.velocity) else {
      fail("invalid position hold motor sample")
    }
    if leg_slot(slot) {
      guard (self.hold[slot].position - motor.position).abs() <=
        self.settings.maximum_error_rad else {
        fail("position hold leg drift at slot " + slot.to_string())
      }
    }
  }
  let result = self.hold.copy()
  for slot in 0..<23 {
    if leg_slot(slot) {
      let error = self.hold[slot].position - sample.motors[slot].position
      let limit = self.settings.bias_limit_nm[slot]
      let step = self.settings.slew_limit_nm_per_s[slot] * dt
      let requested = self.bias[slot] +
        self.settings.integral_gain_nm_per_rad_s * error * dt
      guard finite(requested) else { fail("nonfinite position hold bias") }
      let bounded = requested.max(-limit).min(limit)
      let next = self.bias[slot] +
        (bounded - self.bias[slot]).max(-step).min(step)
      self.bias[slot] = next
      result[slot] = { ..result[slot], torque: next, }
    }
  }
  self.previous_source = Some(sample.source_ns)
  self.previous_receipt = sample.receipt_ms
  self.stopped = false
  result
}
