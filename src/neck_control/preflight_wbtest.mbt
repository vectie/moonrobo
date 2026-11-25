///|
test "holding preflight shares startup bound without loosening settling" {
  let f = { ..healthy(8), position: 2052, goal: 2040, }
  assert_true(holding_feedback(f, 1000L))
  assert_false(within_settling_tolerance(f, f.goal))
  assert_true(within_settling_tolerance({ ..f, position: 2051, }, f.goal))
  Guard::new(8).authorize(f, TorqueLimit, 1000L)
  for
    bad in [
      { ..f, position: 2057, },
      { ..f, voltage_tenths: 104, },
      { ..f, temperature: 55, },
      { ..f, load: 250, },
      { ..f, velocity: 4, },
      { ..f, torque: 0, },
      { ..f, goal_time: 1, },
      { ..f, speed_limit: 0, },
      { ..f, goal: 2373, position: 2389, },
    ] {
    assert_false(holding_feedback(bad, 1000L))
  }
  assert_false(holding_feedback(f, 1151L))
  let bus = SimBus::new()
  run_action(bus, Hold) |> ignore
  bus.registers[8][42] = 248
  bus.registers[8][43] = 7
  bus.registers[8][56] = 4
  bus.registers[8][57] = 8
  let count = bus.writes.length()
  let report = run_action(bus, Status)
  assert_true(report.completed && report.holding)
  assert_eq(bus.writes.length(), count)
}
