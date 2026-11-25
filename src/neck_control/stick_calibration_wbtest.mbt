///|
fn measured_stick_calibration() -> StickCalibration {
  {
    ..factory_stick_calibration(),
    operator_confirmed_neutral: true,
    x_center: -225,
    x_max: 500,
  }
}

///|
test "confirmed neutral drift becomes zero input without moving servo zero" {
  let c = measured_stick_calibration()
  validate_stick_calibration(c)
  assert_eq(correct_stick_axis(-225, c.x_min, c.x_center, c.x_max), 0)
  let gate = StickGate::new()
  gate.update(
    stick(
      x=correct_stick_axis(-230, c.x_min, c.x_center, c.x_max),
      captured_ms=1000L,
    ),
    1000L,
  )
  gate.update(
    stick(
      x=correct_stick_axis(-220, c.x_min, c.x_center, c.x_max),
      deadman=true,
      captured_ms=1050L,
    ),
    1050L,
  )
  assert_true(gate.active)
  assert_eq(home(7), 1927)
  assert_eq(home(8), 2047)
  assert_true(inside(7, 1813))
  assert_false(inside(7, 1812))
}

///|
test "measured travel preserves both signs and saturates only input" {
  let c = measured_stick_calibration()
  assert_eq(correct_stick_axis(-1000, c.x_min, c.x_center, c.x_max), -1000)
  assert_eq(correct_stick_axis(500, c.x_min, c.x_center, c.x_max), 1000)
  assert_eq(correct_stick_axis(1000, c.x_min, c.x_center, c.x_max), 1000)
  assert_true(correct_stick_axis(-600, c.x_min, c.x_center, c.x_max) < 0)
  assert_true(correct_stick_axis(100, c.x_min, c.x_center, c.x_max) > 0)
}

///|
test "explicitly confirmed reconnected neutral must not retain the old offset" {
  let old = measured_stick_calibration()
  let current = { ..old, x_center: 0, }
  validate_stick_calibration(current)
  assert_eq(correct_stick_axis(0, old.x_min, old.x_center, old.x_max), 310)
  assert_eq(
    correct_stick_axis(0, current.x_min, current.x_center, current.x_max),
    0,
  )
  assert_eq(home(7), 1927)
  assert_eq(home(8), 2047)
}

///|
test "both explicitly observed neutral clusters fit the unchanged deadzone" {
  let c = { ..measured_stick_calibration(), x_center: -100, }
  validate_stick_calibration(c)
  // Raw neutral band [-280,20] is still 300 wide, the same width as
  // [-380,-80] for the old center. Only the measured band placement changes.
  for raw in [-250, -225, -210, 0, 20] {
    let value = correct_stick_axis(raw, c.x_min, c.x_center, c.x_max)
    assert_eq(stick_speed(value), 0)
  }
  assert_true(
    stick_speed(correct_stick_axis(-350, c.x_min, c.x_center, c.x_max)) < 0,
  )
  assert_true(
    stick_speed(correct_stick_axis(100, c.x_min, c.x_center, c.x_max)) > 0,
  )
}

///|
test "wrong device unconfirmed center and invalid travel cannot authorize calibration" {
  let c = measured_stick_calibration()
  for
    bad in [
      factory_stick_calibration(),
      { ..c, controller: "98:B6:E9:47:BA:4F", },
      { ..c, x_min: 0, },
      { ..c, x_center: -800, },
      { ..c, x_max: 2000, },
      { ..c, y_max: 0, },
      { ..c, x_min: 2147483647, x_center: 500, x_max: -2147483648, },
      { ..c, x_center: -2147483648, },
    ] {
    expect_denied(() => validate_stick_calibration(bad))
  }
}
