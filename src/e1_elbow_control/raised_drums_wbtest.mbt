///|
test "raised reference reaches ninety alternates thirty and returns with 22 records fixed" {
  let hold = suspended_hold()
  let path = DrumPath::raised(hold[:])
  let mut previous = hold.copy()
  for i in 0..<RAISED_DRUM_FRAMES {
    let s = sample(i, hold)
    for slot in [3, 14] {
      s.motors[slot] = { ..s.motors[slot], position: previous[slot].position, }
    }
    let targets = path.next(s, s.receipt_ms)
    for slot, target in targets {
      assert_eq(
        (target.velocity, target.torque, target.kp, target.kd),
        (hold[slot].velocity, hold[slot].torque, hold[slot].kp, hold[slot].kd),
      )
      if slot != 3 && slot != 14 {
        assert_eq(target.position, hold[slot].position)
      }
    }
    if i == 3000 || i == 6300 {
      assert_true((targets[3].position / RAD + 90.0).abs() < 1.0e-10)
      assert_true((targets[14].position / RAD + 90.0).abs() < 1.0e-10)
    }
    if i == 3500 || i == 5100 {
      assert_true((targets[3].position / RAD + 60.0).abs() < 1.0e-10)
      assert_true((targets[14].position / RAD + 90.0).abs() < 1.0e-10)
    }
    if i == 4300 || i == 5900 {
      assert_true((targets[14].position / RAD + 60.0).abs() < 1.0e-10)
      assert_true((targets[3].position / RAD + 90.0).abs() < 1.0e-10)
    }
    assert_eq(path.frame_index(), i + 1)
    previous = targets
  }
  assert_eq(previous[3].position, hold[3].position)
  assert_eq(previous[14].position, hold[14].position)
}

///|
test "raised reference waits for a lagging elbow resumes on catchup and retains fault stop" {
  let hold = suspended_hold()
  let path = DrumPath::raised(hold[:])
  let mut previous = hold.copy()
  for tick in 0..<3000 {
    let s = sample(tick, hold)
    s.motors[3] = { ..s.motors[3], position: previous[3].position, }
    previous = path.next(s, s.receipt_ms)
  }
  let paused = path.frame_index()
  assert_true(paused < 3000)
  for tick in 3000..<3010 {
    let s = sample(tick, hold)
    s.motors[3] = { ..s.motors[3], position: previous[3].position, }
    previous = path.next(s, s.receipt_ms)
    assert_eq(path.frame_index(), paused)
  }
  let recovered = sample(3010, hold)
  for slot in [3, 14] {
    recovered.motors[slot] = {
      ..recovered.motors[slot],
      position: previous[slot].position,
    }
  }
  previous = path.next(recovered, recovered.receipt_ms)
  assert_true(path.frame_index() > paused)
  let bad = sample(3011, hold)
  for slot in [3, 14] {
    bad.motors[slot] = {
      ..bad.motors[slot],
      position: previous[slot].position,
    }
  }
  bad.motors[14] = { ..bad.motors[14], error: 1, }
  assert_true(rejected(() => ignore(path.next(bad, bad.receipt_ms))))
  let next = sample(3012, hold)
  assert_true(rejected(() => ignore(path.next(next, next.receipt_ms))))
}

///|
test "paced reference accepts a delayed fresh control tick and rejects expired cadence" {
  let hold = suspended_hold()
  let path = DrumPath::raised(hold[:])
  let first = sample(0, hold)
  ignore(path.next(first, first.receipt_ms))
  let next = sample(1, hold)
  let delayed = {
    ..next,
    receipt_ms: first.receipt_ms + 35L,
    source_ns: first.source_ns + 35000000L,
  }
  ignore(path.next(delayed, delayed.receipt_ms))
  assert_eq(path.frame_index(), 2)
  let overdue = {
    ..sample(2, hold),
    receipt_ms: delayed.receipt_ms + 41L,
    source_ns: delayed.source_ns + 41000000L,
  }
  assert_true(rejected(() => ignore(path.next(overdue, overdue.receipt_ms))))
}
