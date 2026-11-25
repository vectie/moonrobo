///|
test "public joystick simulation remains explicitly simulated and bounded" {
  let simulated = simulate(Joystick(2))
  assert_true(simulated.simulated)
  assert_true(simulated.report.completed)
  assert_true(simulated.report.holding)
  assert_true(simulated.writes.length() > 10)
}

///|
test "public direction button simulation is a distinct bounded action" {
  let simulated = simulate(Buttons(3))
  assert_true(simulated.simulated && simulated.report.completed)
  assert_eq(simulated.report.action, Buttons(3))
  assert_true(simulated.report.holding)
  assert_true(simulated.writes.length() > 10)
}

///|
test "public thirty-degree report distinguishes completion and accuracy" {
  let result = @neck_control.simulate(
    @neck_control.Jog(@neck_control.Right, 30),
  )
  assert_true(
    result.simulated && result.report.completed && result.report.holding,
  )
  assert_eq(result.report.target_reached, Some(true))
  assert_eq(
    result.report.after[0].position - result.report.before[0].position,
    341,
  )
  let release = @neck_control.simulate(@neck_control.Release)
  assert_eq(release.report.target_reached, None)
}
