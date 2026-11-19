///|
/// Calibrated body gyro/gravity and reference-relative orientation are explicit
/// inputs. SDK quaternion conventions, root alignment and sensor freshness are
/// the surrounding runtime's responsibility. Feature scaling matches training.
pub fn Profile::observation(
  self : Profile,
  q : Array[Double],
  qd : Array[Double],
  previous : Array[Double],
  body_gyro : Array[Double],
  gravity : Array[Double],
  reference_orientation : Array[Double],
  calibration? : Array[Double],
) -> Array[Double] raise {
  let positions = self.embed(q)
  let velocities = self.embed(qd)
  let actions = self.embed(previous)
  let offsets = self.embed(
    calibration.unwrap_or(Array::make(self.joints.length(), 0.0)),
  )
  guard body_gyro.length() == 3 &&
    gravity.length() == 3 &&
    reference_orientation.length() == 6 &&
    [body_gyro, gravity, reference_orientation].all(v => v.all(@numeric.finite)) else {
    fail("invalid E1 calibrated orientation inputs")
  }
  let defaults = self.embed(self.default_q)
  let result = Array::makei(29, i => positions[i] - defaults[i] - offsets[i])
  result.append(velocities)
  result.append(body_gyro)
  result.append(gravity)
  result.append(actions)
  result.append(reference_orientation)
  result
}
