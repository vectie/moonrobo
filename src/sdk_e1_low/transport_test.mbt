///|
test "uncaptured samples and absent libraries fail explicitly" {
  let sample = @sdk_e1_low.Sample::new()
  assert_true(
    try sample.age_ms() catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try @sdk_e1_low.Controller::open("/missing/moonrobo-low-fixture.so") catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}

///|
test "actual-header fake SDK crosses the private MoonBit ABI" {
  guard @env.get_env_var("MOONROBO_E1_LOW_FIXTURE") is Some(path) else {
    println("SKIP low-control ABI: run scripts/test_sdk_e1_low.mbtx")
    return
  }
  let controller = @sdk_e1_low.Controller::open(path)
  let sample = @sdk_e1_low.Sample::new()
  assert_true(
    try controller.capture_into(sample) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  ignore(controller.joint_index("fixture_emit"))
  controller.capture_into(sample)
  assert_eq(controller.joint_index("arm_l1_joint"), 7)
  assert_eq(sample.joint(23).position, 23.25)
  assert_true(sample.age_ms() >= 0L)
}
