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

///|
test "public sweep is explicit and returns its starting pose" {
  let result = @neck_control.simulate(@neck_control.Sweep(30))
  assert_true(result.report.completed && result.report.holding)
  assert_eq(result.report.action, @neck_control.Sweep(30))
  assert_eq(
    result.report.before.map(f => f.position),
    result.report.after.map(f => f.position),
  )
  let parameters = @neck_control.intent_parameters(@neck_control.Sweep(30))
  assert_eq(parameters["maximum_step_ticks"], "2")
  assert_eq(parameters["maximum_target_slew_ticks_per_second"], "40")
}

///|
test "public explicit return is a separate gated action" {
  let action = @neck_control.ReturnToStart(1948, 2056)
  let result = @neck_control.simulate(action)
  assert_true(result.report.completed && result.report.holding)
  assert_eq(result.report.after.map(f => f.position), [1948, 2056])
}
