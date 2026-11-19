///|
test "explicit runner interruption is idempotent and preserves a replacement" {
  for replace in [false, true] {
    let s = supervisor()
    let stops = Ref(0)
    let runner = @policy_runner.Runner::new(
      s,
      clock=() => 100L,
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
      predict=(_, _) => [0.5],
      sink=_ => (),
      stop=() => stops.val += 1,
    )
    runner.interrupt(detail="idle")
    assert_eq(stops.val, 0)
    submit(s)
    ignore(runner.tick())
    if replace {
      replace_during_prediction(s, Ref(100L))
    }
    runner.interrupt(detail="host ended")
    runner.interrupt(detail="repeat")
    assert_eq(stops.val, 1)
    if replace {
      assert_true(
        s.snapshot(120L) is Some({ request_id: "next", state: Accepted, .. }),
      )
    } else {
      assert_true(
        s.snapshot(100L)
        is Some(
          {
            request_id: "request",
            state: Interrupted,
            detail: "host ended",
            ..
          }
        ),
      )
    }
  }
}
