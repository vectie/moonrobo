///|
test "pulse candidate accepts only the explicitly reviewed raw velocity range" {
  for id in [7, 8] {
    for velocity in [-100, 0, 60, 100] {
      Guard::new(id).check_feedback({ ..healthy(id), velocity, }, 1000L)
    }
    for velocity in [-101, 101, -200, 200] {
      let g = Guard::new(id)
      expect_denied(() => g.check_feedback({ ..healthy(id), velocity, }, 1000L))
      assert_eq(g.phase, Faulted)
      g.check_feedback(healthy(id), 1001L)
      assert_eq(g.phase, Faulted)
      expect_denied(() => g.authorize(healthy(id), Enable, 1001L))
    }
  }
  let g = armed_guard()
  g.authorize({ ..healthy(7), velocity: 100, }, Step(1928), 1050L)
  assert_eq(g.last_goal, 1928)
  expect_denied(() => {
    g.authorize(
      { ..healthy(7), goal: 1928, position: 1928, velocity: 101, },
      Step(1929),
      1100L,
    )
  })
  assert_eq(g.last_goal, 1928)
  assert_eq(g.phase, Faulted)
}

///|
test "velocity approval is exact and cannot reuse old profile or limit" {
  let action = Jog(Left, 10)
  let p = profile()
  let parameters = intent_parameters(action)
  assert_eq(parameters["raw_feedback_velocity_limit"], "100")
  let intent = @core.command_intent(
    "pulse-receipt",
    p.id,
    "control.low.neck",
    @core.operator_requester("neck-regression"),
    parameters~,
  )
  let verdict = @core.evaluate_intent(
    {
      profile: p,
      bridge_health: @core.bridge_ok(p.bridge.id, p.id, last_telemetry_age_ms=0),
      approval_id: Some("explicit-pulse-review"),
      dry_run_receipt_id: Some("pulse-simulation"),
      developer_gate: true,
    },
    intent,
  )
  let receipt = @core.receipt_from_verdict(
    "pulse-ready",
    p.bridge.id,
    intent,
    verdict,
    1000L,
  )
  validate_receipt(receipt, action, 1001L)
  for (version, limit) in [("3", "60"), ("4", "60"), ("4", "101"), ("5", "100")] {
    let wrong = parameters.copy()
    wrong["neck_profile_version"] = version
    wrong["raw_feedback_velocity_limit"] = limit
    expect_denied(() => {
      validate_receipt(
        { ..receipt, intent: { ..intent, parameters: wrong, }, },
        action,
        1001L,
      )
    })
  }
}
