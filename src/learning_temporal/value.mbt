///|
pub(all) struct TemporalValue {
  state_mean : Array[Double]
  state_scale : Array[Double]
  obs_mean : Array[Double]
  obs_scale : Array[Double]
  goal_mean : Array[Double]
  goal_scale : Array[Double]
  context_mean : Array[Double]
  context_scale : Array[Double]
  gamma : Double
  dt : Double
  duration : Double
  fall_height : Double
  fall_upright : Double
  net : @numeric.MLP
} derive(Debug)

///|
pub fn TemporalValue::forward(
  self : TemporalValue,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  state : Array[@numeric.Value],
  history : Array[Array[@numeric.Value]],
  goals : Array[Array[@numeric.Value]],
  context : Array[@numeric.Value],
  remaining : @numeric.Value,
) -> @numeric.Value {
  let x = state[4].value
  let y = state[5].value
  let upright = 1.0 - 2.0 * (x * x + y * y)
  if state[2].value < self.fall_height || upright < self.fall_upright {
    return tape.scalar(0.0)
  }
  let features = encode(tape, state, self.state_mean, self.state_scale)
  features[0] = tape.scalar(0.0)
  features[1] = tape.scalar(0.0)
  for row in history {
    for v in encode(tape, row, self.obs_mean, self.obs_scale) {
      features.push(v)
    }
  }
  for row in goals {
    for v in encode(tape, row, self.goal_mean, self.goal_scale) {
      features.push(v)
    }
  }
  for v in encode(tape, context, self.context_mean, self.context_scale) {
    features.push(v)
  }
  features.push(tape.scale(remaining, 1.0 / self.duration))
  let raw = self.net.forward(tape, parameters, features)[0]
  let steps = tape.scale(tape.clamp(remaining, 0.0, 1.0 / 0.0), 1.0 / self.dt)
  let power = tape.exp(tape.scale(steps, @math.ln(self.gamma)))
  let bound = tape.scale(
    tape.sub(tape.scalar(1.0), power),
    3.0 / (1.0 - self.gamma),
  )
  tape.mul(bound, tape.tanh(tape.scale(raw, 1.0 / 300.0)))
}

///|
pub fn TemporalValue::predict(
  self : TemporalValue,
  state : Array[Double],
  history : Array[Array[Double]],
  goals : Array[Array[Double]],
  context : Array[Double],
  remaining : Double,
) -> Double {
  let tape = @numeric.Tape::new()
  self.forward(
    tape,
    self.net.bind(tape),
    tape.vector(state),
    history.map(fn(row) { tape.vector(row) }),
    goals.map(fn(row) { tape.vector(row) }),
    tape.vector(context),
    tape.scalar(remaining),
  ).value
}

///|
pub fn discounted_visitation(
  continuation : Array[Double],
  gamma : Double,
) -> Array[Double] {
  let mut survival = 1.0
  let mut discount = 1.0
  continuation.map(fn(c) {
    let weight = survival * discount
    survival *= c
    discount *= gamma
    weight
  })
}

///|
pub fn policy_loss(
  tape : @numeric.Tape,
  new_log_prob : Array[@numeric.Value],
  old_log_prob : Array[Double],
  advantage : Array[Double],
  weight : Array[Double],
  clip : Double,
) -> @numeric.Value {
  let losses = Array::makei(new_log_prob.length(), fn(i) {
    let ratio = tape.exp(
      tape.sub(new_log_prob[i], tape.scalar(old_log_prob[i])),
    )
    let a = tape.scale(ratio, advantage[i])
    let b = tape.scale(tape.clamp(ratio, 1.0 - clip, 1.0 + clip), advantage[i])
    tape.scale(tape.minimum(a, b), -weight[i])
  })
  tape.mean(losses)
}

///|
pub fn exact_kl(
  new_means : Array[Array[Double]],
  old_means : Array[Array[Double]],
  std : Double,
) -> Double {
  guard !new_means.is_empty() &&
    new_means.length() == old_means.length() &&
    std > 0.0 else {
    abort("invalid Gaussian KL inputs")
  }
  let mut total = 0.0
  for i in 0..<new_means.length() {
    for j in 0..<new_means[i].length() {
      let d = new_means[i][j] - old_means[i][j]
      total += d * d / (2.0 * std * std)
    }
  }
  total / new_means.length().to_double()
}
