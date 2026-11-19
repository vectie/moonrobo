///|
fn tape() -> @e1_actor_shadow.ActorReplay {
  {
    format: "moonrobo.actor-replay.v1",
    catalog: {
      catalog_id: "synthetic-shadow",
      context_version: 0L,
      last_sequence: -1L,
      skills: [
        {
          id: "nominal",
          description: "synthetic frames",
          reference_id: "frames",
          maximum_duration_ms: 500,
          parameters: [],
        },
      ],
    },
    request: {
      request_id: "one",
      sequence: 0L,
      catalog_id: "synthetic-shadow",
      context_version: 0L,
      expires_at_ms: 1000L,
      proposal: { skill_id: "nominal", parameters: Map([]), },
    },
    frames: {
      "frames": Array::makei(3, i => {
        captured_at_ms: 100L + i.to_int64() * 20L,
        observation: Array::makei(99, feature => {
          if feature == 64 {
            -999.0
          } else {
            i.to_double()
          }
        }),
        goals: Array::make(73, i.to_double()),
      }),
    },
  }
}

///|
test "shared shadow replay owns history and replaces recorded previous actions" {
  let observed : Array[Array[Double]] = []
  let policy = @e1_actor_shadow.Policy::new(
    history_frames=2,
    goal_width=73,
    physical_actions=23,
    predict=(history, goals) => {
      assert_eq(history.length(), 2)
      let latest = history[1]
      assert_eq(latest[0], goals[0])
      observed.push([history[0][0], latest[0], latest[64]])
      let actions = Array::make(29, 0.0)
      actions[0] = latest[64] + 1.0
      actions
    },
    nominal_setpoints=actions => Array::makei(23, i => actions[i] * 0.1),
  )
  let report = @e1_actor_shadow.replay(policy, tape())
  assert_eq(observed, [[0.0, 0.0, 0.0], [0.0, 1.0, 1.0], [1.0, 2.0, 2.0]])
  guard report
    is {
      "published": False,
      "stop_count": 1,
      "execution": { "state": "Completed", .. },
      "frames": Array(rows),
      ..
    } else {
    fail("shadow did not complete without publication")
  }
  assert_eq(rows.length(), 3)
  for index, row in rows {
    guard row
      is {
        "actions": Array(actions),
        "nominal_setpoints": Array(positions),
        ..
      } else {
      fail("missing shadow results")
    }
    assert_eq(actions.length(), 23)
    assert_eq(actions[0], Json((index + 1).to_double()))
    assert_eq(positions[0], Json((index + 1).to_double() * 0.1))
  }
}

///|
test "shadow rejects unsupported dimensions and broken recordings" {
  try
    @e1_actor_shadow.Policy::new(
      history_frames=0,
      goal_width=73,
      physical_actions=23,
      predict=(_, _) => [],
      nominal_setpoints=_ => [],
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("empty history accepted")
  }
  let policy = @e1_actor_shadow.Policy::new(
    history_frames=1,
    goal_width=73,
    physical_actions=23,
    predict=(_, _) => fail("invalid tape reached inference"),
    nominal_setpoints=_ => fail("invalid tape reached output"),
  )
  let original = tape()
  let frames = original.frames["frames"].copy()
  frames[1] = { ..frames[1], captured_at_ms: 150L, }
  for
    invalid in [
      { ..original, format: "wrong", },
      { ..original, frames: { "frames": frames }, },
      { ..original, frames: Map([]), },
    ] {
    try @e1_actor_shadow.replay(policy, invalid) catch {
      _ => ()
    } noraise {
      _ => fail("invalid shadow recording accepted")
    }
  }
  let broken_positions = @e1_actor_shadow.Policy::new(
    history_frames=1,
    goal_width=73,
    physical_actions=23,
    predict=(_, _) => Array::make(29, 0.0),
    nominal_setpoints=_ => [],
  )
  try @e1_actor_shadow.replay(broken_positions, original) catch {
    _ => ()
  } noraise {
    _ => fail("invalid nominal position dimensions were reported")
  }
}
