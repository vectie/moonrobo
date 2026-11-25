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
  assert_true(inside(7, 1870))
  assert_false(inside(7, 1869))
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
