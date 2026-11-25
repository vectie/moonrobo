///|
test "all four thirty-degree commands finish 341 guarded steps" {
  for
    (direction, motor, sign) in [
      (Left, 7, -1),
      (Right, 7, 1),
      (Up, 8, -1),
      (Down, 8, 1),
    ] {
    let bus = SimBus::new()
    let report = run_action(bus, Jog(direction, 30))
    assert_true(report.completed && report.holding)
    assert_eq(report.target_reached, Some(true))
    let last : Map[Int32, (Int32, Int64)] = Map([])
    let mut steps = 0
    for i in 0..<bus.writes.length() {
      let (id, params) = bus.writes[i]
      if params[0] == 42 {
        let goal = params[1].to_int() + (params[2].to_int() << 8)
        assert_true(inside(id, goal))
        if last.get(id) is Some((previous, time)) {
          assert_eq(id, motor)
          assert_eq(goal - previous, sign)
          assert_true(bus.write_times[i] - time >= 50L)
          steps += 1
        }
        last[id] = (goal, bus.write_times[i])
      }
    }
    assert_eq(steps, 341)
    assert_eq(observe(bus, motor).position, home(motor) + sign * 341)
    assert_eq(
      bounded_step_count(motor, home(motor), home(motor) + sign * 341),
      341,
    )
  }
  assert_eq(bounded_step_count(7, 1586, 2268), 682)
  expect_denied(() => bounded_step_count(7, 1585, 2268) |> ignore)
  expect_denied(() => bounded_step_count(8, 1706, 2389) |> ignore)
}

///|
test "safe static offset completes holding with explicit missed accuracy" {
  for bias in [11, 12, 16] {
    let bus = SimBus::new(tracking_bias=bias)
    let report = run_action(bus, Jog(Up, 30))
    assert_true(report.completed && report.holding)
    assert_eq(report.target_reached, Some(bias <= 11))
    assert_eq(report.after[1].position - report.after[1].goal, bias)
    assert_eq(bus.writes.length(), 351)
  }
  let bus = SimBus::new(tracking_bias=17)
  expect_denied(() => run_action(bus, Jog(Up, 30)) |> ignore)
  let count = bus.writes.length()
  assert_eq(count, 11)
  assert_eq(bus.writes.last().unwrap().1[0], 42)
  assert_false(bus.events.contains("completed-holding-no-cleanup-writes"))
}

///|
test "settling rejects moving and oscillating residuals without changing accuracy" {
  let s = Settling::new()
  let f = { ..healthy(8), goal: 2047, position: 2059, }
  for _ in 0..<40 {
    s.observe(f, 2047)
  }
  assert_eq(s.exact_samples, 0)
  assert_eq(s.stable_samples, 40)
  s.observe({ ..f, velocity: 100, }, 2047)
  assert_eq(s.stable_samples, 0)
  for i in 0..<40 {
    s.observe({ ..f, position: 2059 + i % 2, }, 2047)
  }
  assert_eq(s.stable_samples, 1)
  s.observe({ ..f, position: 2064, }, 2047)
  assert_eq(s.stable_samples, 0)
  let g = Guard::new(8)
  expect_denied(() => g.check_feedback(f, 1151L))
}
