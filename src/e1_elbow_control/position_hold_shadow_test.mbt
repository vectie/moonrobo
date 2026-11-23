///|
fn settings() -> @e1_elbow_control.PositionHoldSettings {
  {
    format: "moonrobo.e1-position-hold-shadow.v1",
    power_qualified: false,
    integral_gain_nm_per_rad_s: 50.0,
    bias_limit_nm: Array::makei(24, i => {
      if @e1_elbow_control.leg_slot(i) {
        0.01
      } else {
        0.0
      }
    }),
    slew_limit_nm_per_s: Array::makei(24, i => {
      if @e1_elbow_control.leg_slot(i) {
        0.1
      } else {
        0.0
      }
    }),
    maximum_error_rad: 0.017453292519943295,
  }
}

///|
fn position_sample(
  tick : Int32,
  error~ : Double = 0.0,
) -> @e1_elbow_control.Sample {
  {
    source_ns: 1000000000L + tick.to_int64() * 20000000L,
    receipt_ms: 1000L + tick.to_int64() * 20L,
    motors: Array::makei(24, i => {
      id: i,
      position: if i == 7 {
        -0.1 - error
      } else {
        -0.1
      },
      velocity: 0.0,
      error: 0,
    }),
  }
}

///|
test "position feedback changes only leg effort and preserves every position reference" {
  let baseline = position_sample(0)
  let owner = @e1_elbow_control.PositionHoldShadow::new(
    settings(),
    baseline,
    shadow=true,
  )
  let start = owner.next(baseline, 1000L, shadow=true)
  let next = owner.next(position_sample(1, error=0.001), 1020L, shadow=true)
  assert_true((next[7].torque - 0.001).abs() < 1.0e-12)
  for i in 0..<24 {
    assert_eq(
      (next[i].position, next[i].velocity, next[i].kp, next[i].kd),
      (start[i].position, start[i].velocity, start[i].kp, start[i].kd),
    )
    if i != 7 {
      assert_eq(next[i].torque, 0.0)
    }
  }
  // The API consumes q/qd/errors and clocks, with no reported-torque input.
  assert_eq(next[23].position, 0.0)
}

///|
test "position integrator saturates without hidden windup and reverses immediately" {
  let owner = @e1_elbow_control.PositionHoldShadow::new(
    settings(),
    position_sample(0),
    shadow=true,
  )
  ignore(owner.next(position_sample(0), 1000L, shadow=true))
  let mut last = 0.0
  for tick in 1..<=100 {
    let next = owner.next(
      position_sample(tick, error=0.01),
      1000L + tick.to_int64() * 20L,
      shadow=true,
    )
    assert_true(next[7].torque <= 0.01)
    assert_true((next[7].torque - last).abs() <= 0.002 + 1.0e-12)
    last = next[7].torque
  }
  assert_eq(last, 0.01)
  let reverse = owner.next(
    position_sample(101, error=-0.01),
    3020L,
    shadow=true,
  )
  assert_true((reverse[7].torque - 0.008).abs() < 1.0e-12)
}

///|
test "position hold rejects powered use and invalid budgets" {
  try
    @e1_elbow_control.PositionHoldShadow::new(
      settings(),
      position_sample(0),
      shadow=false,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("position experiment admitted powered use")
  }
  for kind in 0..<5 {
    let s = settings()
    let s = match kind {
      0 => { ..s, power_qualified: true, }
      1 => { ..s, maximum_error_rad: 0.02, }
      2 => { ..s, integral_gain_nm_per_rad_s: 0.0 / 0.0, }
      3 => {
        s.bias_limit_nm[3] = 0.1
        s
      }
      _ => {
        s.slew_limit_nm_per_s[7] = -1.0
        s
      }
    }
    try s.validate() catch {
      _ => ()
    } noraise {
      _ => fail("invalid position hold settings admitted")
    }
  }
}

///|
test "position hold faults latch for drift stale input gaps malformed motors or live promotion" {
  for kind in 0..<7 {
    let owner = @e1_elbow_control.PositionHoldShadow::new(
      settings(),
      position_sample(0),
      shadow=true,
    )
    ignore(owner.next(position_sample(0), 1000L, shadow=true))
    let sample = match kind {
      0 => position_sample(1, error=0.018)
      1 => position_sample(0)
      2 => position_sample(3)
      3 => {
        let s = position_sample(1)
        s.motors[7] = { ..s.motors[7], error: 1, }
        s
      }
      4 => {
        let s = position_sample(1)
        s.motors[23] = { ..s.motors[23], position: 0.0 / 0.0, }
        s
      }
      _ => position_sample(1)
    }
    let now = if kind == 5 { 1061L } else { sample.receipt_ms }
    try owner.next(sample, now, shadow=kind != 6) catch {
      _ => ()
    } noraise {
      _ => fail("invalid position input admitted")
    }
    try owner.next(position_sample(1), 1020L, shadow=true) catch {
      _ => ()
    } noraise {
      _ => fail("position hold fault did not latch")
    }
  }
}

///|
test "toy loaded joint rejects small constant disturbance but large drift still stops" {
  // A numerical plant regression, not an E1 dynamics or takeover qualification.
  for load in [0.15, 3.0] {
    let s = settings()
    s.bias_limit_nm[7] = 7.5
    s.slew_limit_nm_per_s[7] = 7.5
    let owner = @e1_elbow_control.PositionHoldShadow::new(
      s,
      position_sample(0),
      shadow=true,
    )
    let mut q = 0.0
    let mut qd = 0.0
    let mut stopped = false
    let mut peak = 0.0
    for tick in 0..<=750 {
      let sample = position_sample(tick, error=-q)
      let result = owner.next(sample, sample.receipt_ms, shadow=true) catch {
        _ => {
          stopped = true
          break
        }
      }
      peak = peak.max(q.abs())
      let acceleration = (-50.0 * q - 5.0 * qd + result[7].torque - load) / 0.25
      qd += acceleration * 0.02
      q += qd * 0.02
    }
    if load == 0.15 {
      assert_false(stopped)
      assert_true(q.abs() < 1.0e-6)
      assert_true(peak < s.maximum_error_rad)
    } else {
      assert_true(stopped)
    }
  }
}
