///|
fn round32(x : Double) -> Double {
  x.to_float().to_double()
}

///|
fn rounded(x : Double, legacy : Bool) -> Double {
  if legacy {
    round32(x)
  } else {
    x
  }
}

///|
fn finite_row(row : Array[Double], legacy : Bool) -> Array[Double] raise {
  guard row.all(@numeric.finite) else {
    fail("PPO numerical archive contains nonfinite inputs")
  }
  let result = row.map(x => rounded(x, legacy))
  guard result.all(@numeric.finite) else {
    fail("PPO numerical archive exceeds its floating-point dtype")
  }
  result
}

///|
fn close(
  actual : Double,
  expected : Double,
  atol : Double,
  rtol : Double,
  name : String,
) -> Unit raise {
  guard @numeric.finite(actual) &&
    @numeric.finite(expected) &&
    (actual - expected).abs() <= atol + rtol * expected.abs() else {
    fail(
      "PPO numerical mismatch in \{name}: stored=\{actual}, recomputed=\{expected}",
    )
  }
}

///|
fn checked_row(
  actual : Array[Double],
  expected : Array[Double],
  atol : Double,
  rtol : Double,
  name : String,
) -> Double raise {
  guard actual.length() == expected.length() else {
    fail("PPO numerical row width differs: " + name)
  }
  let mut maximum = 0.0
  for j in 0..<actual.length() {
    close(actual[j], expected[j], atol, rtol, name + "[" + j.to_string() + "]")
    maximum = maximum.max((actual[j] - expected[j]).abs())
  }
  maximum
}

///|
// Match the legacy tensor dtype at each arithmetic boundary, retaining strict equality checks.
fn latent_setpoint(
  actor : @temporal.TemporalPolicy,
  latent : Array[Double],
  goal : Array[Double],
  legacy : Bool,
) -> Array[Double] raise {
  let nu = actor.base.lower.length()
  guard latent.length() == nu && goal.length() == nu else {
    fail("PPO latent/goal dimensions differ from actor")
  }
  let latent = finite_row(latent, legacy)
  let goal = finite_row(goal, legacy)
  Array::makei(nu, j => {
    let bounded = rounded(@math.tanh(latent[j]), legacy)
    let delta = rounded(
      rounded(actor.base.action_delta_rad, legacy) * bounded,
      legacy,
    )
    let request = rounded(goal[j] + delta, legacy)
    request
    .min(rounded(actor.base.upper[j], legacy))
    .max(rounded(actor.base.lower[j], legacy))
  })
}

///|
fn objective(
  state : Array[Double],
  action : Array[Double],
  previous : Array[Double],
  goal : Array[Double],
  q_indices : Array[Int32],
  target_height : Double,
  legacy : Bool,
) -> (Double, Double) raise {
  if !legacy {
    let t = @numeric.Tape::new()
    let (reward, continuation) = @training.step_reward(
      t,
      t.vector(state),
      t.vector(action),
      t.vector(previous),
      t.vector(goal),
      q_indices,
      target_height,
    )
    return (reward.value, continuation.value)
  }
  let state = finite_row(state, true)
  let action = finite_row(action, true)
  let previous = finite_row(previous, true)
  let goal = finite_row(goal, true)
  let nu = action.length()
  guard nu > 0 &&
    previous.length() == nu &&
    goal.length() == nu &&
    q_indices.length() == nu &&
    state.length() >= 7 else {
    fail("invalid PPO objective tensor dimensions")
  }
  let square = (x : Double) => round32(x * x)
  let mut tracking_sum = 0.0
  let mut smooth_sum = 0.0
  for j in 0..<nu {
    guard q_indices[j] >= 0 && q_indices[j] < state.length() else {
      fail("actor joint index exceeds logged state")
    }
    tracking_sum = round32(
      tracking_sum + square(round32(state[q_indices[j]] - goal[j])),
    )
    smooth_sum = round32(
      smooth_sum +
      square(round32(round32(action[j] - previous[j]) / round32(0.1))),
    )
  }
  let upright = round32(
    1.0 - round32(2.0 * round32(square(state[4]) + square(state[5]))),
  )
  let tracking = round32(
    @math.exp(round32(-round32(tracking_sum / nu.to_double()) / round32(0.09))),
  )
  let balance = round32(
    @math.exp(-square(round32(round32(1.0 - upright) / round32(0.2)))),
  )
  let height = round32(
    @math.exp(
      -square(
        round32(round32(state[2] - round32(target_height)) / round32(0.15)),
      ),
    ),
  )
  let smooth = round32(round32(0.05) * round32(smooth_sum / nu.to_double()))
  let reward = round32(round32(round32(tracking + balance) + height) - smooth)
  fn sigmoid(x : Double) -> Double {
    // The result is rounded to the legacy tensor scalar dtype.
    round32(1.0 / (1.0 + @math.exp(-x)))
  }
  let h = sigmoid(round32(round32(state[2] - round32(0.35)) / round32(0.02)))
  let u = sigmoid(round32(round32(upright - round32(0.5)) / round32(0.05)))
  (reward, round32(h * u))
}

///|
fn returns(
  rewards : Array[Double],
  continuation : Array[Double],
  terminated : Array[Bool],
  gamma : Double,
  legacy : Bool,
) -> Array[Double] {
  if !legacy {
    return @training.physical_return_targets(
      rewards, continuation, terminated, 0.0, gamma,
    )
  }
  let out = Array::make(rewards.length(), 0.0)
  let mut value = 0.0
  for step in 0..<rewards.length() {
    let i = rewards.length() - step - 1
    let alive = if terminated[i] { 0.0 } else { 1.0 }
    let coefficient = round32(round32(round32(gamma) * continuation[i]) * alive)
    value = round32(rewards[i] + round32(coefficient * value))
    out[i] = value
  }
  out
}

///|
fn visitation(
  continuation : Array[Double],
  gamma : Double,
  legacy : Bool,
) -> Array[Double] {
  if !legacy {
    return @temporal.discounted_visitation(continuation, gamma)
  }
  let out : Array[Double] = []
  let mut survival = 1.0
  for i, c in continuation {
    let discount = round32(@math.pow(round32(gamma), i.to_double()))
    out.push(round32(survival * discount))
    survival = round32(survival * c)
  }
  out
}
