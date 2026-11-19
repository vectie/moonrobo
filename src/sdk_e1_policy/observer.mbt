///|
/// Prepared sensor-to-feature adapter. No SDK initialization, actor inference,
/// timestamps or command publication occur here. The control owner supplies
/// reference alignment and retains sample capture time plus receipt age.
pub struct Observer {
  priv mapping : Mapping
  priv features : @actor.SmcObservation
  priv imu : Imu
}

///|
pub fn Observer::new(mapping : Mapping, imu : Imu) -> Self raise {
  { mapping, features: mapping.bundle.smc_observation(), imu, }
}

///|
pub fn Observer::profile_id(self : Self) -> String {
  self.mapping.profile_id()
}

///|
pub fn Observer::observation(
  self : Self,
  sample : @low.Sample,
  previous : ArrayView[Double],
  reference_body_to_world : ArrayView[Double],
) -> Array[Double] raise {
  let (q, qd) = self.mapping.joint_state(sample)
  let attitude = self.imu.decode(
    sample.orientation()[:],
    sample.angular_velocity()[:],
    reference_body_to_world,
  )
  self.features.encode(
    q[:],
    qd[:],
    previous,
    attitude.body_gyro()[:],
    attitude.gravity()[:],
    attitude.reference_orientation()[:],
  )
}
