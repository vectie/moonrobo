///|
fn healthy(id : Int32, now~ : Int64 = 1000L) -> Feedback {
  {
    id,
    captured_ms: now,
    mode: 0,
    torque: 1,
    acceleration: 3,
    goal: if id == 7 {
      1927
    } else {
      2047
    },
    goal_time: 0,
    speed_limit: 50,
    torque_limit: 300,
    position: if id == 7 {
      1927
    } else {
      2047
    },
    velocity: 0,
    load: 20,
    voltage_tenths: 123,
    temperature: 30,
    current_raw: 10,
    status: 0,
  }
}

///|
fn expect_denied(f : () -> Unit raise) -> Unit raise {
  assert_true(
    try {
      f()
      false
    } catch {
      _ => true
    },
  )
}

///|
test "exact incident regression release then stale zero cannot reenergize" {
  let g = Guard::new(7)
  let frame = healthy(7)
  g.authorize(frame, ReleaseTorque, 1000L)
  for
    operation in [
      Step(0),
      LatchPresent,
      Enable,
      TorqueLimit,
      SpeedLimit,
      Acceleration,
    ] {
    expect_denied(() => g.authorize(frame, operation, 2000L))
  }
  assert_eq(g.phase, Faulted)
}

///|
test "power-on stale goal zero is replaced only after bounded profile readback" {
  let bus = SimBus::new()
  let report = run_action(bus, Hold)
  assert_true(report.holding)
  for id in [7, 8] {
    let commands = bus.writes.filter(w => w.0 == id).map(w => w.1)
    assert_eq(commands.length(), 5)
    assert_eq(commands[0], [48, 44, 1])
    assert_eq(commands[1], [46, 50, 0])
    assert_eq(commands[2], [41, 3])
    assert_eq(commands[3][0], 42)
    assert_eq(
      commands[3][1].to_int() + (commands[3][2].to_int() << 8),
      home(id),
    )
    assert_eq(commands[4], [40, 1])
    assert_eq(bus.registers[id][40], 1)
  }
  assert_eq(bus.events.last(), Some("completed-holding-no-cleanup-writes"))
}

///|
test "arming without latch or with unbounded profile is denied" {
  for command in [Enable, Step(1928)] {
    expect_denied(() => Guard::new(7).authorize(healthy(7), command, 1000L))
  }
  for
    frame in [
      { ..healthy(7), speed_limit: 0, },
      { ..healthy(7), torque_limit: 1000, },
      { ..healthy(7), acceleration: 0, },
      { ..healthy(7), goal_time: 100, },
    ] {
    expect_denied(() => Guard::new(7).authorize(frame, LatchPresent, 1000L))
  }
}

///|
test "stale future wrong motor and unhealthy feedback latch the fault" {
  for
    frame in [
      { ..healthy(7), captured_ms: 0L, },
      { ..healthy(7), captured_ms: 2000L, },
      healthy(8),
      { ..healthy(7), mode: 1, },
      { ..healthy(7), status: 32, },
      { ..healthy(7), position: 0, },
      { ..healthy(7), load: 619, },
      { ..healthy(7), current_raw: 250, },
      { ..healthy(7), voltage_tenths: 90, },
      { ..healthy(7), temperature: 60, },
    ] {
    let g = Guard::new(7)
    expect_denied(() => g.authorize(frame, LatchPresent, 1000L))
    assert_eq(g.phase, Faulted)
    // Healthy telemetry later must not silently clear the fault.
    expect_denied(() => g.authorize(healthy(7), LatchPresent, 1001L))
  }
}

///|
fn armed_guard() -> Guard raise {
  let g = Guard::new(7)
  g.authorize(healthy(7), LatchPresent, 1000L)
  g.authorize(healthy(7), Enable, 1001L)
  g
}

///|
test "rate limiter rejects large jumps too fast steps and raw zero" {
  for (goal, now) in [(0, 1100L), (1930, 1100L), (1928, 1010L), (1985, 1100L)] {
    expect_denied(() => armed_guard().authorize(healthy(7), Step(goal), now))
  }
  let g = armed_guard()
  g.authorize(healthy(7), Step(1928), 1050L)
  assert_eq(g.last_goal, 1928)
}

///|
test "power reset external command and torque loss cannot auto resume" {
  for
    frame in [
      { ..healthy(7), speed_limit: 0, },
      { ..healthy(7), torque: 0, },
      { ..healthy(7), goal: 0, },
      { ..healthy(7), goal: 1980, },
      { ..healthy(7), position: 1900, },
    ] {
    let g = armed_guard()
    expect_denied(() => g.authorize(frame, Step(1928), 1100L))
    assert_eq(g.phase, Faulted)
  }
}

///|
test "status sends zero writes and release has no cleanup reactivation" {
  let observation = SimBus::new()
  run_action(observation, Status) |> ignore
  assert_eq(observation.writes.length(), 0)
  let release = SimBus::new()
  run_action(release, Release) |> ignore
  assert_eq(release.writes, [(7, [40, 0]), (8, [40, 0])])
  assert_eq(release.registers[7][40], 0)
  assert_eq(release.registers[8][40], 0)
}

///|
test "invalid pair target and audit failure produce no writes" {
  let bus = SimBus::new()
  expect_denied(() => run_action(bus, Jog(Left, 90)) |> ignore)
  assert_eq(bus.writes.length(), 0)
  let failed = SimBus::new(fail_audit=true)
  expect_denied(() => run_action(failed, Hold) |> ignore)
  assert_eq(failed.writes.length(), 0)
}

///|
test "all four directions are bounded incremental motion with no success restore" {
  for direction in [Left, Up, Right, Down] {
    let bus = SimBus::new()
    let result = run_action(bus, Jog(direction, 2))
    assert_true(result.holding)
    assert_eq(bus.registers[7][40], 1)
    assert_eq(bus.registers[8][40], 1)
    for (id, parameters) in bus.writes {
      assert_true(parameters[0] >= 40 && parameters[0] <= 48)
      assert_true(parameters.length() <= 3)
      if parameters[0] == 42 {
        let goal = parameters[1].to_int() + (parameters[2].to_int() << 8)
        assert_true(inside(id, goal))
        assert_true(goal != 0)
      }
    }
    assert_eq(bus.events.last(), Some("completed-holding-no-cleanup-writes"))
  }
}

///|
test "valid replies and corrupt wrong-id truncated error packets" {
  assert_eq(
    response_payload(b"\xff\xff\x07\x04\x00\x09\x03\xe8", 7, 2),
    b"\x09\x03",
  )
  for
    raw in [
      b"\xff\xff\x07\x04\x00\x09\x03\x00", b"\xff\xff\x08\x04\x00\x09\x03\xe7", b"\xff\xff\x07\x04",
      b"\xff\xff\x07\x02\x20\xd6",
    ] {
    expect_denied(() => response_payload(raw, 7, 2) |> ignore)
  }
}

///|
test "slow audit persistence cannot dispatch expired authorized writes" {
  let bus = SimBus::new(audit_delay_ms=200)
  expect_denied(() => run_action(bus, Hold) |> ignore)
  assert_eq(bus.writes.length(), 0)
}

///|
test "changed factory speed scale rejects motion before any write" {
  let bus = SimBus::new()
  bus.registers[8][82] = 25
  expect_denied(() => run_action(bus, Hold) |> ignore)
  assert_eq(bus.writes.length(), 0)
}

///|
test "feedback pulse candidate has an explicit hard velocity cap" {
  let guard_state = Guard::new(7)
  guard_state.check_feedback({ ..healthy(7), velocity: 100, }, 1000L)
  expect_denied(() => {
    guard_state.check_feedback({ ..healthy(7), velocity: 101, }, 1000L)
  })
}

///|
test "existing MoonRobo gate and exact fresh execution receipt are required" {
  let action = Jog(Left, 2)
  let p = profile()
  let intent = @core.command_intent(
    "neck-test",
    p.id,
    "control.low.neck",
    @core.operator_requester("neck-regression"),
    parameters=intent_parameters(action),
  )
  let context : @core.SafetyContext = {
    profile: p,
    bridge_health: @core.bridge_ok(p.bridge.id, p.id, last_telemetry_age_ms=0),
    approval_id: Some("test-explicit-approval"),
    dry_run_receipt_id: Some("test-simulation"),
    developer_gate: true,
  }
  let verdict = @core.evaluate_intent(context, intent)
  assert_eq(verdict.decision, Allow)
  let receipt = @core.receipt_from_verdict(
    "neck-ready",
    p.bridge.id,
    intent,
    verdict,
    1000L,
  )
  validate_receipt(receipt, action, 1001L)
  let legacy = { ..intent, parameters: { "action": Json(action).stringify() }, }
  expect_denied(() => {
    validate_receipt({ ..receipt, intent: legacy, }, action, 1001L)
  })
  let wrong_speed = {
    ..intent,
    parameters: {
      "action": Json(action).stringify(),
      "neck_profile_version": "2",
      "servo_speed_limit": "20",
    },
  }
  expect_denied(() => {
    validate_receipt({ ..receipt, intent: wrong_speed, }, action, 1001L)
  })
  expect_denied(() => validate_receipt(receipt, Jog(Right, 2), 1001L))
  expect_denied(() => validate_receipt(receipt, action, 61001L))
  expect_denied(() => validate_receipt(receipt, action, 999L))
  expect_denied(() => {
    validate_receipt({ ..receipt, status: Executed, }, action, 1001L)
  })
  assert_true(
    @core.evaluate_intent({ ..context, approval_id: None, }, intent).decision !=
    Allow,
  )
  assert_true(
    @core.evaluate_intent({ ..context, dry_run_receipt_id: None, }, intent).decision !=
    Allow,
  )
  assert_true(
    @core.evaluate_intent({ ..context, developer_gate: false, }, intent).decision !=
    Allow,
  )
}

///|
test "lost acknowledgement stops without retry cleanup goal restore or torque release" {
  let bus = SimBus::new(fail_reply_after_write=12)
  expect_denied(() => run_action(bus, Jog(Left, 2)) |> ignore)
  assert_eq(bus.writes.length(), 12)
  assert_eq(bus.writes.last().unwrap().1[0], 42)
  assert_eq(bus.registers[7][40], 1)
  assert_eq(bus.registers[8][40], 1)
  assert_eq(bus.registers[7][46], 50)
  assert_eq(bus.registers[7][47], 0)
  assert_eq(bus.registers[7][48], 44)
  assert_eq(bus.registers[7][49], 1)
}

///|
test "raw historical cleanup packet is rejected before audit or serial dispatch" {
  let serial : Serial = {
    fd: -1,
    log_path: "/nonexistent/never-created.jsonl",
    run_id: "raw-write-test",
    sequence: 0,
    writes: 0,
    joystick: None,
    stick_required: false,
  }
  expect_denied(() => {
    serial.transfer(7, 3, [41, 0, 0, 0, 0, 0, 0, 0, 232, 3], 0, 1000L) |> ignore
  })
  expect_denied(() => serial.transfer(7, 3, [42, 0, 0], 0, 1000L) |> ignore)
  expect_denied(() => serial.transfer(7, 3, [46, 0, 0], 0, 1000L) |> ignore)
  expect_denied(() => serial.transfer(7, 3, [48, 232, 3], 0, 1000L) |> ignore)
  assert_eq(serial.writes, 0)
  assert_eq(serial.sequence, 0)
}

///|
test "durable marker and one-use intent journal survive a new caller" {
  let path = "/tmp/moonrobo-neck-policy-\{clock_ms()}"
  let bytes = @utf8.encode(path)
  assert_eq(latch_fault(bytes), 0)
  assert_eq(fault_exists(bytes), 1)
  assert_eq(clear_fault(bytes), 0)
  assert_eq(fault_exists(bytes), 0)
  assert_eq(consume_receipt(bytes), 0)
  assert_true(consume_receipt(bytes) < 0)
  assert_eq(clear_fault(bytes), 0)
}

///|
test "inactive tilt power reset halts pan command generation too" {
  let bus = SimBus::new(reset_inactive_after_write=11)
  expect_denied(() => run_action(bus, Jog(Left, 2)) |> ignore)
  assert_eq(bus.writes.length(), 11)
  assert_eq(bus.registers[8][40], 0)
  assert_eq(bus.registers[7][40], 1)
}
