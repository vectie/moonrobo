///|
test "cancellation during prediction suppresses publication" {
  let s = supervisor()
  let writes = Ref(0)
  let stops = Ref(0)
  let runner = @policy_runner.Runner::new(
    s,
    clock=() => 100L,
    history_frames=1,
    observation_width=1,
    goal_width=1,
    action_width=1,
    predict=(_, _) => {
      ignore(s.cancel("request", detail="operator cancelled"))
      [0.5]
    },
    reference=(_, _, _, _) => {
      observation: [0.0],
      goals: [0.0],
      captured_at_ms: 100L,
      complete: false,
    },
    sink=_ => writes.val += 1,
    stop=() => stops.val += 1,
  )
  submit(s)
  assert_true(runner.tick() is Stopped)
  assert_eq(writes.val, 0)
  assert_eq(stops.val, 1)
  assert_true(
    s.snapshot(100L)
    is Some({ state: Interrupted, detail: "operator cancelled", .. }),
  )
}

///|
test "prediction finishing at the deadline cannot reach the sink" {
  for finished_at in [599L, 600L, 601L] {
    let s = supervisor()
    let clock = Ref(100L)
    let writes = Ref(0)
    let stops = Ref(0)
    let runner = @policy_runner.Runner::new(
      s,
      clock=() => clock.val,
      history_frames=1,
      observation_width=1,
      goal_width=1,
      action_width=1,
      maximum_sensor_age_ms=1000L,
      reference=(_, _, _, _) => {
        observation: [0.0],
        goals: [0.0],
        captured_at_ms: 100L,
        complete: false,
      },
      predict=(_, _) => {
        clock.val = finished_at
        [0.5]
      },
      sink=_ => writes.val += 1,
      stop=() => stops.val += 1,
    )
    submit(s)
    let result = runner.tick()
    if finished_at < 600L {
      assert_true(result is Action([0.5]))
      assert_eq(writes.val, 1)
      assert_eq(stops.val, 0)
    } else {
      assert_true(result is Stopped)
      assert_eq(writes.val, 0)
      assert_eq(stops.val, 1)
      assert_true(s.snapshot(finished_at) is Some({ state: Interrupted, .. }))
    }
  }
}

///|
test "telemetry becoming stale during prediction is not published" {
  let s = supervisor()
  let clock = Ref(100L)
  let writes = Ref(0)
  let stops = Ref(0)
  let runner = @policy_runner.Runner::new(
    s,
    clock=() => clock.val,
    history_frames=1,
    observation_width=1,
    goal_width=1,
    action_width=1,
    reference=(_, _, _, _) => {
      observation: [0.0],
      goals: [0.0],
      captured_at_ms: 100L,
      complete: false,
    },
    predict=(_, _) => {
      clock.val = 201L
      [0.5]
    },
    sink=_ => writes.val += 1,
    stop=() => stops.val += 1,
  )
  submit(s)
  assert_true(
    try runner.tick() catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_eq(writes.val, 0)
  assert_eq(stops.val, 1)
  assert_true(s.snapshot(201L) is Some({ state: Failed, .. }))
}

///|
test "reference completion after expiry cannot turn interruption into success" {
  let s = supervisor()
  let clock = Ref(100L)
  let predicts = Ref(0)
  let runner = @policy_runner.Runner::new(
    s,
    clock=() => clock.val,
    history_frames=1,
    observation_width=1,
    goal_width=1,
    action_width=1,
    reference=(_, _, _, _) => {
      clock.val = 600L
      {
        observation: [0.0],
        goals: [0.0],
        captured_at_ms: 600L,
        complete: true,
      }
    },
    predict=(_, _) => {
      predicts.val += 1
      [0.5]
    },
    sink=_ => fail("expired reference reached sink"),
    stop=() => (),
  )
  submit(s)
  assert_true(runner.tick() is Stopped)
  assert_eq(predicts.val, 0)
  assert_true(s.snapshot(600L) is Some({ state: Interrupted, .. }))
}

///|
test "new sensor capture during reference preparation uses its actual time" {
  let s = supervisor()
  let clock = Ref(100L)
  let writes = Ref(0)
  let runner = @policy_runner.Runner::new(
    s,
    clock=() => clock.val,
    history_frames=1,
    observation_width=1,
    goal_width=1,
    action_width=1,
    reference=(_, _, _, _) => {
      clock.val = 110L
      {
        observation: [0.0],
        goals: [0.0],
        captured_at_ms: 110L,
        complete: false,
      }
    },
    predict=(_, _) => {
      clock.val = 120L
      [0.5]
    },
    sink=_ => writes.val += 1,
    stop=() => (),
  )
  submit(s)
  assert_true(runner.tick() is Action([0.5]))
  assert_eq(writes.val, 1)
}

///|
fn replace_during_prediction(
  s : @skills.Supervisor,
  clock : Ref[Int64],
) -> Unit raise {
  clock.val = 120L
  ignore(s.cancel("request", detail="replace old request"))
  ignore(
    s.accept(
      {
        request_id: "next",
        sequence: 2L,
        catalog_id: "fixture",
        context_version: s.version(),
        expires_at_ms: 1000L,
        proposal: { skill_id: "one", parameters: Map([]), },
      },
      120L,
    ),
  )
}

///|
test "replacement during prediction remains accepted until a fresh tick" {
  let s = supervisor()
  let clock = Ref(100L)
  let calls = Ref(0)
  let writes = Ref(0)
  let stops = Ref(0)
  let runner = @policy_runner.Runner::new(
    s,
    clock=() => clock.val,
    history_frames=1,
    observation_width=1,
    goal_width=1,
    action_width=1,
    reference=(_, _, _, now) => {
      observation: [0.0],
      goals: [0.0],
      captured_at_ms: now,
      complete: false,
    },
    predict=(_, _) => {
      if calls.val == 0 {
        replace_during_prediction(s, clock)
      }
      calls.val += 1
      [0.5]
    },
    sink=_ => writes.val += 1,
    stop=() => stops.val += 1,
  )
  submit(s)
  assert_true(runner.tick() is Stopped)
  assert_true(
    s.snapshot(120L) is Some({ request_id: "next", state: Accepted, .. }),
  )
  assert_eq(writes.val, 0)
  assert_eq(stops.val, 1)
  assert_true(runner.tick() is Action([0.5]))
  assert_eq(writes.val, 1)
}

///|
suberror PredictionFailure {
  Original
}

///|
test "cleanup preserves the prediction failure and does not fail a replacement" {
  let s = supervisor()
  let clock = Ref(100L)
  let stops = Ref(0)
  let runner = @policy_runner.Runner::new(
    s,
    clock=() => clock.val,
    history_frames=1,
    observation_width=1,
    goal_width=1,
    action_width=1,
    reference=(_, _, _, now) => {
      observation: [0.0],
      goals: [0.0],
      captured_at_ms: now,
      complete: false,
    },
    predict=(_, _) => {
      replace_during_prediction(s, clock)
      raise PredictionFailure::Original
    },
    sink=_ => fail("failed prediction reached sink"),
    stop=() => stops.val += 1,
  )
  submit(s)
  assert_true(
    try runner.tick() catch {
      PredictionFailure::Original => true
      _ => false
    } noraise {
      _ => false
    },
  )
  assert_true(
    s.snapshot(120L) is Some({ request_id: "next", state: Accepted, .. }),
  )
  assert_eq(stops.val, 1)
}

///|
test "backward clock during prediction fails locally without publication" {
  let s = supervisor()
  let clock = Ref(100L)
  let writes = Ref(0)
  let stops = Ref(0)
  let runner = @policy_runner.Runner::new(
    s,
    clock=() => clock.val,
    history_frames=1,
    observation_width=1,
    goal_width=1,
    action_width=1,
    reference=(_, _, _, now) => {
      observation: [0.0],
      goals: [0.0],
      captured_at_ms: now,
      complete: false,
    },
    predict=(_, _) => {
      clock.val = 99L
      [0.5]
    },
    sink=_ => writes.val += 1,
    stop=() => stops.val += 1,
  )
  submit(s)
  assert_true(
    try runner.tick() catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_eq(writes.val, 0)
  assert_eq(stops.val, 1)
  assert_true(s.snapshot(100L) is Some({ state: Failed, .. }))
}
