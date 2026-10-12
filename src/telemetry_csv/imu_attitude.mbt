///|
/// Normalize with scaling so very small/large finite quaternions remain usable.
/// The original norm is retained; a nonrepresentable norm cannot be reported.
fn imu_quaternion(
  raw : Array[Double],
  policy : String,
) -> Result[(Array[Double], Double), String] {
  let scale = raw.fold(init=0.0, (a, v) => a.max(v.abs()))
  if scale == 0.0 {
    return Err("selected orientation has a zero quaternion")
  }
  let scaled = raw.map(v => v / scale)
  let length = scaled.fold(init=0.0, (a, v) => a + v * v).sqrt()
  let norm = scale * length
  if norm.is_inf() || norm == 0.0 {
    return Err("quaternion norm is not representable")
  }
  if policy == "require-unit" && (norm - 1.0).abs() > 1.0e-6 {
    return Err(
      "quaternion is not unit length within 1e-6; choose normalize explicitly",
    )
  }
  Ok((scaled.map(v => v / length), norm))
}

///|
/// Fixed-axis XYZ roll/pitch/yaw (R = Rz(yaw) Ry(pitch) Rx(roll)).
/// Euler singularities are rejected rather than inventing a unique heading.
fn imu_attitude(q : Array[Double]) -> Result[Array[Double], String] {
  let x = q[0]
  let y = q[1]
  let z = q[2]
  let w = q[3]
  let sine_pitch = 2.0 * (w * y - z * x)
  if sine_pitch.abs() >= 1.0 - 1.0e-12 {
    return Err(
      "attitude is at or near Euler gimbal lock; select quaternion instead of attitude",
    )
  }
  Ok([
    @math.atan2(2.0 * (w * x + y * z), 1.0 - 2.0 * (x * x + y * y)),
    @math.asin(sine_pitch),
    @math.atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z)),
  ])
}
