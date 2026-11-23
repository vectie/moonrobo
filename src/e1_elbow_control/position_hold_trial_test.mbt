///|
fn trial_settings() -> @e1_elbow_control.PositionHoldTrialSettings {
  let feedback = settings()
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
    feedback.bias_limit_nm[slot] = budget
    feedback.slew_limit_nm_per_s[slot] = budget
  }
  {
    format: "moonrobo.e1-position-hold-trial.v1",
    power_qualified: false,
    maximum_active_ms: 1000,
    shadow_audit_sha256: "14e323836ba6824014c7e4ab9a7b76810c4ed5638c762bc383b88e7076eb0f89",
    feedback,
  }
}

///|
test "finite commissioning uses the same numeric feedback as shadow without promoting shadow admission" {
  let profile = trial_settings()
  let trial = @e1_elbow_control.PositionHoldTrial::new(
    profile,
    position_sample(0),
  )
  let shadow = @e1_elbow_control.PositionHoldShadow::new(
    profile.feedback,
    position_sample(0),
    shadow=true,
  )
  for tick in 0..<50 {
    let s = position_sample(tick, error=if tick == 0 { 0.0 } else { 0.001 })
    let a = trial.next(s, s.receipt_ms)
    let b = shadow.next(s, s.receipt_ms, shadow=true)
    for i in 0..<24 {
      assert_eq(
        (a[i].position, a[i].velocity, a[i].torque, a[i].kp, a[i].kd),
        (b[i].position, b[i].velocity, b[i].torque, b[i].kp, b[i].kd),
      )
    }
  }
  let late = position_sample(51)
  try trial.next(late, late.receipt_ms) catch {
    _ => ()
  } noraise {
    _ => fail("finite trial exceeded one second")
  }
  let valid = position_sample(50)
  try trial.next(valid, valid.receipt_ms) catch {
    _ => ()
  } noraise {
    _ => fail("trial deadline did not latch")
  }
}

///|
test "commissioning rejects changed gain duration effort budget or qualification claim" {
  for kind in 0..<5 {
    let p = trial_settings()
    let p = match kind {
      0 => { ..p, maximum_active_ms: 15000, }
      1 => { ..p, power_qualified: true, }
      2 => { ..p, shadow_audit_sha256: "missing", }
      3 =>
        { ..p, feedback: { ..p.feedback, integral_gain_nm_per_rad_s: 100.0, }, }
      _ => {
        p.feedback.bias_limit_nm[7] = 8.0
        p
      }
    }
    try p.validate() catch {
      _ => ()
    } noraise {
      _ => fail("changed commissioning request admitted")
    }
  }
}
