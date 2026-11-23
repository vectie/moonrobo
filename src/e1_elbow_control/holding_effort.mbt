///|
/// Under the standard PD-plus-feedforward model, calculate a candidate that
/// retains the old instantaneous effort at this pose using SDK standing gains.
/// The caller must supply the actual active command, not MotorState.tau or an
/// inferred zero. This is numerical preparation, not hardware qualification.
/// No runtime selects this candidate automatically or publishes it.
pub fn Sample::effort_matched_candidate(
  self : Self,
  active : ArrayView[@low.MotorCommand],
) -> Array[@low.MotorCommand] raise {
  guard active.length() == 24 &&
    active.all(m => {
      finite(m.position) &&
      finite(m.velocity) &&
      finite(m.torque) &&
      finite(m.kp) &&
      finite(m.kd) &&
      m.kp >= 0.0 &&
      m.kd >= 0.0
    }) &&
    active[23].kp == 0.0 &&
    active[23].torque == 0.0 else {
    fail(
      "complete finite active command required; reported torque is not a command snapshot",
    )
  }
  let candidate = self.stand_candidate()
  for slot in 0..<23 {
    let measured = self.motors[slot]
    let old = active[slot]
    let effort = old.kp * (old.position - measured.position) +
      old.kd * (old.velocity - measured.velocity) +
      old.torque
    // At q_des=q and qd_des=0, the new PD contribution is -kd*qd.
    // Starting tau_ff at zero, or ramping it from zero, loses the old preload.
    let torque = effort + candidate[slot].kd * measured.velocity
    guard finite(effort) && finite(torque) else {
      fail("nonfinite holding effort at slot " + slot.to_string())
    }
    candidate[slot] = { ..candidate[slot], torque, }
  }
  candidate
}
