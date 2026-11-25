///|
test "direction buttons ignore thumbstick calibration and keep enable and exit" {
  let raw : NativeStickSample = {
    captured_ms: 1000L,
    x: 99999,
    y: -99999,
    min_x: 0,
    max_x: 0,
    min_y: 0,
    max_y: 0,
    zl: true,
    minus: true,
    buttons: 0,
  }
  let c = factory_stick_calibration()
  assert_eq(
    map_input(raw, c, buttons=true),
    stick(deadman=true, exit=true, captured_ms=1000L),
  )
  expect_denied(() => map_input(raw, c, buttons=false) |> ignore)
  for (mask, x, y) in [(1, 0, 600), (2, 0, -600), (4, 600, 0), (8, -600, 0)] {
    let sample = map_input({ ..raw, buttons: mask, }, c, buttons=true)
    assert_eq((sample.x, sample.y), (x, y))
    assert_eq(stick_speed(if x == 0 { y } else { x }).abs(), 20)
    assert_true(sample.deadman && sample.exit)
  }
  for invalid in [-1, 3, 5, 6, 9, 12, 15, 16] {
    expect_denied(() => button_axes(invalid) |> ignore)
  }
}

///|
test "button sessions have separate exact receipts from analog sessions" {
  let p = profile()
  let intent = @core.command_intent(
    "buttons-receipt-test",
    p.id,
    "control.low.neck",
    @core.operator_requester("neck-regression"),
    parameters=intent_parameters(Buttons(300)),
  )
  let verdict = @core.evaluate_intent(
    {
      profile: p,
      bridge_health: @core.bridge_ok(p.bridge.id, p.id, last_telemetry_age_ms=0),
      approval_id: Some("explicit-buttons-approval"),
      dry_run_receipt_id: Some("buttons-simulation"),
      developer_gate: true,
    },
    intent,
  )
  let receipt = @core.receipt_from_verdict(
    "buttons-ready",
    p.bridge.id,
    intent,
    verdict,
    1000L,
  )
  validate_receipt(receipt, Buttons(300), 1001L)
  for
    action in [
      Joystick(300),
      Buttons(299),
      Buttons(301),
      Buttons(0),
      Jog(Right, 1),
    ] {
    expect_denied(() => validate_receipt(receipt, action, 1001L))
  }
}

///|
test "button release stops steps while all directions retain bounded slow targets" {
  for (mask, id, sign) in [(1, 8, 1), (2, 8, -1), (4, 7, 1), (8, 7, -1)] {
    let (x, y) = button_axes(mask)
    let samples = [stick(), stick(deadman=true)]
    for _ in 0..<8 {
      samples.push(stick(x~, y~, deadman=true))
    }
    samples.push(stick())
    for _ in 0..<8 {
      samples.push(stick(x~, y~))
    }
    samples.push(stick(exit=true))
    let bus = SimBus::new(samples~)
    let report = run_action(bus, Buttons(3))
    assert_eq(report.action, Buttons(3))
    let goals = bus.writes.filter(w => w.0 == id && w.1[0] == 42)
    assert_true(goals.length() > 1)
    let mut previous = home(id)
    let mut time = -1L
    for i in 0..<bus.writes.length() {
      let (motor, params) = bus.writes[i]
      if motor == id && params[0] == 42 {
        let goal = params[1].to_int() + params[2].to_int() * 256
        assert_true(inside(id, goal))
        if time >= 0L {
          assert_eq(goal - previous, sign)
          assert_true(bus.write_times[i] - time >= 50L)
        }
        previous = goal
        time = bus.write_times[i]
      }
    }
    assert_true(report.holding)
    assert_eq(bus.registers[7][40], 1)
    assert_eq(bus.registers[8][40], 1)
  }
}

///|
test "held direction cannot arm and button duration and freshness stay bounded" {
  let samples = [stick(x=600), stick(x=600, deadman=true), stick(exit=true)]
  let bus = SimBus::new(samples~)
  run_action(bus, Buttons(2)) |> ignore
  assert_eq(bus.writes.length(), 0)
  for seconds in [0, -1, 301] {
    expect_denied(() => run_action(SimBus::new(), Buttons(seconds)) |> ignore)
  }
  let stale = SimBus::new(samples=[
    stick(),
    stick(deadman=true),
    stick(x=600, deadman=true, captured_ms=0L),
  ])
  expect_denied(() => run_action(stale, Buttons(2)) |> ignore)
  assert_eq(stale.writes.length(), 10)
}
