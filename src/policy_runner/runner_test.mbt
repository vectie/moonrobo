///|
fn supervisor() -> @skills.Supervisor raise {
  @skills.Supervisor::new("fixture", [
    {
      id: "one",
      description: "fixture",
      reference_id: "reference",
      maximum_duration_ms: 500,
      parameters: [],
    },
  ])
}

///|
fn submit(s : @skills.Supervisor) -> Unit raise {
  ignore(
    s.accept(
      {
        request_id: "request",
        sequence: 1L,
        catalog_id: "fixture",
        context_version: s.version(),
        expires_at_ms: 1000L,
        proposal: { skill_id: "one", parameters: Map([]), },
      },
      100L,
    ),
  )
}

///|
test "local shadow loop owns history previous actions and observed completion" {
  let s = supervisor()
  let writes = []
  let stops = Ref(0)
  let clock = Ref(99L)
  let runner = @policy_runner.Runner::new(
    s,
    clock=() => clock.val,
    history_frames=2,
    observation_width=1,
    goal_width=1,
    action_width=1,
    predict=(history, goal) => [history[0][0] + history[1][0] + goal[0]],
    reference=(execution, step, previous, _) => {
      assert_eq(execution.reference_id, "reference")
      {
        observation: [previous[0] + 1.0],
        goals: [2.0],
        captured_at_ms: 100L + step.to_int64() * 20L,
        complete: step == 2,
      }
    },
    sink=action => writes.push(action),
    stop=() => stops.val += 1,
  )
  assert_true(runner.tick() is Idle)
  submit(s)
  clock.val = 100L
  assert_true(runner.tick() is Action([4.0]))
  clock.val = 120L
  assert_true(runner.tick() is Action([8.0]))
  clock.val = 140L
  assert_true(runner.tick() is Stopped)
  assert_true(s.snapshot(140L) is Some({ state: Completed, .. }))
  assert_eq(writes.length(), 2)
  assert_eq(stops.val, 1)
  clock.val = 160L
  assert_true(runner.tick() is Idle)
}

///|
test "expiry and stale telemetry stop locally without another task message" {
  let s = supervisor()
  let writes = Ref(0)
  let stops = Ref(0)
  let captured = Ref(100L)
  let clock = Ref(100L)
  let runner = @policy_runner.Runner::new(
    s,
    clock=() => clock.val,
    history_frames=1,
    observation_width=1,
    goal_width=1,
    action_width=1,
    predict=(_, _) => [0.5],
    reference=(_, _, _, _) => {
      observation: [0.0],
      goals: [0.0],
      captured_at_ms: captured.val,
      complete: false,
    },
    sink=_ => writes.val += 1,
    stop=() => stops.val += 1,
  )
  submit(s)
  ignore(runner.tick())
  clock.val = 201L
  assert_true(
    try runner.tick() catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(s.snapshot(201L) is Some({ state: Failed, .. }))
  assert_eq(writes.val, 1)
  assert_eq(stops.val, 1)
  clock.val = 601L
  assert_true(runner.tick() is Idle)
  // A fresh run expires even if its telemetry would otherwise still be valid.
  let s2 = supervisor()
  let clock2 = Ref(100L)
  let runner2 = @policy_runner.Runner::new(
    s2,
    clock=() => clock2.val,
    history_frames=1,
    observation_width=1,
    goal_width=1,
    action_width=1,
    predict=(_, _) => [0.5],
    reference=(_, _, _, _) => {
      observation: [0.0],
      goals: [0.0],
      captured_at_ms: 100L,
      complete: false,
    },
    sink=_ => writes.val += 1,
    stop=() => stops.val += 1,
  )
  submit(s2)
  ignore(runner2.tick())
  clock2.val = 600L
  assert_true(runner2.tick() is Stopped)
  assert_true(s2.snapshot(600L) is Some({ state: Interrupted, .. }))
  assert_eq(writes.val, 2)
  assert_eq(stops.val, 2)
}
