///|
fn post_hold(i : Int32, mask : Int32, shift~ : Double = 0.0) -> Packet {
  let p = sample(i)
  for
    bit, (slot, normal, jump) in [
      (9, -8.904159723618188, 1.1558838461290022),
      (10, 2.0234270129539964, -11.935561461016581),
      (20, -5.967441531273238, 1.5632809129356564),
      (21, -2.7425289901514773, -4.656041201833054),
    ] {
    p.q[slot] = (
        normal + shift + (if (mask & (1 << bit)) == 0 { 0.0 } else { jump })
      ) *
      @ankle.RAD
    p.qd[slot] = 1.3 * @ankle.RAD
  }
  p
}

///|
test "isolated confirmation handles new stance and all ankle subsets without releasing suspect values" {
  for shift in [0.0, -2.0, 2.0] {
    for mask in 1..<16 {
      let first = post_hold(0, 0, shift~)
      let d = Detector::new(first, confirm_isolated=true)
      assert_true(d.observe(first) is Use)
      assert_true(d.observe(post_hold(1, 0, shift~)) is Use)
      assert_true(d.observe(post_hold(2, mask, shift~)) is Wait)
      assert_eq(d.good.seq, first.seq + 1)
      assert_eq(d.baseline.q, first.q)
      assert_true(d.observe(post_hold(3, 0, shift~)) is Use)
      assert_eq(d.left_events + d.right_only_events, 1)
      assert_eq(d.max_confirmation_ns, 2850000L)
      assert_eq(d.good.q, first.q)
    }
  }
}

///|
test "isolated confirmation rejects persistence bad recovery bad health and broken continuity" {
  for fault in 0..<12 {
    let first = post_hold(0, 0)
    let d = Detector::new(first, confirm_isolated=true)
    assert_true(d.observe(first) is Use)
    assert_true(d.observe(post_hold(1, 0)) is Use)
    let spike = post_hold(2, 15)
    assert_true(d.observe(spike) is Wait)
    let next = post_hold(3, 0)
    let result = match fault {
      0 => d.observe(post_hold(3, 15))
      1 => d.observe(post_hold(3, 1))
      2 => {
        next.q[9] += 0.11 * @ankle.RAD
        d.observe(next)
      }
      3 => {
        next.q[20] += 0.11 * @ankle.RAD
        d.observe(next)
      }
      4 => {
        next.q[8] += 1.01 * @ankle.RAD
        d.observe(next)
      }
      5 => {
        next.qd[10] = 1.0
        d.observe(next)
      }
      6 => {
        next.error[9] = 1
        d.observe(next)
      }
      7 => d.observe({ ..next, seq: next.seq + 1, })
      8 => d.observe({ ..next, arrival_ns: spike.arrival_ns + 6000001L, })
      9 => d.observe({ ..next, source_ns: spike.source_ns + 6000001L, })
      10 => d.observe({ ..next, source_ns: spike.source_ns, })
      _ => {
        next.q[9] = 0.0 / 0.0
        d.observe(next)
      }
    }
    assert_true(result is Stop(_, _))
    assert_eq(d.good.seq, first.seq + 1)
    assert_eq(d.left_events + d.right_only_events, 0)
  }
}

///|
test "new arbitrary ankle step waits at most one packet while gradual drift trips immediately" {
  for slot in [9, 10, 20, 21] {
    for sign in [-1.0, 1.0] {
      let first = post_hold(0, 0)
      let d = Detector::new(first, confirm_isolated=true)
      assert_true(d.observe(first) is Use)
      assert_true(d.observe(post_hold(1, 0)) is Use)
      let step = post_hold(2, 0)
      step.q[slot] += sign * 3.0 * @ankle.RAD
      assert_true(d.observe(step) is Wait)
      let sustained = post_hold(3, 0)
      sustained.q[slot] = step.q[slot]
      assert_true(d.observe(sustained) is Stop("ankle excursion persisted", _))
      assert_eq(d.good.seq, first.seq + 1)
      let gradual = Detector::new(first, confirm_isolated=true)
      assert_true(gradual.observe(first) is Use)
      for i in 1..<=9 {
        let p = post_hold(i, 0)
        p.q[slot] += sign * i.to_double() * 0.1 * @ankle.RAD
        assert_true(gradual.observe(p) is Use)
      }
      let over = post_hold(10, 0)
      over.q[slot] += sign * 1.01 * @ankle.RAD
      assert_true(gradual.observe(over) is Stop("gradual ankle drift", _))
      assert_eq(gradual.baseline.q, first.q)
    }
  }
}

///|
test "isolated filter never ignores other joints credible velocity or dense alternating anomalies" {
  for slot in [0, 1, 2, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 16, 17, 18, 19, 22] {
    let first = post_hold(0, 0)
    let d = Detector::new(first, confirm_isolated=true)
    assert_true(d.observe(first) is Use)
    assert_true(d.observe(post_hold(1, 0)) is Use)
    let changed = post_hold(2, 15)
    changed.q[slot] += 1.01 * @ankle.RAD
    assert_true(
      d.observe(changed) is Stop("stationary joint outside tolerance", _),
    )
  }
  for slot in [9, 10, 20, 21] {
    let first = post_hold(0, 0)
    let d = Detector::new(first, confirm_isolated=true)
    assert_true(d.observe(first) is Use)
    assert_true(d.observe(post_hold(1, 0)) is Use)
    let moving = post_hold(2, 15)
    moving.qd[slot] = 1.0
    assert_true(
      d.observe(moving) is Stop("ankle excursion corroborated by velocity", _),
    )
  }
  let first = post_hold(0, 0)
  let d = Detector::new(first, confirm_isolated=true)
  assert_true(d.observe(first) is Use)
  assert_true(d.observe(post_hold(1, 0)) is Use)
  assert_true(d.observe(post_hold(2, 15)) is Wait)
  assert_true(d.observe(post_hold(3, 0)) is Use)
  assert_true(
    d.observe(post_hold(4, 15))
    is Stop("ankle excursion lacks stationary history", _),
  )
  let unknown_start = post_hold(0, 15)
  let startup = Detector::new(unknown_start, confirm_isolated=true)
  assert_true(startup.observe(unknown_start) is Use)
  assert_true(startup.observe(post_hold(1, 0)) is Stop(_, _))
}

///|
test "gradual drift diagnosis takes precedence over velocity and history checks" {
  let first = post_hold(0, 0)
  let d = Detector::new(first, confirm_isolated=true)
  assert_true(d.observe(first) is Use)
  let healthy = post_hold(1, 0)
  assert_true(d.observe(healthy) is Use)
  let approaching = post_hold(2, 0)
  approaching.q[9] -= 0.95 * @ankle.RAD
  approaching.qd[9] = -50.0 * @ankle.RAD
  assert_true(d.observe(approaching) is Use)
  let over = post_hold(3, 0)
  over.q[9] -= 1.15 * @ankle.RAD
  over.qd[9] = -48.0 * @ankle.RAD
  assert_true(d.observe(over) is Stop("gradual ankle drift", 9))
  assert_eq(d.good.seq, approaching.seq)
  assert_eq(d.baseline.q, first.q)
}

///|
test "suspended assessment records settling and still rejects SDK ranges faults and gaps" {
  let first = post_hold(0, 0)
  let d = Detector::new(first, confirm_isolated=true, suspended=true)
  assert_true(d.observe(first) is Use)
  let moved = post_hold(1, 0)
  moved.q[9] -= 5.0 * @ankle.RAD
  moved.qd[9] = -50.0 * @ankle.RAD
  assert_true(d.observe(moved) is Use)
  assert_eq(d.good.q, moved.q)
  assert_true(d.pending is None)
  let too_far = post_hold(2, 0)
  too_far.q[9] = -59.0 * @ankle.RAD
  assert_true(
    d.observe(too_far) is Stop("leg feedback outside SDK joint range", 9),
  )
  let unhealthy = Detector::new(first, suspended=true)
  assert_true(unhealthy.observe(first) is Use)
  let bad = post_hold(1, 0)
  bad.error[3] = 1
  assert_true(unhealthy.observe(bad) is Stop(_, _))
  let gap = Detector::new(first, suspended=true)
  assert_true(gap.observe(first) is Use)
  assert_true(
    gap.observe(post_hold(2, 0)) is Stop("packet continuity lost", -1),
  )
}

///|
test "suspended cadence accepts captured 15ms source pause but confirmation stays six milliseconds" {
  let first = post_hold(0, 0)
  let delayed = {
    ..post_hold(1, 0),
    source_ns: first.source_ns + 15647705L,
    arrival_ns: first.arrival_ns + 15700000L,
  }
  let suspended = Detector::new(first, suspended=true)
  assert_true(suspended.observe(first) is Use)
  assert_true(suspended.observe(delayed) is Use)
  let standing = Detector::new(first, confirm_isolated=true)
  assert_true(standing.observe(first) is Use)
  assert_true(standing.observe(delayed) is Stop("packet continuity lost", -1))
  for fault in 0..<4 {
    let detector = Detector::new(first, suspended=true)
    assert_true(detector.observe(first) is Use)
    let bad = match fault {
      0 => { ..delayed, source_ns: first.source_ns + 40000001L, }
      1 => { ..delayed, arrival_ns: first.arrival_ns + 40000001L, }
      2 => { ..delayed, seq: first.seq + 2, }
      _ => { ..delayed, source_ns: first.source_ns, }
    }
    assert_true(detector.observe(bad) is Stop("packet continuity lost", -1))
  }
}

///|
test "isolated pending sample cannot release a target when the stream ends or recovery is late" {
  let clip = @elbow.Clip::gentle()
  for late in [false, true] {
    let data = Array::makei(8, i => post_hold(i, if i == 7 { 15 } else { 0 }))
    if late {
      let next = post_hold(8, 0)
      data.push({ ..next, arrival_ns: next.arrival_ns + 4000000L, })
    }
    // Give the elbow an in-range baseline for the path's independent limits.
    for p in data {
      p.q[3] = -0.1
    }
    let result = replay(
      clip,
      data,
      classify=true,
      track=true,
      confirm_isolated=true,
    )
    assert_true(result.trip is Some(_))
    assert_eq(result.candidates, 1)
    assert_eq(result.max_leg_target_change_rad, 0.0)
  }
}

///|
test "hold transition preserves validated history for an immediate isolated ankle sample" {
  for persist in [false, true] {
    let first = post_hold(0, 0)
    let baseline = Detector::new(first, confirm_isolated=true)
    assert_true(baseline.observe(first) is Use)
    let current = post_hold(1, 0, shift=0.03)
    assert_true(baseline.observe(current) is Use)
    let active = baseline.begin_hold()
    assert_true(active.confirm_isolated)
    assert_eq(active.baseline.q, current.q)
    assert_eq(active.healthy_streak, 2)
    assert_true(active.observe(post_hold(2, 12, shift=0.03)) is Wait)
    assert_eq(active.good.seq, current.seq)
    let result = active.observe(
      post_hold(3, if persist { 12 } else { 0 }, shift=0.03),
    )
    if persist {
      assert_true(result is Stop("ankle excursion persisted", _))
    } else {
      assert_true(result is Use)
      assert_eq(active.right_only_events, 1)
    }
    assert_eq(baseline.baseline.q, first.q)
  }
}

///|
test "hold transition rejects provisional or noncurrent telemetry and retains continuity" {
  let first = post_hold(0, 0)
  let d = Detector::new(first, confirm_isolated=true)
  assert_false(
    try {
      ignore(d.begin_hold())
      true
    } catch {
      _ => false
    },
  )
  assert_true(d.observe(first) is Use)
  let current = post_hold(1, 0)
  assert_true(d.observe(current) is Use)
  let active = d.begin_hold()
  assert_true(active.observe(current) is Stop("packet continuity lost", _))
  assert_true(d.observe(post_hold(2, 15)) is Wait)
  assert_false(
    try {
      ignore(d.begin_hold())
      true
    } catch {
      _ => false
    },
  )
  assert_true(d.observe(post_hold(3, 0)) is Use)
  let recovered = d.begin_hold()
  assert_eq(recovered.healthy_streak, 1)
  assert_true(recovered.observe(post_hold(4, 15)) is Stop(_, _))
  assert_true(d.observe(post_hold(4, 15)) is Stop(_, _))
  assert_false(
    try {
      ignore(d.begin_hold())
      true
    } catch {
      _ => false
    },
  )
}
