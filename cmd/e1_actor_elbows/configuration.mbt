///|
priv struct Configuration {
  format : String
  model_id : String
  actor_json_sha256 : String
  parameters_sha256 : String
  robot_json_sha256 : String
  model_om_sha256 : String
  reference_sha256 : String
  reference_duration_ms : Int32
  joint_calibration : @mapping.Calibration
  imu_calibration : @mapping.ImuCalibration
  adapter : @adapter.Settings
  maximum_policy_ms : Int32
  approach_ms : Int32
  maximum_total_ms : Int32
  following_tolerance_rad : Double
  scope : String
} derive(FromJson)

///|
fn required(name : String) -> String raise {
  guard @env.get_env_var(name) is Some(value) else {
    fail("missing actor environment: " + name)
  }
  value
}

///|
fn sha(bytes : Bytes) -> String {
  let mut text = ""
  for byte in @crypto.sha256(bytes) {
    text += byte.to_hex()
  }
  text
}

///|
async fn load() -> (@actor.Bundle, @actor.Actor, @reference.Clip, Configuration) {
  let directory = required("MOONROBO_E1_ACTOR_BUNDLE")
  let model = required("MOONROBO_E1_ACTOR_MODEL")
  let config : Configuration = @json.from_json(
    @fs.read_file(required("MOONROBO_E1_ACTOR_CONFIG")).json(),
  )
  guard config.format == "moonrobo.e1-actor-elbows.v1" &&
    config.model_id.length() == 64 &&
    config.model_id == config.model_om_sha256 &&
    config.scope != "" &&
    config.maximum_policy_ms > 0 &&
    config.maximum_policy_ms <= 30000 &&
    config.approach_ms >= 0 &&
    config.approach_ms <= 60000 &&
    config.maximum_total_ms > config.maximum_policy_ms &&
    config.maximum_total_ms <= 180000 &&
    config.following_tolerance_rad > 0.0 &&
    config.following_tolerance_rad <= 5.0 * @ankle.RAD else {
    fail("invalid constrained actor deployment settings")
  }
  for
    (path, expected) in [
      (directory + "/actor.json", config.actor_json_sha256),
      (directory + "/parameters.f32", config.parameters_sha256),
      (directory + "/robot.json", config.robot_json_sha256),
      (model, config.model_om_sha256),
    ] {
    guard sha(@fs.read_file(path).binary()) == expected else {
      fail("actor artifact identity mismatch: " + path)
    }
  }
  config.adapter.validate()
  let bundle = @actor.Bundle::read(directory)
  guard bundle.joints().length() == 23 &&
    bundle.history_frames() == 10 &&
    bundle.observation_width() == 99 &&
    bundle.goal_width() == 730 else {
    fail("expected frozen 23-joint SMC actor")
  }
  for
    (name, slot) in [
      ("l_arm_elbow_pitch_joint", 3),
      ("r_arm_elbow_pitch_joint", 14),
    ] {
    guard config.joint_calibration.axes
      .filter(a => {
        a.actor_joint == name &&
        a.motor_id == slot &&
        a.direction == 1.0 &&
        a.zero == 0.0
      })
      .length() ==
      1 else {
      fail("elbow mapping differs from commissioned SDK pitch motors")
    }
  }
  let reference_path = required("MOONROBO_E1_ACTOR_REFERENCE")
  guard sha(@fs.read_file(reference_path).binary()) == config.reference_sha256 else {
    fail("actor reference identity mismatch")
  }
  let clip = @reference.Clip::read(bundle, reference_path)
  guard clip.duration_ms() == config.reference_duration_ms.to_int64() else {
    fail("reference duration mismatch")
  }
  let actor = @actor.Actor::open_ascend(
    bundle,
    required("MOONROBO_E1_CANN_LIBRARY"),
    model,
  )
  (bundle, actor, clip, config)
}
