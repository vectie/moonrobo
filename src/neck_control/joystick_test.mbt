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
