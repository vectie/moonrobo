///|
pub(all) struct MoonmoonNoetixAuthoredMotionSample {
  phase : Double
  root_cycle_forward_m : Double
  root_sway_m : Double
  root_bob_m : Double
  torso_counter_rotation_rad : Double
  left_foot_x_m : Double
  left_foot_y_m : Double
  left_foot_z_m : Double
  left_foot_roll_pitch_rad : Double
  right_foot_x_m : Double
  right_foot_y_m : Double
  right_foot_z_m : Double
  right_foot_roll_pitch_rad : Double
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct NoetixRootLocalPoint {
  x : Double
  y : Double
  z : Double
}

///|
fn noetix_mat4_identity() -> Array[Double] {
  [
    1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0,
  ]
}

///|
fn noetix_mat4_multiply(a : Array[Double], b : Array[Double]) -> Array[Double] {
  let out : Array[Double] = []
  for col in 0..<4 {
    for row in 0..<4 {
      out.push(
        a[row] * b[col * 4] +
        a[4 + row] * b[col * 4 + 1] +
        a[8 + row] * b[col * 4 + 2] +
        a[12 + row] * b[col * 4 + 3],
      )
    }
  }
  out
}

///|
fn noetix_mat4_translate(
  matrix : Array[Double],
  x : Double,
  y : Double,
  z : Double,
) -> Array[Double] {
  let t = noetix_mat4_identity()
  t[12] = x
  t[13] = y
  t[14] = z
  noetix_mat4_multiply(matrix, t)
}

///|
fn noetix_mat4_rotate_x(
  matrix : Array[Double],
  angle : Double,
) -> Array[Double] {
  let c = @math.cos(angle)
  let s = @math.sin(angle)
  noetix_mat4_multiply(matrix, [
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    c,
    s,
    0.0,
    0.0,
    0.0 - s,
    c,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
  ])
}

///|
fn noetix_mat4_rotate_z(
  matrix : Array[Double],
  angle : Double,
) -> Array[Double] {
  let c = @math.cos(angle)
  let s = @math.sin(angle)
  noetix_mat4_multiply(matrix, [
    c,
    s,
    0.0,
    0.0,
    0.0 - s,
    c,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
  ])
}

///|
fn noetix_transform_point(
  matrix : Array[Double],
  point : NoetixRootLocalPoint,
) -> NoetixRootLocalPoint {
  {
    x: matrix[0] * point.x +
    matrix[4] * point.y +
    matrix[8] * point.z +
    matrix[12],
    y: matrix[1] * point.x +
    matrix[5] * point.y +
    matrix[9] * point.z +
    matrix[13],
    z: matrix[2] * point.x +
    matrix[6] * point.y +
    matrix[10] * point.z +
    matrix[14],
  }
}

///|
fn noetix_root_sway_m(phase : Double) -> Double {
  let left_stance = phase < 0.5
  let stance_sign = if left_stance { 1.0 } else { 0.0 - 1.0 }
  stance_sign * 0.018 * @math.sin(cycle01(phase * 2.0) * @math.PI)
}

///|
fn noetix_root_bob_m(phase : Double) -> Double {
  @math.cos(phase * @math.PI * 4.0) * 0.032
}

///|
fn noetix_torso_counter_rotation_rad(phase : Double) -> Double {
  0.0 - 0.16 * @math.sin(phase * @math.PI * 2.0)
}

///|
fn noetix_foot_roll_pitch_rad(foot_phase : Double) -> Double {
  if foot_phase < 0.08 {
    mix(0.0 - 0.20, 0.0, smoothstep(foot_phase / 0.08))
  } else if foot_phase >= 0.42 && foot_phase < 0.64 {
    0.34 * smoothstep((foot_phase - 0.42) / 0.22)
  } else if foot_phase >= 0.64 && foot_phase < 0.78 {
    mix(0.34, 0.10, smoothstep((foot_phase - 0.64) / 0.14))
  } else if foot_phase >= 0.78 {
    mix(0.0 - 0.18, 0.0, smoothstep((foot_phase - 0.78) / 0.14))
  } else {
    0.0
  }
}

///|
fn noetix_leg_sole_local(
  side : Double,
  hip_rad : Double,
  knee_rad : Double,
  ankle_rad : Double,
) -> NoetixRootLocalPoint {
  let upper_len = 0.30
  let lower_len = 0.31
  let mut hip = noetix_mat4_identity()
  hip = noetix_mat4_translate(hip, side * 0.095, 0.0 - 0.135, 0.005)
  hip = noetix_mat4_rotate_x(hip, hip_rad)
  hip = noetix_mat4_rotate_z(hip, side * 0.025)
  let mut knee = noetix_mat4_translate(hip, 0.0, 0.0 - upper_len, 0.0)
  knee = noetix_mat4_rotate_x(knee, 0.0 - knee_rad)
  let mut ankle = noetix_mat4_translate(knee, 0.0, 0.0 - lower_len, 0.006)
  ankle = noetix_mat4_rotate_x(ankle, ankle_rad)
  noetix_transform_point(ankle, { x: 0.0, y: 0.0 - 0.056, z: 0.13 })
}

///|
fn noetix_left_foot_local(
  sample : MoonmoonNoetixAuthoredJointSample,
) -> NoetixRootLocalPoint {
  noetix_leg_sole_local(
    1.0,
    sample.left_hip_rad,
    sample.left_knee_rad,
    sample.left_ankle_rad,
  )
}

///|
fn noetix_right_foot_local(
  sample : MoonmoonNoetixAuthoredJointSample,
) -> NoetixRootLocalPoint {
  noetix_leg_sole_local(
    0.0 - 1.0,
    sample.right_hip_rad,
    sample.right_knee_rad,
    sample.right_ankle_rad,
  )
}

///|
pub fn noetix_e1_moonmoon_authored_motion_samples() -> Array[
  MoonmoonNoetixAuthoredMotionSample,
] {
  let samples : Array[MoonmoonNoetixAuthoredMotionSample] = []
  for joint_sample in noetix_e1_moonmoon_authored_joint_samples() {
    let phase = joint_sample.phase
    let left_foot = noetix_left_foot_local(joint_sample)
    let right_foot = noetix_right_foot_local(joint_sample)
    let right_phase = cycle01(phase + 0.5)
    samples.push({
      phase,
      root_cycle_forward_m: phase * 0.38,
      root_sway_m: noetix_root_sway_m(phase),
      root_bob_m: noetix_root_bob_m(phase),
      torso_counter_rotation_rad: noetix_torso_counter_rotation_rad(phase),
      left_foot_x_m: left_foot.x,
      left_foot_y_m: left_foot.y,
      left_foot_z_m: left_foot.z,
      left_foot_roll_pitch_rad: noetix_foot_roll_pitch_rad(phase),
      right_foot_x_m: right_foot.x,
      right_foot_y_m: right_foot.y,
      right_foot_z_m: right_foot.z,
      right_foot_roll_pitch_rad: noetix_foot_roll_pitch_rad(right_phase),
    })
  }
  samples
}
