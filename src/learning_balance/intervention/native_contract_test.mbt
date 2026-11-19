///|
/// Native WindowTeacher contract from test_balance_intervention.py. Requires MOONROBO_MUJOCO_LIBRARY; no physical execution is performed by moon check.
test "window teachers reset filter state and retain exactly N error frames" {
  guard @env.get_env_var("MOONROBO_MUJOCO_LIBRARY") is Some(library) else {
    fail(
      "set MOONROBO_MUJOCO_LIBRARY before running native migration contracts",
    )
  }
  let runtime = @native_physics.Runtime::open(
    library, "src/learning_balance/physics/testdata/teacher.xml",
  )
  runtime.reset("home", 1.0)
  let parameters : @balance.FeedbackParameters = {
    angle_gain: 0.0,
    rate_gain: 0.0,
    com_gain: 0.0,
    velocity_gain: 1.0,
    pitch_bias: 0.0,
    residual_bound: 100.0,
    joint_damping: 0.0,
    hip_share: 0.0,
    waist_share: 0.0,
    waist_dynamic_only: false,
    support_gain: 0.0,
  }
  let full = @balance_native.NativeBalanceTeacher::new(
    runtime, parameters, 0.02,
  )
  let short = WindowTeacher::new(runtime, parameters, 10, 0.02)
  let long = WindowTeacher::new(runtime, parameters, 50, 0.02)
  let zero = WindowTeacher::new(runtime, parameters, 1, 0.02)
  let zero_action = Array::make(5, 0.0)
  let errors : Array[Array[Double]] = []
  for i in 0..<35 {
    let state = runtime.state()
    for joint in runtime.q_indices() {
      state[joint] = 0.0001 * i.to_double() * i.to_double()
    }
    runtime.set_state(state)
    let (_, feet, com) = full.measurements()
    errors.push([
      com[0] - (feet[0][0] + feet[1][0]) / 2.0,
      com[1] - (feet[0][1] + feet[1][1]) / 2.0,
      0.0,
    ])
    let obs = runtime.observation(zero_action)
    let full_action = full.predict(obs, zero_action)
    let long_action = long.predict(obs, zero_action)
    for j in 0..<5 {
      assert_true((long_action[j] - full_action[j]).abs() < 1.0e-14)
    }
    ignore(short.predict(obs, zero_action))
    let expected = [0.0, 0.0, 0.0]
    let first = (errors.length() - 10).max(0)
    for j in (first + 1)..<errors.length() {
      for axis in 0..<3 {
        expected[axis] = 0.8 * expected[axis] +
          0.2 * (errors[j][axis] - errors[j - 1][axis]) / 0.02
      }
    }
    for j in 0..<3 {
      assert_true((short.velocity()[j] - expected[j]).abs() < 1.0e-14)
    }
    assert_eq(zero.predict(obs, zero_action), zero_action)
  }
  let fresh = WindowTeacher::new(runtime, parameters, 10, 0.02)
  assert_eq(
    fresh.predict(runtime.observation(zero_action), zero_action),
    zero_action,
  )
  assert_true((short.velocity()[0] - full.memory().1[0]).abs() > 1.0e-6)
}
