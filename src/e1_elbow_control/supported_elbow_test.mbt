///|
fn supported_settings() -> @e1_elbow_control.SupportedElbowSettings {
  let feedback = {
    ..trial_settings().feedback,
    maximum_error_rad: 5.0 * 0.017453292519943295,
  }
  {
    format: "moonrobo.e1-supported-elbow.v2",
    power_qualified: false,
    hold_ms: 3000,
    motion_ms: 15000,
    return_hold_ms: 500,
    maximum_total_ms: 19000,
    amplitude_deg: 5.0,
    stationary_tolerance_deg: 5.0,
    following_tolerance_deg: 5.0,
    feedback,
  }
}

///|
test "supported actor feedback preserves all positions and latches excessive drift" {
  let owner = @e1_elbow_control.SupportedHoldFeedback::new(
    supported_settings(),
    position_sample(0),
  )
  let initial = owner.next(position_sample(0), 1000L)
  let next = owner.next(position_sample(1, error=0.001), 1020L)
  assert_true((next[7].torque - 0.001).abs() < 1.0e-12)
  for i in 0..<24 {
    assert_eq(next[i].position, initial[i].position)
  }
  try owner.next(position_sample(2, error=0.09), 1040L) catch {
    _ => ()
  } noraise {
    _ => fail("supported feedback accepted excessive drift")
  }
  try owner.next(position_sample(3), 1060L) catch {
    _ => ()
  } noraise {
    _ => fail("supported feedback did not latch")
  }
}

///|
test "supported gesture keeps leg references fixed permits approved settling and returns left elbow" {
  let profile = supported_settings()
  let baseline = position_sample(0)
  let trial = @e1_elbow_control.SupportedElbowTrial::new(profile, baseline)
  let mut prior = baseline.motors[3].position
  let mut peak = prior
  for tick in 0..<=925 {
    let s = position_sample(
      tick,
      error=if tick == 0 { 0.0 } else { 2.5 * 0.017453292519943295 },
    )
    s.motors[3] = { ..s.motors[3], position: prior, }
    let commands = trial.next(s, s.receipt_ms, shadow=false)
    for i in 0..<24 {
      if i != 3 {
        assert_eq(
          commands[i].position,
          if i == 23 {
            0.0
          } else {
            baseline.motors[i].position
          },
        )
      }
      assert_true(commands[i].torque.abs() <= profile.feedback.bias_limit_nm[i])
    }
    prior = commands[3].position
    peak = peak.min(prior)
  }
  assert_true(
    (peak - baseline.motors[3].position + 5.0 * 0.017453292519943295).abs() <
    1.0e-12,
  )
  assert_eq(prior, baseline.motors[3].position)
  assert_eq(trial.reference_frame(), 750)
}

///|
test "supported profile does not promote old live hold and excess leg drift still latches" {
  let p = supported_settings()
  let old = { ..trial_settings(), feedback: p.feedback, }
  try old.validate() catch {
    _ => ()
  } noraise {
    _ => fail("old hold silently admitted three degrees")
  }
  let trial = @e1_elbow_control.SupportedElbowTrial::new(p, position_sample(0))
  ignore(trial.next(position_sample(0), 1000L, shadow=true))
  try
    trial.next(
      position_sample(1, error=5.1 * 0.017453292519943295),
      1020L,
      shadow=true,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("supported leg guard failed")
  }
  try trial.next(position_sample(2), 1040L, shadow=true) catch {
    _ => ()
  } noraise {
    _ => fail("supported stop did not latch")
  }
}

///|
test "operator-approved elbow following envelope remains bounded at five degrees" {
  let trial = @e1_elbow_control.SupportedElbowTrial::new(
    supported_settings(),
    position_sample(0),
  )
  ignore(trial.next(position_sample(0), 1000L, shadow=false))
  let within = position_sample(1)
  within.motors[3] = {
    ..within.motors[3],
    position: -0.1 - 4.5 * 0.017453292519943295,
  }
  ignore(trial.next(within, 1020L, shadow=false))
  let beyond = position_sample(2)
  beyond.motors[3] = {
    ..beyond.motors[3],
    position: -0.1 - 5.1 * 0.017453292519943295,
  }
  try trial.next(beyond, 1040L, shadow=false) catch {
    _ => ()
  } noraise {
    _ => fail("elbow following limit disabled")
  }
}
