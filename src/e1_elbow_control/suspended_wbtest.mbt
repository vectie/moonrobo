///|
fn suspended_hold() -> Array[@low.MotorCommand] {
  Array::makei(24, i => {
    position: if i == ELBOW_SLOT {
      -0.1
    } else {
      0.0
    },
    velocity: 0.0,
    torque: 0.0,
    kp: if i == 23 {
      0.0
    } else {
      50.0
    },
    kd: 5.0,
  })
}

///|
test "suspended slow fold accepts leg feedback motion while all other command fields stay fixed" {
  let hold = suspended_hold()
  let clip = Clip::slow_fold_return()
  clip.validate()
  assert_eq(clip.tracking_tolerance_deg(), 5.0)
  assert_eq(clip.offset_degrees.length(), 9001)
  assert_eq(clip.offset_degrees[4500], -90.0)
  let path = Path::new(clip, hold[:], suspended=true)
  let mut previous = hold[ELBOW_SLOT].position
  for i in 0..<clip.offset_degrees.length() {
    let status = sample(i, hold)
    status.motors[ELBOW_SLOT] = {
      ..status.motors[ELBOW_SLOT],
      position: previous,
    }
    // Measured settling is accepted for this operator-supported profile.
    status.motors[9] = { ..status.motors[9], position: -14.0 * RAD, }
    let commands = path.next(status, status.receipt_ms)
    for slot, command in commands {
      let original = hold[slot]
      assert_eq(
        (command.velocity, command.torque, command.kp, command.kd),
        (original.velocity, original.torque, original.kp, original.kd),
      )
      if slot != ELBOW_SLOT {
        assert_eq(command.position, original.position)
      }
    }
    previous = commands[ELBOW_SLOT].position
  }
  assert_eq(previous, hold[ELBOW_SLOT].position)
}

///|
test "slow ninety degree reference still stops when the elbow does not respond" {
  let hold = suspended_hold()
  let clip = Clip::slow_fold_return()
  let path = Path::new(clip, hold[:], suspended=true)
  let mut stopped_at = -1
  for i in 0..<clip.offset_degrees.length() {
    let status = sample(i, hold)
    ignore(path.next(status, status.receipt_ms)) catch {
      error => {
        assert_true(error.to_string().contains("elbow following error"))
        stopped_at = i
        break
      }
    }
  }
  assert_true(stopped_at > 0 && stopped_at < 4500)
}

///|
test "suspended profile retains range health and elbow following checks" {
  for fault in 0..<4 {
    let hold = suspended_hold()
    let path = Path::new(Clip::gentle(), hold[:], suspended=true)
    let status = sample(0, hold)
    match fault {
      0 => status.motors[9] = { ..status.motors[9], position: -59.0 * RAD, }
      1 => status.motors[3] = { ..status.motors[3], error: 1, }
      2 => status.motors[3] = { ..status.motors[3], position: 1.0, }
      _ => status.motors[3] = { ..status.motors[3], position: -0.2, }
    }
    assert_true(rejected(() => ignore(path.next(status, status.receipt_ms))))
  }
  let hold = suspended_hold()
  let path = Path::new(Clip::gentle(), hold[:], suspended=true)
  let status = sample(0, hold)
  ignore(path.next(status, status.receipt_ms))
  let next = sample(1, hold)
  next.motors[9] = { ..next.motors[9], position: -14.0 * RAD, }
  ignore(path.next(next, next.receipt_ms))
  let broken = sample(2, hold)
  broken.motors[3] = {
    ..broken.motors[3],
    position: hold[3].position - 2.0 * RAD,
  }
  assert_true(rejected(() => ignore(path.next(broken, broken.receipt_ms))))
}
