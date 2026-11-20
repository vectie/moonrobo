///|
fn settings() -> @e1_actor_elbows.Settings {
  {
    lower_rad: [-1.57, -1.57],
    upper_rad: [0.0, 0.0],
    maximum_speed_rad_s: [0.04, 0.04],
    response_ms: 500,
    engage_ms: 2000,
    policy_authority: 1.0,
  }
}

///|
fn hold() -> Array[@low.MotorCommand] {
  Array::makei(24, i => {
    position: if i == 3 || i == 14 {
      -0.2
    } else {
      i.to_double() * 0.01
    },
    velocity: 0.0,
    torque: 0.0,
    kp: 50.0,
    kd: 5.0,
  })
}

///|
test "fresh predictions change elbow commands while preserving every other field" {
  let base = hold()
  let a = @e1_actor_elbows.Adapter::new(settings(), base[:])
  let b = @e1_actor_elbows.Adapter::new(settings(), base[:])
  let inferred = base.copy()
  inferred[3] = { ..base[3], position: -1.1, }
  inferred[14] = { ..base[14], position: -0.7, }
  let mut previous = base
  for tick in 0..<=800 {
    let now = tick.to_int64() * 20L
    let step = a.next(inferred[:], now, now, "policy")
    let unchanged = b.next(base[:], now, now, "policy")
    for slot in 0..<24 {
      let motor = step.commands[slot]
      if slot == 3 || slot == 14 {
        assert_true(
          (motor.position - previous[slot].position).abs() <= 0.000800000001,
        )
        assert_true(motor.position >= -1.57 && motor.position <= 0.0)
        assert_eq(
          (motor.kp, motor.kd, motor.velocity, motor.torque),
          (50.0, 5.0, 0.0, 0.0),
        )
      } else {
        assert_eq(
          (motor.position, motor.kp, motor.kd, motor.velocity, motor.torque),
          (base[slot].position, base[slot].kp, base[slot].kd, 0.0, 0.0),
        )
      }
    }
    if tick == 800 {
      assert_true(
        step.commands[3].position < unchanged.commands[3].position - 0.3,
      )
      assert_true(
        step.commands[14].position < unchanged.commands[14].position - 0.3,
      )
    }
    previous = step.commands
  }
  for tick in 801..<=1800 {
    let step = a.next(inferred[:], tick.to_int64() * 20L, 0L, "return")
    assert_eq(step.authority, 0.0)
  }
  assert_true(a.returned())
}

///|
test "bounded predictions are explicit and stale inference ticks cannot advance" {
  let base = hold()
  let adapter = @e1_actor_elbows.Adapter::new(settings(), base[:])
  let inferred = base.copy()
  inferred[3] = { ..base[3], position: -10.0, }
  inferred[14] = { ..base[14], position: 10.0, }
  let initial = adapter.next(inferred[:], 0L, 0L, "baseline")
  assert_eq(initial.bounded_elbow_rad, [-0.2, -0.2])
  assert_eq(initial.raw_elbow_rad, [-10.0, 10.0])
  assert_eq(initial.authority, 0.0)
  try adapter.next(inferred[:], 41L, 41L, "policy") catch {
    _ => ()
  } noraise {
    _ => fail("late policy tick accepted")
  }
  try
    @e1_actor_elbows.Adapter::new(
      { ..settings(), maximum_speed_rad_s: [0.0, 1.0], },
      base[:],
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("zero speed accepted")
  }
}

///|
test "caller mutations cannot change an admitted adapter or its command history" {
  let limits = settings()
  let base = hold()
  let adapter = @e1_actor_elbows.Adapter::new(limits, base[:])
  let prediction = base.copy()
  prediction[3] = { ..base[3], position: -1.0, }
  ignore(adapter.next(prediction[:], 0L, 2000L, "policy"))
  limits.lower_rad[0] = -100.0
  limits.upper_rad[0] = 100.0
  limits.maximum_speed_rad_s[0] = 100.0
  base[9] = { ..base[9], position: 99.0, }
  let step = adapter.next(prediction[:], 20L, 2020L, "policy")
  assert_true((step.commands[3].position + 0.2).abs() <= 0.000800000001)
  assert_eq(step.commands[9].position, 0.09)
  step.commands[3] = { ..step.commands[3], position: -100.0, }
  let subsequent = adapter.next(prediction[:], 40L, 2040L, "policy")
  assert_true(subsequent.commands[3].position >= -0.201600000001)
}
