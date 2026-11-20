///|
test "typing pose enters and returns smoothly with every non-elbow record fixed" {
  let hold = suspended_hold()
  let path = DrumPath::typing_pose(hold[:])
  let mut previous = hold.copy()
  let mut previous_velocity = [0.0, 0.0]
  let mut maximum_speed = 0.0
  let mut maximum_acceleration = 0.0
  for i in 0..<TYPING_ELBOW_FRAMES {
    let s = sample(i, hold)
    for slot in [3, 14] {
      s.motors[slot] = { ..s.motors[slot], position: previous[slot].position, }
    }
    let targets = path.next(s, s.receipt_ms)
    for slot, target in targets {
      if slot != 3 && slot != 14 {
        assert_eq(target.position, hold[slot].position)
      }
      assert_eq(
        (target.kp, target.kd, target.torque, target.velocity),
        (hold[slot].kp, hold[slot].kd, hold[slot].torque, hold[slot].velocity),
      )
    }
    let velocity = [3, 14].map(slot => {
      (targets[slot].position - previous[slot].position) / 0.02
    })
    for j, value in velocity {
      maximum_speed = maximum_speed.max(value.abs())
      maximum_acceleration = maximum_acceleration.max(
        ((value - previous_velocity[j]) / 0.02).abs(),
      )
    }
    if i == 3000 || i == 3100 {
      assert_eq(targets[3].position, TYPING_LEFT_RAD)
      assert_eq(targets[14].position, TYPING_RIGHT_RAD)
    }
    previous_velocity = velocity
    previous = targets
  }
  // Analytic minimum-jerk bounds for this exact test baseline and duration.
  let delta = (hold[3].position - TYPING_LEFT_RAD)
    .abs()
    .max((hold[14].position - TYPING_RIGHT_RAD).abs())
  assert_true(maximum_speed <= delta * 1.875 / 60.0 + 1.0e-10)
  assert_true(maximum_acceleration <= delta * 5.774 / 3600.0 + 1.0e-10)
  assert_eq(previous[3].position, hold[3].position)
  assert_eq(previous[14].position, hold[14].position)
  assert_eq(path.frame_index(), TYPING_ELBOW_FRAMES)
}

///|
test "typing transfer retains fault latching" {
  let hold = suspended_hold()
  let path = DrumPath::typing_pose(hold[:])
  let bad = sample(0, hold)
  bad.motors[14] = { ..bad.motors[14], error: 1, }
  assert_true(rejected(() => ignore(path.next(bad, bad.receipt_ms))))
  let good = sample(1, hold)
  assert_true(rejected(() => ignore(path.next(good, good.receipt_ms))))
}
