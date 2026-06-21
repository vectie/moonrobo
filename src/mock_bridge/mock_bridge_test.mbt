///|
test "mock bridge produces deterministic health and telemetry" {
  let profile = @core.noetix_e1_profile("noetix-e1-lab-01", "Noetix E1 Lab 01")
  let state = @mock_bridge.new(profile)
  let health = @mock_bridge.health(profile)
  assert_eq(health.status, "ok")
  assert_eq(health.robot_id, profile.id)
  let frame = @mock_bridge.telemetry_frame(profile, state, 1000L)
  assert_eq(frame.frame_id, "mock-0")
  assert_eq(frame.joints.length(), 24)
  assert_eq(frame.joints[23].name, "waist_2_joint")
  assert_true(frame.imu is Some(_))
}
