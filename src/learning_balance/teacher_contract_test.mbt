///|
/// Port of test_balance_teacher.py: feedback axis signs, limits, episode-local EMA and non-actuating support compensation.
fn contract_teacher_parameters() -> FeedbackParameters {
  {
    angle_gain: 1.0,
    rate_gain: 0.1,
    com_gain: 2.0,
    velocity_gain: 0.2,
    pitch_bias: 0.0,
    joint_damping: 0.02,
    residual_bound: 0.3,
    hip_share: 0.0,
    waist_share: 0.0,
    waist_dynamic_only: false,
    support_gain: 0.0,
  }
}

///|
fn contract_joint_names() -> Array[String] {
  [
    "left_ankle_pitch_joint", "left_ankle_roll_joint", "right_ankle_pitch_joint",
    "right_ankle_roll_joint", "waist_pitch_joint",
  ]
}

///|
fn assert_close_rows(
  actual : Array[Double],
  expected : Array[Double],
  tolerance : Double,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i, x in actual {
    assert_true((x - expected[i]).abs() <= tolerance)
  }
}

///|
test "teacher pitch roll COM signs preserve the reference goal and waist share" {
  let feet = [[0.0, -0.1, 0.0], [0.0, 0.1, 0.0]]
  let lower = Array::make(5, -1.0)
  let upper = Array::make(5, 1.0)
  let zero = Array::make(5, 0.0)
  let call = fn(rotation, com, goal, parameters) {
    BalanceTeacher::new(contract_joint_names(), parameters, 0.02).predict(
      rotation,
      com,
      feet,
      zero,
      [0.0, 0.0, 0.0],
      zero,
      goal,
      lower,
      upper,
    )
  }
  let c = @math.cos(0.1)
  let s = @math.sin(0.1)
  let pitch = call(
    [c, 0.0, s, 0.0, 1.0, 0.0, -s, 0.0, c],
    [0.0, 0.0, 0.8],
    zero,
    contract_teacher_parameters(),
  )
  assert_close_rows(pitch, [0.1, 0.0, 0.1, 0.0, 0.0], 1.0e-14)
  let roll = call(
    [1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c],
    [0.0, 0.0, 0.8],
    zero,
    contract_teacher_parameters(),
  )
  assert_close_rows(roll, [0.0, 0.1, 0.0, 0.1, 0.0], 1.0e-14)
  let goal = [0.1, 0.1, 0.1, 0.1, 0.2]
  let action = call(
    identity(),
    [0.05, 0.03, 0.8],
    goal,
    contract_teacher_parameters(),
  )
  assert_close_rows(
    Array::makei(5, fn(i) { action[i] - goal[i] }),
    [0.1, -0.06, 0.1, -0.06, 0.0],
    1.0e-14,
  )
  assert_eq(goal, [0.1, 0.1, 0.1, 0.1, 0.2])
  let assisted = call(identity(), [0.05, 0.03, 0.8], goal, {
    ..contract_teacher_parameters(),
    waist_share: 0.5,
  })
  assert_true((assisted[4] - goal[4] + 0.05).abs() < 1.0e-14)
}

///|
test "teacher actuator residual bounds and new-episode EMA reset" {
  let teacher = BalanceTeacher::new(
    contract_joint_names(),
    contract_teacher_parameters(),
    0.02,
  )
  let feet = [[0.0, -0.1, 0.0], [0.0, 0.1, 0.0]]
  let zero = Array::make(5, 0.0)
  let call = fn(t : BalanceTeacher, com, goal) {
    t.predict(
      identity(),
      com,
      feet,
      zero,
      [0.0, 0.0, 0.0],
      zero,
      goal,
      Array::make(5, -1.0),
      Array::make(5, 1.0),
    )
  }
  assert_eq(call(teacher, [10.0, 0.0, 0.8], [0.9, 0.0, 0.9, 0.0, 0.0]), [
    1.0, 0.0, 1.0, 0.0, 0.0,
  ])
  ignore(call(teacher, [0.0, 0.0, 0.8], zero))
  assert_eq(
    call(
      BalanceTeacher::new(
        contract_joint_names(),
        contract_teacher_parameters(),
        0.02,
      ),
      [0.0, 0.0, 0.8],
      zero,
    ),
    zero,
  )
  for x in call(teacher, [0.0, 0.0, 0.8], zero) {
    assert_true(x.abs() <= 0.3)
  }
}

///|
test "support distribution kernel subtracts Jacobian support without mutating inputs" {
  let bias = [0.0, 0.0, 39.24, 0.0, 0.0, 0.0, 0.2, -0.2]
  let jac = [
    [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.01, 0.0],
    [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, -0.01],
  ]
  let result = support_torque(
    [0.0, 0.0, 0.8],
    [[0.0, 0.1, 0.0], [0.0, -0.1, 0.0]],
    39.24,
    jac,
    bias,
  )
  for i in 0..<6 {
    assert_true(result[i].abs() < 1.0e-12)
  }
  assert_true(result[6].abs() + result[7].abs() > 0.001)
  assert_eq(bias, [0.0, 0.0, 39.24, 0.0, 0.0, 0.0, 0.2, -0.2])
  assert_eq(jac[0][2], 1.0)
}
