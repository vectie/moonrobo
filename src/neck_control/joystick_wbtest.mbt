///|
fn stick(
  x~ : Int32 = 0,
  y~ : Int32 = 0,
  deadman~ : Bool = false,
  exit~ : Bool = false,
  captured_ms~ : Int64 = -1L,
) -> StickSample {
  { captured_ms, x, y, deadman, exit, }
}

///|
test "input setup requires matching positive acknowledgement" {
  let good : Bytes = [0x21, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0x40]
  validate_stick_setup_reply(good, 0x40)
  expect_denied(() => validate_stick_setup_reply(good, 3))
  expect_denied(() => validate_stick_setup_reply(b"", 0x40))
  let nack = good.to_array()
  nack[13] = 0
  expect_denied(() => validate_stick_setup_reply(Bytes::from_array(nack), 0x40))
}

///|
test "held trigger or deflected stick at startup cannot arm" {
  let gate = StickGate::new()
  for
    sample in [
      stick(deadman=true),
      stick(x=1000, deadman=true),
      stick(),
      stick(x=1000, deadman=true),
      stick(deadman=true),
    ] {
    gate.update({ ..sample, captured_ms: 1000L, }, 1000L)
    assert_false(gate.active)
  }
  gate.update(stick(captured_ms=1000L), 1000L)
  gate.update(stick(deadman=true, captured_ms=1050L), 1050L)
  assert_true(gate.active)
  gate.update(stick(x=-1000, deadman=true, captured_ms=1100L), 1100L)
  assert_true(gate.active)
  gate.update(stick(x=-1000, captured_ms=1150L), 1150L)
  assert_false(gate.active)
  gate.update(stick(x=-1000, deadman=true, captured_ms=1200L), 1200L)
  assert_false(gate.active)
}

///|
test "deadzone calibrated endpoints and proportional rates" {
  assert_eq(calibrated_axis(-32767, -32767, 32767), -1000)
  assert_eq(calibrated_axis(0, -32767, 32767), 0)
  assert_eq(calibrated_axis(32767, -32767, 32767), 1000)
  for value in [-200, -1, 0, 1, 200] {
    assert_eq(stick_speed(value), 0)
  }
  assert_eq(stick_speed(-1000), -20)
  assert_eq(stick_speed(1000), 20)
  assert_eq(stick_speed(600), 10)
  expect_denied(() => calibrated_axis(0, 0, 0) |> ignore)
  expect_denied(() => calibrated_axis(32768, -32767, 32767) |> ignore)
}

///|
test "stale future invalid and stalled input fail closed" {
  for
    sample in [
      stick(captured_ms=0L),
      stick(captured_ms=1100L),
      stick(x=1001, captured_ms=1000L),
    ] {
    expect_denied(() => StickGate::new().update(sample, 1000L))
  }
  let gate = StickGate::new()
  gate.update(stick(captured_ms=1000L), 1000L)
  expect_denied(() => gate.update(stick(captured_ms=1300L), 1300L))
}

///|
test "joystick receipt authorizes exactly one bounded duration" {
  let p = profile()
  let intent = @core.command_intent(
    "joystick-receipt-test",
    p.id,
    "control.low.neck",
    @core.operator_requester("neck-regression"),
    parameters=intent_parameters(Joystick(120)),
  )
  let verdict = @core.evaluate_intent(
    {
      profile: p,
      bridge_health: @core.bridge_ok(p.bridge.id, p.id, last_telemetry_age_ms=0),
      approval_id: Some("explicit-session-approval"),
      dry_run_receipt_id: Some("joystick-simulation"),
      developer_gate: true,
    },
    intent,
  )
  let receipt = @core.receipt_from_verdict(
    "joystick-ready",
    p.bridge.id,
    intent,
    verdict,
    1000L,
  )
  validate_receipt(receipt, Joystick(120), 1001L)
  for action in [Joystick(121), Joystick(301), Joystick(0), Hold, Jog(Left, 2)] {
    expect_denied(() => validate_receipt(receipt, action, 1001L))
  }
}

///|
test "neutral idle held trigger and minus exit send no motor writes" {
  for
    samples in [
      [stick(), stick(), stick(exit=true)],
      [stick(deadman=true), stick(x=1000, deadman=true), stick(exit=true)],
      [stick(), stick(exit=true, deadman=true)],
    ] {
    let bus = SimBus::new(samples~)
    run_action(bus, Joystick(1)) |> ignore
    assert_eq(bus.writes.length(), 0)
  }
  for duration in [0, -1, 301] {
    let bus = SimBus::new()
    expect_denied(() => run_action(bus, Joystick(duration)) |> ignore)
    assert_eq(bus.writes.length(), 0)
  }
}

///|
test "session expiry during input I/O cannot arm or dispatch" {
  let bus = SimBus::new(samples=[stick(deadman=true)], stick_delay_ms=1000)
  let report = run_action(bus, Joystick(1))
  assert_true(report.completed)
  assert_eq(bus.writes.length(), 0)
}

///|
test "joystick all directions use one tick steps and release stops without recenter" {
  for
    (x, y, id, delta) in [
      (-1000, 0, 7, -1),
      (1000, 0, 7, 1),
      (0, -1000, 8, -1),
      (0, 1000, 8, 1),
    ] {
    let samples = [stick(), stick(deadman=true)]
    for _ in 0..<5 {
      samples.push(stick(x~, y~, deadman=true))
    }
    for _ in 0..<5 {
      samples.push(stick(x~, y~))
    }
    samples.push(stick(exit=true))
    let bus = SimBus::new(samples~)
    let report = run_action(bus, Joystick(2))
    assert_true(report.holding)
    assert_eq(bus.writes.length(), 15)
    let goals = bus.writes
      .filter(w => w.0 == id && w.1[0] == 42)
      .map(w => w.1[1].to_int() + (w.1[2].to_int() << 8))
    assert_eq(goals, [
      home(id),
      home(id) + delta,
      home(id) + 2 * delta,
      home(id) + 3 * delta,
      home(id) + 4 * delta,
      home(id) + 5 * delta,
    ])
    assert_eq(bus.registers[7][40], 1)
    assert_eq(bus.registers[8][40], 1)
    assert_eq(bus.events.last(), Some("completed-holding-no-cleanup-writes"))
  }
}

///|
test "diagonal motion stops at absolute bounds no catch-up or target replay" {
  let samples = [stick(), stick(deadman=true)]
  for _ in 0..<400 {
    samples.push(stick(x=1000, y=1000, deadman=true))
  }
  samples.push(stick(exit=true))
  let bus = SimBus::new(samples~)
  run_action(bus, Joystick(40)) |> ignore
  for id in [7, 8] {
    let f = observe(bus, id)
    assert_eq(f.goal, home(id) + 341)
    assert_true(inside(id, f.goal))
  }
  assert_eq(bus.writes.length(), 692)
  let last_goal : Map[Int32, Int32] = Map([])
  let last_time : Map[Int32, Int64] = Map([])
  for i in 0..<bus.writes.length() {
    let (id, params) = bus.writes[i]
    if params[0] == 42 {
      let goal = params[1].to_int() + (params[2].to_int() << 8)
      if last_goal.get(id) is Some(previous) {
        assert_true((goal - previous).abs() <= 1)
        assert_true(bus.write_times[i] - last_time[id] >= 50L)
      }
      last_goal[id] = goal
      last_time[id] = bus.write_times[i]
    }
  }
}

///|
test "lost input stale input inactive-axis reset and lost ACK halt joystick writes" {
  let samples = [
    stick(),
    stick(deadman=true),
    stick(x=1000, deadman=true),
    stick(captured_ms=0L),
  ]
  let bus = SimBus::new(samples~)
  expect_denied(() => run_action(bus, Joystick(2)) |> ignore)
  assert_eq(bus.writes.length(), 11)
  assert_eq(bus.writes.last().unwrap().1[0], 42)
  for
    bus in [
      SimBus::new(samples~, fail_reply_after_write=11),
      SimBus::new(samples~, reset_inactive_after_write=11),
    ] {
    expect_denied(() => run_action(bus, Joystick(2)) |> ignore)
    assert_eq(bus.writes.length(), 11)
  }
}
