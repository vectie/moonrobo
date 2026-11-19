///|
/// Native float32 arithmetic for the fixed-gain diagnostic ankle controller.
pub fn observation_ankle_feedback(
  c : @balance.FeedbackParameters,
  nu : Int32,
  indices : Array[Int32],
  lower : Array[Double],
  upper : Array[Double],
  observation : Array[Double],
  goal : Array[Double],
  feature : Array[Double],
) -> Array[Double] {
  guard c.support_gain == 0.0 else {
    abort("observation feedback cannot use support-force compensation")
  }
  let obs = observation.map(round)
  let gx = obs[2 * nu]
  let gy = obs[2 * nu + 1]
  let gz = obs[2 * nu + 2]
  let pitch = round(@math.atan2(gx, sqrt(add(mul(gy, gy), mul(gz, gz)))))
  let roll = round(@math.atan2(-gy, -gz))
  let p = add(
    add(mul(c.com_gain, feature[0]), mul(c.velocity_gain, feature[3])),
    c.pitch_bias,
  )
  let r = sub(mul(-c.com_gain, feature[1]), mul(c.velocity_gain, feature[4]))
  let p = add(
    add(p, mul(c.angle_gain, pitch)),
    mul(c.rate_gain, obs[2 * nu + 4]),
  )
  let r = add(
    add(r, mul(c.angle_gain, roll)),
    mul(c.rate_gain, obs[2 * nu + 3]),
  )
  Array::makei(4, fn(j) {
    let correction = sub(
      if j % 2 == 0 {
        p
      } else {
        r
      },
      mul(c.joint_damping, obs[nu + indices[j]]),
    )
    let bounded = @balance.clip(
      correction,
      round(-c.residual_bound),
      round(c.residual_bound),
    )
    @balance.clip(
      add(goal[indices[j]], bounded),
      round(lower[indices[j]]),
      round(upper[indices[j]]),
    )
  })
}
