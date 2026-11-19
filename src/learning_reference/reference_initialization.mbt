///|
pub(all) struct TrainingPoint {
  history : Array[Array[Double]]
  current : Array[Double]
  future : Array[Array[Double]]
  valid : Array[Bool]
  target : Array[Double]
} derive(Debug)

///|
/// Teacher controls are labels only. History and preview are entirely derived
/// from observations and goals, so changing labels cannot change policy inputs.
pub fn training_points(
  observations : Array[Array[Double]],
  goals : Array[Array[Double]],
  source_setpoints : Array[Array[Double]],
  history_length : Int32,
  future_length : Int32,
  nu~ : Int32 = 29,
) -> Array[TrainingPoint] {
  let count = observations.length()
  guard history_length > 0 &&
    future_length >= 0 &&
    goals.length() == count + 1 &&
    source_setpoints.length() == count else {
    abort("training point shape")
  }
  Array::makei(count, i => {
    let desired = reference_observation(goals[i], nu~)
    guard observations[i][:2 * nu + 6] == desired[:2 * nu + 6] else {
      abort("source physical observations do not match current reference")
    }
    let command = reference_command(goals, i, future_length)
    {
      history: Array::makei(history_length, j => {
        observations[(i - history_length + 1 + j).max(0)].copy()
      }),
      current: command.current,
      future: command.future,
      valid: command.valid,
      target: source_setpoints[i].copy(),
    }
  })
}

///|
pub fn prediction(
  actor : ReferenceActor,
  point : TrainingPoint,
) -> Array[Double] {
  actor.forward(
    point.history,
    point.current,
    point.future,
    point.valid,
    Array::make(6, 0.0),
    Array::make(6, 0.0),
  )
}

///|
pub fn fit_error(
  actor : ReferenceActor,
  points : Array[TrainingPoint],
) -> (Double, Double) {
  let mut total = 0.0
  let mut maximum = 0.0
  let mut count = 0
  for point in points {
    let output = prediction(actor, point)
    for i, x in output {
      let error = x - point.target[i]
      total += error * error
      maximum = maximum.max(error.abs())
      count += 1
    }
  }
  guard count > 0 else { abort("nonempty fitting points required") }
  ((total / count.to_double()).sqrt(), maximum)
}

///|
pub(all) struct ReferenceValue {
  state_mean : Array[Double]
  state_scale : Array[Double]
  obs_mean : Array[Double]
  obs_scale : Array[Double]
  goal_mean : Array[Double]
  goal_scale : Array[Double]
  clips : Int32
  net : Array[Dense]
} derive(Debug, ToJson, FromJson)

///|
pub fn ReferenceValue::forward(
  self : ReferenceValue,
  state : Array[Double],
  history : Array[Array[Double]],
  current : Array[Double],
  features : Array[Double],
  reference_features : Array[Double],
  context : Array[Double],
  clip : Int32,
  step : Int32,
  remaining : Int32,
  root_position : Array[Double],
  root_quaternion : Array[Double],
) -> Double {
  guard clip >= 0 && clip < self.clips else { abort("value clip index") }
  let relative = state.mapi((i, x) => {
    if i < 3 {
      x - root_position[i]
    } else {
      x
    }
  })
  let input = normalize(relative, self.state_mean, self.state_scale)
  for obs in history {
    input.append(normalize(obs, self.obs_mean, self.obs_scale))
  }
  input.append(normalize(current, self.goal_mean, self.goal_scale))
  for x in features[3:] {
    input.push(x / 0.2)
  }
  for x in reference_features[3:] {
    input.push(x / 0.2)
  }
  input.append(context)
  for i in 0..<self.clips {
    input.push(if i == clip { 1.0 } else { 0.0 })
  }
  input.push(step.to_double() / 1500.0)
  input.push(remaining.to_double() / 1500.0)
  input.append(root_quaternion)
  6.0 * @math.tanh(network(self.net, input)[0] / 6.0)
}
