///|
/// Pullback through the production matrix->quaternion graph, using explicit
/// upstream fixture leaves/weights rather than finite differences as an oracle.
pub fn quaternion_pullback(
  vector : Array[Double],
  weights : Array[Double],
) -> (Array[Double], Array[Double]) {
  let t = @numeric.Tape::new()
  let v = t.vector(vector)
  let q = ad_quaternion(t, ad_exp(t, v))
  let loss = q.foldi(init=t.scalar(0.0), (i, sum, x) => {
    t.add(sum, t.scale(x, weights[i]))
  })
  t.backward(loss)
  (q.map(x => x.value), v.map(x => t.gradient(x)))
}

///|
pub fn rotation_angle_pullback(
  vector : Array[Double],
) -> (Double, Array[Double]) {
  let t = @numeric.Tape::new()
  let v = t.vector(vector)
  let angle = ad_square(t, ad_log(t, ad_exp(t, v)))
  t.backward(angle)
  (angle.value, v.map(x => t.gradient(x)))
}

///|
/// The rotation leaf is exp(rotation_vector) @ reference.rotation, matching
/// the original MDP differential fixture and preserving its chain rule.
pub fn reward_pullback(
  kin : Kinematics,
  state : State,
  reference : State,
  reference_bodies : Array[BodyState],
  action : Array[Double],
  previous : Array[Double],
  rotation_vector : Array[Double],
) -> (Double, Array[Double], Array[Double], Array[Double]) {
  let t = @numeric.Tape::new()
  let base = lift(t, state)
  let rotation = t.vector(rotation_vector)
  let s = {
    ..base,
    rotation: ad_mat(t, ad_exp(t, rotation), t.vector(reference.rotation)),
  }
  let reward = ad_reward(
    t,
    kin,
    s,
    reference,
    reference_bodies,
    t.vector(action),
    t.vector(previous),
    RewardConfig::default(),
  )
  t.backward(reward)
  (
    reward.value,
    s.p.map(x => t.gradient(x)),
    rotation.map(x => t.gradient(x)),
    s.q.map(x => t.gradient(x)),
  )
}
