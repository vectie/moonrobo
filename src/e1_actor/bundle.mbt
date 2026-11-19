///|
priv struct RobotProfile {
  format : String
  id : String
  joints : Array[String]
  default_q : Array[Double]
  scales : Array[Double]
} derive(FromJson)

///|
priv struct RobotIdentity {
  robot : RobotProfile
} derive(FromJson)

///|
priv struct SourceSpec {
  format : String
  observation_mode : String
  hist : Int32
  goal_frames : Int32
} derive(FromJson)

///|
priv struct Companion {
  format : String
  identity : RobotIdentity
  source_spec : SourceSpec
  physical_action_count : Int32
  contract : Json?
} derive(FromJson)

///|
/// Deployment-only E1 contract. Numeric normalization and network geometry
/// belong to LunaKine. Physical joint order and action-to-position conversion
/// belong to MoonRobo. This package imports no trainer, LibTorch or SDK.
pub struct Bundle {
  priv spec : @portable.Spec
  priv robot : RobotProfile
  priv feature_contract : Json?
}

///|
pub fn Bundle::parse(actor : Json, robot : Json) -> Self raise {
  let spec : @portable.Spec = @json.from_json(actor)
  let companion : Companion = @json.from_json(robot)
  spec.validate()
  let profile = companion.identity.robot
  let count = profile.joints.length()
  let width = match companion.source_spec.observation_mode {
    "smc" => 99
    "paper" => 93
    "observable" => 102
    _ => fail("unsupported E1 actor observation mode")
  }
  guard companion.format == "moonrobo.lunakine-e1.v1" &&
    profile.format == "moonrobo.e1-embedded-profile.v1" &&
    profile.id != "" &&
    (count == 23 || count == 24) &&
    companion.physical_action_count == count &&
    profile.default_q.length() == count &&
    profile.scales.length() == count &&
    profile.default_q.all(@portable.finite) &&
    profile.scales.all(x => @portable.finite(x) && x > 0.0) &&
    companion.source_spec.format == "moonrobo.native-tensor-actor-spec.v1" &&
    companion.source_spec.hist > 0 &&
    companion.source_spec.hist <= 10 &&
    companion.source_spec.goal_frames > 0 &&
    companion.source_spec.goal_frames <= 10 &&
    spec.history_frames == companion.source_spec.hist &&
    spec.observation_width == width &&
    spec.goal_width() == companion.source_spec.goal_frames * 73 &&
    spec.action_width() == 29 else {
    fail("LunaKine E1 deployment contracts differ")
  }
  for index, joint in profile.joints {
    guard joint != "" && !profile.joints[:index].contains(joint) else {
      fail("E1 actor joint order requires distinct names")
    }
  }
  for index, mask in spec.action_mask {
    guard mask == (if index < count { 1.0 } else { 0.0 }) else {
      fail("E1 actor action mask differs from its physical prefix")
    }
  }
  { spec, robot: profile, feature_contract: companion.contract, }
}

///|
pub async fn Bundle::read(directory : String) -> Self {
  Bundle::parse(
    @fs.read_file(directory + "/actor.json").json(),
    @fs.read_file(directory + "/robot.json").json(),
  )
}

///|
pub fn Bundle::profile_id(self : Self) -> String {
  self.robot.id
}

///|
pub fn Bundle::joints(self : Self) -> ReadOnlyArray[String] {
  ReadOnlyArray::from_array(self.robot.joints)
}

///|
pub fn Bundle::history_frames(self : Self) -> Int32 {
  self.spec.history_frames
}

///|
pub fn Bundle::observation_width(self : Self) -> Int32 {
  self.spec.observation_width
}

///|
pub fn Bundle::goal_width(self : Self) -> Int32 {
  self.spec.goal_width()
}

///|
/// Nominal training-frame positions; not calibrated SDK commands. All 29 raw
/// actions must be finite, including inactive channels. Unused channels do not
/// become physical joints and no gains, clipping or calibration are inferred.
pub fn Bundle::nominal_setpoints(
  self : Self,
  actions : ArrayView[Double],
) -> Array[Double] raise {
  guard actions.length() == 29 && actions.all(@portable.finite) else {
    fail("invalid embedded E1 action")
  }
  let positions = Array::makei(self.robot.joints.length(), index => {
    self.robot.default_q[index] + self.robot.scales[index] * actions[index]
  })
  guard positions.all(@portable.finite) else {
    fail("E1 nominal setpoint conversion overflow")
  }
  positions
}

///|
fn Bundle::project(self : Self, actions : Array[Double]) -> Array[Double] raise {
  guard actions.length() == 29 && actions.all(@portable.finite) else {
    fail("invalid embedded E1 action")
  }
  Array::makei(29, index => {
    if index < self.robot.joints.length() {
      actions[index]
    } else {
      0.0
    }
  })
}
