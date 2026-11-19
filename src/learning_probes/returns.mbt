///|
pub suberror ProbeError {
  Invalid(String)
}

///|
fn require_width(a : Array[Double], b : Array[Double]) -> Unit raise ProbeError {
  if a.length() != b.length() || a.is_empty() {
    raise Invalid("nonempty equal widths required")
  }
}

///|
pub fn gravity(state : Array[Double]) -> Array[Double] raise ProbeError {
  if state.length() < 7 {
    raise Invalid("free-root state needs at least seven coordinates")
  }
  let w = state[3]
  let x = state[4]
  let y = state[5]
  let z = state[6]
  [-2 * (x * z - w * y), -2 * (y * z + w * x), -(1 - 2 * (x * x + y * y))]
}

///|
/// Exact scalar translation of policy.step_reward, including smoothness penalty.
pub fn step_reward(
  state : Array[Double],
  action : Array[Double],
  previous : Array[Double],
  goal : Array[Double],
  q_indices : Array[Int32],
  target_height : Double,
) -> (Double, Double) raise ProbeError {
  require_width(action, previous)
  require_width(action, goal)
  if q_indices.length() != goal.length() ||
    q_indices.any(i => i < 0 || i >= state.length()) {
    raise Invalid("invalid joint indices")
  }
  let upright = -gravity(state)[2]
  let mut error = 0.0
  let mut smooth = 0.0
  for i, q in q_indices {
    let delta = state[q] - goal[i]
    error += delta * delta
    let d = (action[i] - previous[i]) / 0.1
    smooth += d * d
  }
  let tracking = @math.exp(-error / q_indices.length().to_double() / 0.09)
  let balance = (1.0 - upright) / 0.2
  let height = (state[2] - target_height) / 0.15
  let reward = tracking +
    @math.exp(-balance * balance) +
    @math.exp(-height * height) -
    0.05 * smooth / action.length().to_double()
  let continuation = 1.0 /
    (1.0 + @math.exp(-(state[2] - 0.35) / 0.02)) /
    (1.0 + @math.exp(-(upright - 0.5) / 0.05))
  (reward, continuation)
}

///|
/// Complete recorded rewards with zero tail at end of the physical episode.
pub fn recorded_returns(
  rewards : Array[Double],
  continuation : Array[Double],
  terminated : Array[Bool],
  gamma : Double,
) -> (Array[Double], Array[Double]) raise ProbeError {
  require_width(rewards, continuation)
  if terminated.length() != rewards.length() {
    raise Invalid("termination width differs")
  }
  let hard = Array::make(rewards.length(), 0.0)
  let soft = Array::make(rewards.length(), 0.0)
  for i = rewards.length() - 1; i >= 0; i = i - 1 {
    let h = if i + 1 < rewards.length() { hard[i + 1] } else { 0.0 }
    let s = if i + 1 < rewards.length() { soft[i + 1] } else { 0.0 }
    hard[i] = rewards[i] + gamma * (if terminated[i] { 0.0 } else { h })
    soft[i] = rewards[i] + gamma * continuation[i] * s
  }
  (hard, soft)
}

///|
/// model_probe.score: survival-weighted finite-horizon return, no value tail.
pub fn score(
  states : Array[Array[Double]],
  actions : Array[Array[Double]],
  previous : Array[Double],
  goals : Array[Array[Double]],
  q_indices : Array[Int32],
  target_height : Double,
  gamma : Double,
) -> Double raise ProbeError {
  if states.length() != actions.length() || goals.length() != actions.length() {
    raise Invalid("trajectory lengths differ")
  }
  let mut survival = 1.0
  let mut discount = 1.0
  let mut total = 0.0
  let mut prev = previous
  for t, action in actions {
    let (reward, continuation) = step_reward(
      states[t],
      action,
      prev,
      goals[t],
      q_indices,
      target_height,
    )
    total += discount * survival * reward
    survival *= continuation
    discount *= gamma
    prev = action
  }
  total
}

///|
pub fn cosine(a : Array[Double], b : Array[Double]) -> Double? raise ProbeError {
  require_width(a, b)
  let mut dot = 0.0
  let mut na = 0.0
  let mut nb = 0.0
  for i, x in a {
    dot += x * b[i]
    na += x * x
    nb += b[i] * b[i]
  }
  let denominator = (na * nb).sqrt()
  if denominator > 0 {
    Some(dot / denominator)
  } else {
    None
  }
}

///|
pub fn normalized_mse(
  prediction : Array[Double],
  target : Array[Double],
  scale : Array[Double],
) -> Double raise ProbeError {
  require_width(prediction, target)
  require_width(target, scale)
  let mut total = 0.0
  for i, x in prediction {
    if scale[i] <= 0 || scale[i].is_nan() || scale[i].is_inf() {
      raise Invalid("normalization scale must be finite and positive")
    }
    let d = (x - target[i]) / scale[i]
    total += d * d
  }
  total / prediction.length().to_double()
}
