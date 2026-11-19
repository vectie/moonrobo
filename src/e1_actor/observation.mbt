///|
priv struct ObservationProfile {
  id : String
  joints : Array[String]
  default_q : Array[Double]
} derive(FromJson)

///|
priv struct ObservationContract {
  profile : ObservationProfile
  internal_actions : Int32
  physical_actions : Int32
  observation_mode : String
  internal_observation_width : Int32
  joint_velocity_feature_scale : Double
  body_gyro_feature_scale : Double
} derive(FromJson)

///|
/// Prepared raw SMC feature encoder. Read saved feature scales once, before
/// control ticks. Normalization remains inside the selected numerical actor.
pub struct SmcObservation {
  priv defaults : Array[Double]
  priv velocity_scale : Double
  priv gyro_scale : Double
}

///|
/// Missing feature metadata is not guessed from current training defaults.
/// Older bundles can still execute explicit recorded features without it.
pub fn Bundle::smc_observation(self : Self) -> SmcObservation raise {
  guard self.feature_contract is Some(value) && self.observation_width() == 99 else {
    fail("SMC observation preparation requires the saved feature contract")
  }
  let contract : ObservationContract = @json.from_json(value)
  guard contract.observation_mode == "smc" &&
    contract.internal_actions == 29 &&
    contract.internal_observation_width == 99 &&
    contract.physical_actions == self.robot.joints.length() &&
    contract.profile.id == self.robot.id &&
    contract.profile.joints == self.robot.joints &&
    contract.profile.default_q == self.robot.default_q &&
    @portable.finite(contract.joint_velocity_feature_scale) &&
    contract.joint_velocity_feature_scale > 0.0 &&
    @portable.finite(contract.body_gyro_feature_scale) &&
    contract.body_gyro_feature_scale > 0.0 else {
    fail("saved SMC feature contract differs from the selected actor profile")
  }
  {
    defaults: self.robot.default_q,
    velocity_scale: contract.joint_velocity_feature_scale,
    gyro_scale: contract.body_gyro_feature_scale,
  }
}

///|
/// q/qd are calibrated physical joint coordinates in actor order. Previous
/// actions are29 raw embedded policy values, never SDK positions. Body vectors
/// and the row-interleaved first two columns of R_body^T R_reference are explicit.
pub fn SmcObservation::encode(
  self : Self,
  q : ArrayView[Double],
  qd : ArrayView[Double],
  previous : ArrayView[Double],
  body_gyro : ArrayView[Double],
  gravity : ArrayView[Double],
  reference_orientation : ArrayView[Double],
) -> Array[Double] raise {
  let count = self.defaults.length()
  guard q.length() == count &&
    qd.length() == count &&
    previous.length() == 29 &&
    body_gyro.length() == 3 &&
    gravity.length() == 3 &&
    reference_orientation.length() == 6 &&
    q.all(@portable.finite) &&
    qd.all(@portable.finite) &&
    previous.all(@portable.finite) &&
    body_gyro.all(@portable.finite) &&
    gravity.all(@portable.finite) &&
    reference_orientation.all(@portable.finite) else {
    fail("invalid calibrated SMC observation inputs")
  }
  let result = Array::make(99, 0.0)
  for index in 0..<count {
    result[index] = q[index] - self.defaults[index]
    result[29 + index] = qd[index] * self.velocity_scale
    result[64 + index] = previous[index]
  }
  for index in 0..<3 {
    result[58 + index] = body_gyro[index] * self.gyro_scale
    result[61 + index] = gravity[index]
  }
  for index in 0..<6 {
    result[93 + index] = reference_orientation[index]
  }
  guard result.all(@portable.finite) else {
    fail("SMC feature conversion overflow")
  }
  result
}
