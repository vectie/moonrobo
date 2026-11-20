///|
test "MuJoCo startup failure preserves library scene and actionable detail" {
  assert_true(@learning_physics.compiled_mujoco_header_version() >= 0)
  try
    @learning_physics.Runtime::open(
      "/nonexistent/moonrobo-mujoco-library", "/nonexistent/moonrobo-scene.xml",
    )
  catch {
    Invalid(message) => {
      assert_true(message.contains("/nonexistent/moonrobo-mujoco-library"))
      assert_true(message.contains("/nonexistent/moonrobo-scene.xml"))
      if @learning_physics.compiled_mujoco_header_version() == 0 {
        assert_true(message.contains("CPATH"))
        assert_true(message.contains("compiled header version=0"))
      } else {
        assert_true(message.length() > 120)
      }
    }
  } noraise {
    _ => fail("missing native library must never open a simulator")
  }
}
