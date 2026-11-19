///|
test "rotation and transport remove fixed world error motion" {
  let rate = 0.7
  let dt = 0.02
  let errors = Array::makei(30, fn(i) {
    let a = i.to_double() * rate * dt
    [
      0.03 * @math.cos(a) + 0.04 * @math.sin(a),
      -0.03 * @math.sin(a) + 0.04 * @math.cos(a),
      0.0,
    ]
  })
  let gravity = Array::makei(30, fn(_) { [0.0, 0.0, -1.0] })
  let omega = Array::makei(30, fn(_) { [0.0, 0.0, rate] })
  let methods : Array[TransportMethod] = [Gyro, GravityGyro]
  for method in methods {
    let transports = observation_transports(gravity, omega, dt, method)
    for window in [Some(10), None] {
      for row in causal_velocity(errors, transports, dt, window) {
        for value in row {
          assert_true(value.abs() <= 2.0e-15)
        }
      }
    }
  }
  let wrong = causal_velocity(
    errors,
    observation_transports(gravity, omega, dt, BodyDifference),
    dt,
    None,
  )
  assert_true(wrong.any(fn(row) { row.any(fn(x) { x.abs() > 0.01 }) }))
}

///|
test "OLS recovers independent law" {
  let matrix = [
    [1.0, 0.0, 1.0],
    [0.0, 1.0, 1.0],
    [1.0, 1.0, 1.0],
    [-1.0, 2.0, 1.0],
  ]
  let target = [5.0, 0.0, 2.0, -5.0]
  let fit = least_squares(matrix, target)
  for i, expected in [2.0, -3.0, 3.0] {
    assert_true((fit[i] - expected).abs() < 1.0e-12)
  }
}

///|
test "reference preview pads with explicit invalid tail" {
  let r = FullBodyReference::new(
    [[0.0], [1.0], [2.0]],
    [0.0, 0.02, 0.04],
    [[0.0], [0.0]],
    0.02,
  )
  let (goals, valid) = r.preview(1, length=3)
  assert_eq(goals, [[2.0], [2.0], [2.0]])
  assert_eq(valid, [true, false, false])
}

///|
test "learned head recovers uncensored coefficients and clips inference" {
  let names = [
    "left_ankle_pitch_joint", "left_ankle_roll_joint", "right_ankle_pitch_joint",
    "right_ankle_roll_joint",
  ]
  let head = LearnedAnkleHead::new(names, [-0.8, -0.8, -0.8, -0.8], [
    0.8, 0.8, 0.8, 0.8,
  ])
  let inputs = Array::makei(20, fn(i) {
    let t = i.to_double() / 20.0
    Array::makei(4, fn(_) { [t, t * t, @math.sin(t)] })
  })
  let goals = Array::makei(20, fn(_) { [0.0, 0.0, 0.0, 0.0] })
  let targets = inputs.map(fn(row) {
    row.map(fn(x) { 0.02 * x[0] - 0.03 * x[1] + 0.04 * x[2] + 0.01 })
  })
  let reports = head.fit(inputs, goals, targets)
  for report in reports {
    assert_eq(report.uncensored_points, 20)
    for i, expected in [0.02, -0.03, 0.04, 0.01] {
      assert_true((report.raw_coefficients[i] - expected).abs() < 1.0e-10)
    }
  }
}
