///|
fn main raise {
  guard @env.args()[1:] is [library] else {
    fail("usage: sdk_e1_low_abi FAKE_SDK_LIBRARY")
  }
  let controller = @low.Controller::open(library)
  let sample = @low.Sample::new()
  assert_true(
    try controller.capture_into(sample) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try sample.mode() catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  ignore(controller.joint_index("fixture_emit"))
  for _ in 0..<3 {
    controller.capture_into(sample)
  }
  for i in 0..<24 {
    let joint = sample.joint(i)
    assert_eq(joint.motor_id, 100 + i)
    assert_eq(joint.position, i.to_double() + 0.25)
    assert_eq(joint.velocity, i.to_double() + 0.5)
    assert_eq(joint.torque, i.to_double() + 0.75)
    assert_eq(joint.error, i)
    assert_eq(joint.temperature, 30 + i)
  }
  assert_eq(sample.orientation(), [2.0, 3.0, 4.0, 5.0])
  assert_eq(sample.angular_velocity(), [6.0, 7.0, 8.0])
  assert_eq(sample.linear_acceleration(), [9.0, 10.0, 11.0])
  assert_eq(sample.remote_axes(), [12.0, 13.0])
  assert_eq(sample.remote_buttons().length(), 14)
  assert_eq(sample.mode(), 3)
  assert_true(sample.age_ms() >= 0L)
  assert_eq(controller.joint_index("arm_l1_joint"), 7)
  assert_true(
    try controller.joint_index("unknown") catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try sample.joint(24) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  let commands : Array[@low.MotorCommand] = Array::makei(24, i => {
    position: i.to_double() + 0.25,
    velocity: i.to_double() + 0.5,
    torque: i.to_double() + 0.75,
    kp: 10.0 + i.to_double(),
    kd: 1.0 + i.to_double(),
  })
  assert_true(
    try controller.publish(commands[:23]) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  controller.publish(commands)
  assert_eq(controller.joint_index("fixture_publish_count"), 1)
  let original = commands[0]
  commands[0] = { ..original, kp: -1.0, }
  assert_true(
    try controller.publish(commands) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_eq(controller.joint_index("fixture_publish_count"), 1)
  commands[0] = original
  ignore(controller.joint_index("fixture_throw_publish"))
  assert_true(
    try controller.publish(commands) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  ignore(controller.joint_index("fixture_resume_publish"))
  controller.publish(commands)
  assert_eq(controller.joint_index("fixture_publish_count"), 2)
  println(
    "SDK3.1 low MoonBit ABI: reusable coherent capture, raw fields, joint lookup, full motor frames, rejection and SDK failure/reuse passed; fake SDK only",
  )
}
