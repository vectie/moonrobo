///|
test "sweep covers four absolute extremes and explicitly returns captured pose" {
  let bus = SimBus::new()
  for (id, position) in [(7, 1948), (8, 2056)] {
    bus.registers[id][56] = (position & 255).to_byte()
    bus.registers[id][57] = (position >> 8).to_byte()
  }
  let before = [observe(bus, 7), observe(bus, 8)]
  let path = movement_waypoints(Sweep(30), before)
  assert_eq(path.map(w => w.label), [
    "center-before", "left", "center-after-left", "up", "center-after-up", "right",
    "center-after-right", "down", "center-after-down", "starting-pose",
  ])
  assert_eq(path[1].targets, [1586, 2047])
  assert_eq(path[3].targets, [1927, 1706])
  assert_eq(path[5].targets, [2268, 2047])
  assert_eq(path[7].targets, [1927, 2388])
  assert_eq(path[9].targets, [1948, 2056])
  let report = run_action(bus, Sweep(30))
  assert_true(report.completed && report.holding)
  assert_eq(report.target_reached, Some(true))
  assert_eq(report.after.map(f => f.position), [1948, 2056])
  assert_eq(bus.events.filter(e => e == "waypoint-completed").length(), 10)
  let last : Map[Int32, (Int32, Int64)] = Map([])
  let visited : Map[Int32, Array[Int32]] = { 7: [], 8: [] }
  for i in 0..<bus.writes.length() {
    let (id, params) = bus.writes[i]
    if params[0] == 42 {
      let goal = params[1].to_int() + (params[2].to_int() << 8)
      assert_true(inside(id, goal))
      if last.get(id) is Some((previous, time)) {
        assert_true((goal - previous).abs() <= 2)
        assert_true(bus.write_times[i] - time >= 50L)
      }
      last[id] = (goal, bus.write_times[i])
      visited[id].push(goal)
    }
  }
  assert_true(visited[7].contains(1586) && visited[7].contains(2268))
  assert_true(visited[8].contains(1706) && visited[8].contains(2388))
  assert_eq(bus.events.last(), Some("completed-holding-no-cleanup-writes"))
}

///|
test "sweep aborts without returning to start or replay after lost acknowledgement" {
  let bus = SimBus::new(fail_reply_after_write=30)
  expect_denied(() => run_action(bus, Sweep(30)) |> ignore)
  assert_eq(bus.writes.length(), 30)
  assert_eq(bus.events.filter(e => e == "waypoint-completed").length(), 1)
  assert_false(bus.events.contains("completed-holding-no-cleanup-writes"))
  assert_true(observe(bus, 7).goal < home(7))
  for degrees in [0, 31, -1] {
    let denied = SimBus::new()
    expect_denied(() => run_action(denied, Sweep(degrees)) |> ignore)
    assert_eq(denied.writes.length(), 0)
  }
}

///|
test "two-tick live rates never overstep odd endpoint or accumulate catch-up credit" {
  assert_eq(next_goal(2267, 2268), 2268)
  assert_eq(next_goal(1707, 1706), 1706)
  assert_eq(live_step(40), (2, 50L))
  assert_eq(live_step(-40), (-2, 50L))
  assert_eq(live_step(21), (2, 96L))
  assert_eq(live_step(20), (1, 50L))
  assert_eq(live_step(1), (1, 1000L))
  let guard_state = armed_guard()
  guard_state.authorize(healthy(7), Step(1929), 1050L)
  expect_denied(() => {
    guard_state.authorize(
      { ..healthy(7), goal: 1929, position: 1929, },
      Step(1931),
      1099L,
    )
  })
}
