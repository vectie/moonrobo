///|
test "ten-degree profile binds exact wider envelope without moving neutral" {
  assert_eq(profile().profile_version, 3)
  assert_eq(home(7), 1927)
  assert_eq(home(8), 2047)
  assert_eq(
    intent_parameters(Jog(Right, 10))["neck_travel_limit_degrees"],
    "10",
  )
  for (id, low, high) in [(7, 1813, 2041), (8, 1933, 2161)] {
    assert_true(inside(id, low) && inside(id, high))
    assert_false(inside(id, low - 1) || inside(id, high + 1))
  }
  expect_denied(() => target(Jog(Right, 10), 7, 1928) |> ignore)
  for degrees in [-1, 0, 11, 90] {
    expect_denied(() => intent_parameters(Jog(Right, degrees)) |> ignore)
  }
}

///|
test "all four ten-degree simulations retain one-tick steps and rate limits" {
  for
    (direction, motor, sign) in [
      (Left, 7, -1),
      (Right, 7, 1),
      (Up, 8, -1),
      (Down, 8, 1),
    ] {
    let bus = SimBus::new()
    let report = run_action(bus, Jog(direction, 10))
    assert_true(report.completed && report.holding)
    let last : Map[Int32, (Int32, Int64)] = Map([])
    let mut steps = 0
    for i in 0..<bus.writes.length() {
      let (id, p) = bus.writes[i]
      if p[0] == 42 {
        let goal = p[1].to_int() + p[2].to_int() * 256
        assert_true(inside(id, goal))
        if last.get(id) is Some((previous, time)) {
          assert_eq(goal - previous, sign)
          assert_eq(id, motor)
          assert_true(bus.write_times[i] - time >= 50L)
          steps += 1
        }
        last[id] = (goal, bus.write_times[i])
      }
    }
    assert_eq(steps, 114)
    assert_eq(bus.events.last(), Some("completed-holding-no-cleanup-writes"))
    assert_eq(observe(bus, motor).goal, home(motor) + sign * 114)
  }
}

///|
test "old range receipt cannot authorize new ten-degree profile" {
  let action = Jog(Right, 10)
  let p = profile()
  let intent = @core.command_intent(
    "ten-degree-receipt",
    p.id,
    "control.low.neck",
    @core.operator_requester("neck-regression"),
    parameters=intent_parameters(action),
  )
  let verdict = @core.evaluate_intent(
    {
      profile: p,
      bridge_health: @core.bridge_ok(p.bridge.id, p.id, last_telemetry_age_ms=0),
      approval_id: Some("explicit-ten-degree-review"),
      dry_run_receipt_id: Some("ten-degree-simulation"),
      developer_gate: true,
    },
    intent,
  )
  let receipt = @core.receipt_from_verdict(
    "ten-degree-ready",
    p.bridge.id,
    intent,
    verdict,
    1000L,
  )
  validate_receipt(receipt, action, 1001L)
  for
    parameters in [
      {
        "action": Json(action).stringify(),
        "neck_profile_version": "2",
        "servo_speed_limit": "50",
      },
      {
        "action": Json(action).stringify(),
        "neck_profile_version": "3",
        "servo_speed_limit": "50",
        "neck_travel_limit_degrees": "5",
      },
    ] {
    expect_denied(() => {
      validate_receipt(
        { ..receipt, intent: { ..intent, parameters, }, },
        action,
        1001L,
      )
    })
  }
  let g = Guard::new(8)
  expect_denied(() => g.check_feedback({ ..healthy(8), velocity: 100, }, 1000L))
  assert_eq(g.phase, Faulted)
}
