///|
pub(all) struct ImaginedReturn {
  total : @numeric.Value
  states : Array[Array[@numeric.Value]]
  rewards : Array[@numeric.Value]
  continuations : Array[@numeric.Value]
}

///|
/// The caller binds actor, dynamics and critic parameters on the same tape. Histories advance only with predicted observations, and the goal callback is the declared command schedule.
pub fn temporal_imagination(
  tape : @numeric.Tape,
  initial : Array[@numeric.Value],
  initial_history : Array[Array[@numeric.Value]],
  goals : Array[Array[@numeric.Value]],
  context : Array[@numeric.Value],
  horizon : Int32,
  future_length : Int32,
  gamma : Double,
  actor : (
    Array[Array[@numeric.Value]],
    Array[@numeric.Value],
    Array[Array[@numeric.Value]],
  ) -> Array[@numeric.Value],
  dynamics : (
    Array[@numeric.Value],
    Array[@numeric.Value],
    Array[@numeric.Value],
  ) -> Array[@numeric.Value],
  observation : (Array[@numeric.Value], Array[@numeric.Value]) -> Array[
    @numeric.Value,
  ],
  reward : (
    Array[@numeric.Value],
    Array[@numeric.Value],
    Array[@numeric.Value],
    Array[@numeric.Value],
  ) -> (@numeric.Value, @numeric.Value),
  bootstrap : (Array[@numeric.Value], Array[Array[@numeric.Value]], Int32) -> @numeric.Value,
  use_bootstrap : Bool,
) -> ImaginedReturn {
  guard horizon >= 0 &&
    !initial_history.is_empty() &&
    goals.length() >= horizon + future_length + 1 else {
    abort("insufficient imagination inputs")
  }
  let mut state = initial
  let mut history = initial_history.copy()
  let nu = goals[0].length()
  let last = history[history.length() - 1]
  let mut previous = Array::makei(nu, fn(i) { last[last.length() - nu + i] })
  let mut total = tape.scalar(0.0)
  let mut survival = tape.scalar(1.0)
  let mut discount = 1.0
  let states = [state]
  let rewards : Array[@numeric.Value] = []
  let continuations : Array[@numeric.Value] = []
  for t in 0..<horizon {
    let future = Array::makei(future_length, fn(i) { goals[t + 1 + i] })
    let action = actor(history, goals[t], future)
    state = dynamics(state, action, context)
    let (r, c) = reward(state, action, previous, goals[t])
    total = tape.add(total, tape.scale(tape.mul(survival, r), discount))
    survival = tape.mul(survival, c)
    let next_history = Array::makei(history.length(), fn(i) {
      if i + 1 < history.length() {
        history[i + 1]
      } else {
        observation(state, action)
      }
    })
    history = next_history
    previous = action
    states.push(state)
    rewards.push(r)
    continuations.push(c)
    discount *= gamma
  }
  if use_bootstrap {
    total = tape.add(
      total,
      tape.scale(
        tape.mul(survival, bootstrap(state, history, horizon)),
        discount,
      ),
    )
  }
  { total, states, rewards, continuations, }
}

///|
pub fn gaussian_log_probability(
  tape : @numeric.Tape,
  means : Array[@numeric.Value],
  sample : Array[Double],
  std : Double,
) -> @numeric.Value {
  guard std > 0.0 && means.length() == sample.length() else {
    abort("invalid Gaussian inputs")
  }
  let constant = @math.ln(std) + 0.9189385332046727
  let mut total = tape.scalar(0.0)
  for i in 0..<means.length() {
    let delta = tape.sub(means[i], tape.scalar(sample[i]))
    total = tape.sub(
      total,
      tape.add(
        tape.scalar(constant),
        tape.scale(tape.mul(delta, delta), 0.5 / (std * std)),
      ),
    )
  }
  total
}
