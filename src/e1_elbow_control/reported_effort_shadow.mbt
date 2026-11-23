///|
/// Availability for an explicitly unqualified counterfactual, not a torque-valid
/// flag. Never infer that a zero represents a missing or a genuine measurement.
pub fn reported_leg_effort_shadow_available(tau : ArrayView[Double]) -> Bool {
  tau.length() == 24 &&
  tau.all(finite) &&
  Array::makei(24, i => i).all(i => !leg_slot(i) || tau[i] != 0.0)
}

///|
/// Shadow-only static-effort hypothesis. Keep measured positions and SDK gains,
/// and compensate initial damping so the modeled leg effort equals the report.
/// A simultaneous nonzero report does not establish its validity or motor-side
/// age. The result cannot qualify or authorize a powered takeover.
pub fn Sample::reported_leg_effort_shadow_candidate(
  self : Self,
  tau : ArrayView[Double],
  shadow~ : Bool,
) -> Array[@low.MotorCommand] raise {
  guard shadow && reported_leg_effort_shadow_available(tau) else {
    fail(
      "fresh complete reported leg effort is an unqualified shadow-only hypothesis",
    )
  }
  let result = self.stand_candidate()
  for slot in 0..<23 {
    if leg_slot(slot) {
      let torque = tau[slot] + result[slot].kd * self.motors[slot].velocity
      guard finite(torque) else { fail("nonfinite shadow leg effort") }
      result[slot] = { ..result[slot], torque, }
    }
  }
  result
}
