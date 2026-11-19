///|
fn catalog() -> @policy_skills.Supervisor raise {
  @policy_skills.Supervisor::new("e1-test-v1", [
    {
      id: "motion-one",
      description: "test-only reference",
      reference_id: "clip-one",
      maximum_duration_ms: 500,
      parameters: [
        {
          name: "qualified_parameter",
          minimum: 0.0,
          maximum: 1.0,
          default_value: 0.5,
        },
      ],
    },
  ])
}

///|
fn request() -> @policy_skills.Request {
  {
    request_id: "task-1",
    sequence: 1L,
    catalog_id: "e1-test-v1",
    context_version: 0L,
    expires_at_ms: 1000L,
    proposal: { skill_id: "motion-one", parameters: Map([]), },
  }
}

///|
test "language proposal becomes a qualified reference and observed outcome" {
  let s = catalog()
  let accepted = s.accept(request(), 100L)
  assert_eq(accepted.reference_id, "clip-one")
  assert_eq(accepted.parameters.get("qualified_parameter"), Some(0.5))
  assert_eq(accepted.deadline_ms, 600L)
  assert_true(s.start("task-1", 101L).state is Running)
  assert_true(
    s.finish("task-1", success=true, detail="reference completed").state
    is Completed,
  )
  assert_true(s.accept(request(), 200L).state is Completed)
}

///|
test "invalid stale and conflicting proposals do not replace an active skill" {
  let s = catalog()
  let r = request()
  assert_true(
    try
      s.accept(
        { ..r, proposal: { skill_id: "invented", parameters: Map([]), }, },
        100L,
      )
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try
      s.accept(
        {
          ..r,
          proposal: {
            skill_id: "motion-one",
            parameters: { "qualified_parameter": 2.0 },
          },
        },
        100L,
      )
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  ignore(s.accept(r, 100L))
  assert_true(
    try
      s.accept(
        {
          ..r,
          request_id: "task-2",
          sequence: 2L,
          context_version: s.version(),
        },
        101L,
      )
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try s.accept({ ..r, sequence: 2L, }, 101L) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    s.snapshot(101L) is Some({ request_id: "task-1", state: Accepted, .. }),
  )
}

///|
test "task link loss expires locally and reconnect cannot replay an old command" {
  let s = catalog()
  let r = request()
  ignore(s.accept(r, 100L))
  ignore(s.start("task-1", 101L))
  assert_true(s.snapshot(601L) is Some({ state: Interrupted, .. }))
  assert_true(s.accept(r, 700L).state is Interrupted)
  let next = {
    ..r,
    request_id: "task-2",
    sequence: 2L,
    context_version: s.version(),
    expires_at_ms: 1200L,
  }
  assert_true(s.accept(next, 700L).state is Accepted)
  assert_true(
    s.cancel("task-2", detail="operator takeover").state is Interrupted,
  )
}
