///|
test "SMC encoder uses saved legacy or current scales and masks inactive channels" {
  for (velocity_scale, gyro_scale) in [(1.0, 1.0), (0.1, 0.25)] {
    let (bundle, _) = fixture(velocity_scale~, gyro_scale~)
    let encoder = bundle.smc_observation()
    let q = Array::makei(23, i => i.to_double() * 0.1 + 0.5)
    let qd = Array::makei(23, i => (i + 1).to_double())
    let previous = Array::makei(29, i => (i + 1).to_double() * 0.01)
    let observation = encoder.encode(
      q[:],
      qd[:],
      previous[:],
      [2.0, 4.0, 6.0],
      [0.0, 0.0, -1.0],
      [1.0, 2.0, 3.0, 4.0, 5.0, 6.0],
    )
    assert_eq(observation.length(), 99)
    for i in 0..<23 {
      assert_true((observation[i] - 0.5).abs() < 1.0e-12)
      assert_eq(observation[29 + i], qd[i] * velocity_scale)
      assert_eq(observation[64 + i], previous[i])
    }
    for i in 23..<29 {
      assert_eq(
        (observation[i], observation[29 + i], observation[64 + i]),
        (0.0, 0.0, 0.0),
      )
    }
    assert_eq(observation[58:61].to_owned(), [
      2.0 * gyro_scale,
      4.0 * gyro_scale,
      6.0 * gyro_scale,
    ])
    assert_eq(observation[61:64].to_owned(), [0.0, 0.0, -1.0])
    assert_eq(observation[93:99].to_owned(), [1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
  }
}

///|
async test "actual deployed actor retains declared observation scaling" {
  guard @env.get_env_var("MOONROBO_E1_BUNDLE") is Some(directory) else {
    println("SKIP real E1 observation contract: set MOONROBO_E1_BUNDLE")
    return
  }
  let bundle = @e1_actor.Bundle::read(directory)
  guard @fs.read_file(directory + "/robot.json").json()
    is {
      "contract": {
        "joint_velocity_feature_scale": Number(velocity_scale, ..),
        "body_gyro_feature_scale": Number(gyro_scale, ..),
        ..
      },
      ..
    } else {
    fail("saved feature scales missing")
  }
  let count = bundle.joints().length()
  let result = bundle
    .smc_observation()
    .encode(
      Array::make(count, 0.0)[:],
      Array::make(count, 2.0)[:],
      Array::make(29, 0.0)[:],
      [4.0, 8.0, 12.0],
      [0.0, 0.0, -1.0],
      [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
    )
  assert_eq(result[29], 2.0 * velocity_scale)
  assert_eq(result[58:61].to_owned(), [
    4.0 * gyro_scale,
    8.0 * gyro_scale,
    12.0 * gyro_scale,
  ])
}
