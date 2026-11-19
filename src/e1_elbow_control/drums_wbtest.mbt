///|
test "alternating drum strokes move only the two elbow records and return" {
  let hold = suspended_hold()
  let path = DrumPath::new(hold[:])
  let mut previous = hold.copy()
  for i in 0..<DRUM_FRAMES {
    let s = sample(i, hold)
    for slot in [ELBOW_SLOT, RIGHT_ELBOW_SLOT] {
      s.motors[slot] = { ..s.motors[slot], position: previous[slot].position, }
    }
    s.motors[9] = { ..s.motors[9], position: -14.0 * RAD, }
    let targets = path.next(s, s.receipt_ms)
    for slot, target in targets {
      assert_eq(
        (target.velocity, target.torque, target.kp, target.kd),
        (hold[slot].velocity, hold[slot].torque, hold[slot].kp, hold[slot].kd),
      )
      if slot != ELBOW_SLOT && slot != RIGHT_ELBOW_SLOT {
        assert_eq(target.position, hold[slot].position)
      }
    }
    if i == 300 || i == 1500 {
      assert_true(
        (targets[3].position - hold[3].position + 10.0 * RAD).abs() < 1.0e-10,
      )
      assert_eq(targets[14].position, hold[14].position)
    }
    if i == 900 || i == 2100 {
      assert_true(
        (targets[14].position - hold[14].position + 10.0 * RAD).abs() < 1.0e-10,
      )
      assert_eq(targets[3].position, hold[3].position)
    }
    previous = targets
  }
  assert_eq(previous[3].position, hold[3].position)
  assert_eq(previous[14].position, hold[14].position)
  let extra = sample(DRUM_FRAMES, hold)
  assert_true(rejected(() => ignore(path.next(extra, extra.receipt_ms))))
}

///|
test "right elbow nonresponse faults and telemetry failures still stop drums" {
  let hold = suspended_hold()
  let path = DrumPath::new(hold[:])
  let mut left = hold[3].position
  let mut stopped = false
  for i in 0..<DRUM_FRAMES {
    let s = sample(i, hold)
    s.motors[3] = { ..s.motors[3], position: left, }
    let targets = path.next(s, s.receipt_ms) catch {
      error => {
        assert_true(error.to_string().contains("following error at slot 14"))
        assert_true(i > 600 && i < 900)
        stopped = true
        break
      }
    }
    left = targets[3].position
  }
  assert_true(stopped)
  for fault in 0..<4 {
    let path = DrumPath::new(hold[:])
    let s = sample(0, hold)
    match fault {
      0 => s.motors[14] = { ..s.motors[14], error: 1, }
      1 => s.motors[14] = { ..s.motors[14], id: 3, }
      2 => s.motors[9] = { ..s.motors[9], position: -60.0 * RAD, }
      _ => s.motors[14] = { ..s.motors[14], position: 0.1, }
    }
    assert_true(rejected(() => ignore(path.next(s, s.receipt_ms))))
  }
  let path = DrumPath::new(hold[:])
  let s = sample(0, hold)
  assert_true(rejected(() => ignore(path.next(s, s.receipt_ms + 41L))))
  let invalid = hold.copy()
  invalid[14] = { ..invalid[14], position: -125.0 * RAD, }
  assert_true(rejected(() => ignore(DrumPath::new(invalid[:]))))
}
