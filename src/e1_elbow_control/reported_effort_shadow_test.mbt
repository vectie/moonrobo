///|
test "reported effort seed restores modeled preload only in explicit shadow" {
  let sample : @e1_elbow_control.Sample = {
    source_ns: 1L,
    receipt_ms: 1L,
    motors: Array::makei(24, i => {
      id: i,
      position: -0.1,
      velocity: 0.02,
      error: 0,
    }),
  }
  let tau = Array::make(24, 0.3)
  tau[7] = 2.8205108642578125
  tau[23] = 90.0 // Reserved/disconnected slot is never an actuator effort seed.
  let result = sample.reported_leg_effort_shadow_candidate(tau[:], shadow=true)
  let original = sample.stand_candidate()
  for slot in 0..<24 {
    let m = result[slot]
    assert_eq(
      (m.position, m.velocity, m.kp, m.kd),
      (
        original[slot].position,
        original[slot].velocity,
        original[slot].kp,
        original[slot].kd,
      ),
    )
    if @e1_elbow_control.leg_slot(slot) {
      assert_true((m.torque - m.kd * 0.02 - tau[slot]).abs() < 1.0e-12)
    } else {
      assert_eq(m.torque, 0.0)
    }
  }
  try sample.reported_leg_effort_shadow_candidate(tau[:], shadow=false) catch {
    _ => ()
  } noraise {
    _ => fail("unqualified reports admitted to powered candidate")
  }
  tau[7] = 0.0
  assert_false(@e1_elbow_control.reported_leg_effort_shadow_available(tau[:]))
  try sample.reported_leg_effort_shadow_candidate(tau[:], shadow=true) catch {
    _ => ()
  } noraise {
    _ => fail("ambiguous zero filled or carried forward")
  }
  tau[7] = 0.0 / 0.0
  assert_false(@e1_elbow_control.reported_leg_effort_shadow_available(tau[:]))
}
