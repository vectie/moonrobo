///|
test "effort matching preserves loaded holding effort without changing leg positions" {
  let sample : @e1_elbow_control.Sample = {
    source_ns: 1L,
    receipt_ms: 1L,
    motors: Array::makei(24, i => {
      id: i,
      position: if i == 23 {
        12.5
      } else {
        -0.1
      },
      velocity: if i == 23 {
        18.0
      } else {
        0.02
      },
      error: 0,
    }),
  }
  let source = sample.stand_candidate()
  for slot in 0..<23 {
    source[slot] = {
      position: -0.04,
      velocity: 0.01,
      torque: 0.3,
      kp: 60.0,
      kd: 4.0,
    }
  }
  let candidate = sample.effort_matched_candidate(source[:])
  for slot in 0..<23 {
    let q = sample.motors[slot].position
    let qd = sample.motors[slot].velocity
    let a = source[slot]
    let b = candidate[slot]
    let before = a.kp * (a.position - q) + a.kd * (a.velocity - qd) + a.torque
    let after = b.kp * (b.position - q) + b.kd * (b.velocity - qd) + b.torque
    assert_true((before - after).abs() < 1.0e-12)
    assert_eq(b.position, q)
    assert_eq(b.velocity, 0.0)
    assert_eq(b.kp, 50.0)
    assert_true(b.torque > 3.0)
  }
  assert_eq(
    (candidate[23].position, candidate[23].kp, candidate[23].torque),
    (0.0, 0.0, 0.0),
  )
  // The earlier measured-position/zero-feedforward candidate loses the preload.
  let zero = sample.stand_candidate()
  assert_true(
    (source[7].kp * (source[7].position + 0.1) + source[7].torque).abs() > 3.0,
  )
  assert_eq(zero[7].torque, 0.0)
}

///|
test "unknown or invalid active commands cannot be replaced with zero effort" {
  let sample : @e1_elbow_control.Sample = {
    source_ns: 1L,
    receipt_ms: 1L,
    motors: Array::makei(24, i => {
      id: i,
      position: 0.0,
      velocity: 0.0,
      error: 0,
    }),
  }
  try sample.effort_matched_candidate([]) catch {
    _ => ()
  } noraise {
    _ => fail("missing controller effort admitted")
  }
  for kind in 0..<3 {
    let source = sample.stand_candidate()
    source[7] = match kind {
      0 => { ..source[7], torque: 0.0 / 0.0, }
      1 => { ..source[7], kp: -1.0, }
      _ => { ..source[7], position: 1.0e308, kp: 1.0e308, }
    }
    try sample.effort_matched_candidate(source[:]) catch {
      _ => ()
    } noraise {
      _ => fail("invalid holding effort admitted")
    }
  }
}
