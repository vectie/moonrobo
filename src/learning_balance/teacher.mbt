///|
pub(all) struct FeedbackParameters {
  angle_gain : Double
  rate_gain : Double
  com_gain : Double
  velocity_gain : Double
  pitch_bias : Double
  joint_damping : Double
  residual_bound : Double
  hip_share : Double
  waist_share : Double
  waist_dynamic_only : Bool
  support_gain : Double
} derive(Debug, ToJson, FromJson)

///|
pub fn observation_ankle_feedback(
  parameters : FeedbackParameters,
  nu : Int32,
  indices : Array[Int32],
  lower : Array[Double],
  upper : Array[Double],
  obs : Array[Double],
  goal : Array[Double],
  features : Array[Double],
) -> Array[Double] {
  guard parameters.support_gain == 0.0 else {
    abort("support force is unavailable in observation-only feedback")
  }
  let gx = obs[2 * nu]
  let gy = obs[2 * nu + 1]
  let gz = obs[2 * nu + 2]
  let pitch = @math.atan2(gx, (gy * gy + gz * gz).sqrt())
  let roll = @math.atan2(-gy, -gz)
  let p = parameters.com_gain * features[0] +
    parameters.velocity_gain * features[3] +
    parameters.pitch_bias +
    parameters.angle_gain * pitch +
    parameters.rate_gain * obs[2 * nu + 4]
  let r = -parameters.com_gain * features[1] -
    parameters.velocity_gain * features[4] +
    parameters.angle_gain * roll +
    parameters.rate_gain * obs[2 * nu + 3]
  Array::makei(4, fn(j) {
    let correction = (if j % 2 == 0 { p } else { r }) -
      parameters.joint_damping * obs[nu + indices[j]]
    clip(
      goal[indices[j]] +
      clip(correction, -parameters.residual_bound, parameters.residual_bound),
      lower[indices[j]],
      upper[indices[j]],
    )
  })
}

///|
pub struct BalanceTeacher {
  names : Array[String]
  parameters : FeedbackParameters
  dt : Double
  mut last_error : Array[Double]?
  mut velocity : Array[Double]
}

///|
pub fn BalanceTeacher::new(
  names : Array[String],
  parameters : FeedbackParameters,
  dt : Double,
) -> BalanceTeacher {
  { names, parameters, dt, last_error: None, velocity: [0.0, 0.0, 0.0], }
}

///|
pub fn BalanceTeacher::set_memory(
  self : BalanceTeacher,
  last_error : Array[Double]?,
  velocity : Array[Double],
) -> Unit {
  self.last_error = last_error
  self.velocity = velocity
}

///|
pub fn BalanceTeacher::memory(
  self : BalanceTeacher,
) -> (Array[Double]?, Array[Double]) {
  (self.last_error, self.velocity)
}

///|
/// Runtime supplies privileged physical measurements explicitly; this kernel never reconstructs simulator state from observation channels.
pub fn BalanceTeacher::predict(
  self : BalanceTeacher,
  rotation : Array[Double],
  com : Array[Double],
  feet : Array[Array[Double]],
  joint_speed : Array[Double],
  root_omega : Array[Double],
  support_correction : Array[Double],
  goal : Array[Double],
  lower : Array[Double],
  upper : Array[Double],
) -> Array[Double] {
  let error = com.copy()
  for foot in feet {
    for j in 0..<3 {
      error[j] -= foot[j] / feet.length().to_double()
    }
  }
  error[2] = 0.0
  if self.last_error is Some(previous) {
    self.velocity = Array::makei(3, fn(j) {
      0.8 * self.velocity[j] + 0.2 * (error[j] - previous[j]) / self.dt
    })
  }
  self.last_error = Some(error)
  let local_error = matvec(transpose(rotation), error)
  let local_velocity = matvec(transpose(rotation), self.velocity)
  let gravity = [-rotation[6], -rotation[7], -rotation[8]]
  let pitch = @math.atan2(
    gravity[0],
    (gravity[1] * gravity[1] + gravity[2] * gravity[2]).sqrt(),
  )
  let roll = @math.atan2(-gravity[1], -gravity[2])
  let c = self.parameters
  let p = c.angle_gain * pitch +
    c.rate_gain * root_omega[1] +
    c.com_gain * local_error[0] +
    c.velocity_gain * local_velocity[0] +
    c.pitch_bias
  let r = c.angle_gain * roll +
    c.rate_gain * root_omega[0] -
    c.com_gain * local_error[1] -
    c.velocity_gain * local_velocity[1]
  let waist_signal = p - (if c.waist_dynamic_only { c.pitch_bias } else { 0.0 })
  Array::makei(self.names.length(), fn(i) {
    let name = self.names[i]
    let correction = if name.has_suffix("_ankle_pitch_joint") {
      p
    } else if name.has_suffix("_ankle_roll_joint") {
      r
    } else if name.has_suffix("_hip_pitch_joint") {
      c.hip_share * clip(p, -c.residual_bound, c.residual_bound)
    } else if name.has_suffix("_hip_roll_joint") {
      c.hip_share * clip(r, -c.residual_bound, c.residual_bound)
    } else if name == "waist_pitch_joint" {
      -c.waist_share * clip(waist_signal, -c.residual_bound, c.residual_bound)
    } else {
      0.0
    }
    let support = if c.support_gain == 0.0 {
      0.0
    } else {
      c.support_gain * support_correction[i]
    }
    clip(
      goal[i] +
      clip(
        correction + support - c.joint_damping * joint_speed[i],
        -c.residual_bound,
        c.residual_bound,
      ),
      lower[i],
      upper[i],
    )
  })
}

///|
/// The caller computes the MuJoCo Jacobians at the clipped center of pressure.
pub fn support_torque(
  com : Array[Double],
  feet : Array[Array[Double]],
  weight : Double,
  vertical_jacobians : Array[Array[Double]],
  bias : Array[Double],
) -> Array[Double] {
  let span = feet[0][1] - feet[1][1]
  let left = if span.abs() > 1.0e-6 {
    clip((com[1] - feet[1][1]) / span, 0.0, 1.0)
  } else {
    0.5
  }
  Array::makei(bias.length(), fn(i) {
    bias[i] -
    weight *
    (left * vertical_jacobians[0][i] + (1.0 - left) * vertical_jacobians[1][i])
  })
}

///|
pub fn blend_actions(
  student : Array[Double],
  teacher : Array[Double],
  indices : Array[Int32],
) -> Array[Double] {
  let result = student.copy()
  for i in indices {
    result[i] = teacher[i]
  }
  result
}

///|
pub fn joint_groups(names : Array[String]) -> Map[String, Array[Int32]] {
  let ankle : Array[Int32] = []
  let ankle_waist : Array[Int32] = []
  let lower : Array[Int32] = []
  let other : Array[Int32] = []
  let all : Array[Int32] = []
  for i, name in names {
    all.push(i)
    let a = name.contains("_ankle_")
    let w = name == "waist_pitch_joint"
    if a {
      ankle.push(i)
    }
    if a || w {
      ankle_waist.push(i)
    } else {
      other.push(i)
    }
    if a || name.contains("_hip_") || name.contains("_knee_") {
      lower.push(i)
    }
  }
  {
    "ankle": ankle,
    "ankle_waist": ankle_waist,
    "lower": lower,
    "other": other,
    "all": all,
  }
}
