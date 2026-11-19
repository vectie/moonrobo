///|
/// Owns the legacy parent and temporal adapter together, so updates propagate through both networks as in TemporalActor.parameters().
pub(all) struct TemporalPolicy {
  base : @training.Actor
  temporal : TemporalActor
} derive(Debug)

///|
pub fn TemporalPolicy::new(
  base : @training.Actor,
  history_length : Int32,
  future_length : Int32,
  width : Int32,
  rng : @numeric.Rng,
) -> TemporalPolicy {
  {
    base,
    temporal: TemporalActor::new(
      base.obs_stats.mean,
      base.obs_stats.scale,
      base.goal_stats.mean,
      base.goal_stats.scale,
      base.lower,
      base.upper,
      base.action_delta_rad,
      history_length,
      future_length,
      width,
      rng,
    ),
  }
}

///|
pub fn TemporalPolicy::parameters(self : TemporalPolicy) -> Array[Double] {
  let result = self.base.network.parameters.copy()
  result.append(self.temporal.adapter.parameters)
  result
}

///|
pub fn TemporalPolicy::restore(
  self : TemporalPolicy,
  parameters : Array[Double],
) -> Unit {
  let n = self.base.network.parameters.length()
  guard parameters.length() == n + self.temporal.adapter.parameters.length() else {
    abort("temporal parameter count differs")
  }
  for i in 0..<n {
    self.base.network.parameters[i] = parameters[i]
  }
  for i in 0..<self.temporal.adapter.parameters.length() {
    self.temporal.adapter.parameters[i] = parameters[n + i]
  }
}

///|
pub fn TemporalPolicy::latent_mean(
  self : TemporalPolicy,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  history : Array[Array[@numeric.Value]],
  goal : Array[@numeric.Value],
  future : Array[Array[@numeric.Value]],
) -> Array[@numeric.Value] {
  let n = self.base.network.parameters.length()
  let base_parameters = Array::makei(n, fn(i) { parameters[i] })
  let adapter_parameters = Array::makei(parameters.length() - n, fn(i) {
    parameters[n + i]
  })
  let base_latent = self.base.latent_mean(
    tape,
    base_parameters,
    history[history.length() - 1],
    goal,
  )
  self.temporal.latent_mean(
    tape, adapter_parameters, base_latent, history, goal, future,
  )
}

///|
pub fn TemporalPolicy::forward(
  self : TemporalPolicy,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  history : Array[Array[@numeric.Value]],
  goal : Array[@numeric.Value],
  future : Array[Array[@numeric.Value]],
) -> Array[@numeric.Value] {
  self.temporal.action_from_latent(
    tape,
    self.latent_mean(tape, parameters, history, goal, future),
    goal,
  )
}

///|
pub fn TemporalPolicy::predict(
  self : TemporalPolicy,
  history : Array[Array[Double]],
  goal : Array[Double],
  future : Array[Array[Double]],
) -> Array[Double] {
  let tape = @numeric.Tape::new()
  self
  .forward(
    tape,
    tape.vector(self.parameters()),
    history.map(fn(row) { tape.vector(row) }),
    tape.vector(goal),
    future.map(fn(row) { tape.vector(row) }),
  )
  .map(fn(v) { v.value })
}

///|
pub(all) struct TemporalPoint {
  history : Array[Array[Double]]
  goal : Array[Double]
  future : Array[Array[Double]]
  target : Array[Double]
} derive(Debug, ToJson, FromJson)

///|
pub fn TemporalPolicy::clone_update(
  self : TemporalPolicy,
  optimizer : @numeric.Adam,
  points : Array[TemporalPoint],
) -> Double {
  guard !points.is_empty() else { abort("empty temporal supervision batch") }
  let tape = @numeric.Tape::new()
  let parameters = self.parameters()
  let bound = tape.vector(parameters)
  let errors : Array[@numeric.Value] = []
  for point in points {
    let predicted = self.forward(
      tape,
      bound,
      point.history.map(fn(row) { tape.vector(row) }),
      tape.vector(point.goal),
      point.future.map(fn(row) { tape.vector(row) }),
    )
    for i in 0..<predicted.length() {
      let delta = tape.scale(
        tape.sub(predicted[i], tape.scalar(point.target[i])),
        1.0 / self.base.action_delta_rad,
      )
      errors.push(tape.mul(delta, delta))
    }
  }
  let loss = tape.mean(errors)
  guard @numeric.finite(loss.value) else {
    abort("nonfinite temporal supervision loss")
  }
  tape.backward(loss)
  ignore(optimizer.step(parameters, tape, bound))
  self.restore(parameters)
  loss.value
}

///|
pub(all) struct ValuePoint {
  state : Array[Double]
  history : Array[Array[Double]]
  goals : Array[Array[Double]]
  context : Array[Double]
  remaining : Double
  target : Double
} derive(Debug, ToJson, FromJson)

///|
pub fn TemporalValue::fit_update(
  self : TemporalValue,
  optimizer : @numeric.Adam,
  points : Array[ValuePoint],
) -> Double {
  let tape = @numeric.Tape::new()
  let parameters = self.net.bind(tape)
  let errors = points.map(fn(point) {
    let value = self.forward(
      tape,
      parameters,
      tape.vector(point.state),
      point.history.map(fn(row) { tape.vector(row) }),
      point.goals.map(fn(row) { tape.vector(row) }),
      tape.vector(point.context),
      tape.scalar(point.remaining),
    )
    let delta = tape.scale(tape.sub(value, tape.scalar(point.target)), 0.01)
    tape.mul(delta, delta)
  })
  let loss = tape.mean(errors)
  guard @numeric.finite(loss.value) else {
    abort("nonfinite temporal value loss")
  }
  tape.backward(loss)
  ignore(optimizer.step(self.net.parameters, tape, parameters))
  loss.value
}

///|
pub fn TemporalValue::error(
  self : TemporalValue,
  points : Array[ValuePoint],
) -> Double {
  guard !points.is_empty() else { abort("empty value evaluation set") }
  let mut squared = 0.0
  for p in points {
    let delta = self.predict(
        p.state,
        p.history,
        p.goals,
        p.context,
        p.remaining,
      ) -
      p.target
    squared += delta * delta
  }
  (squared / points.length().to_double()).sqrt()
}

///|
pub fn make_value(
  model : @training.Dynamics,
  actor : TemporalPolicy,
  width : Int32,
  gamma : Double,
  duration : Double,
  rng : @numeric.Rng,
  dt~ : Double = 0.02,
  fall_height~ : Double = 0.35,
  fall_upright~ : Double = 0.5,
) -> TemporalValue {
  let history_length = 10
  let future_length = 10
  let base = actor.base
  let features = model.state_stats.mean.length() +
    history_length * base.obs_stats.mean.length() +
    (future_length + 1) * base.goal_stats.mean.length() +
    model.context_stats.mean.length() +
    1
  {
    state_mean: model.state_stats.mean.copy(),
    state_scale: model.state_stats.scale.copy(),
    obs_mean: base.obs_stats.mean.copy(),
    obs_scale: base.obs_stats.scale.copy(),
    goal_mean: base.goal_stats.mean.copy(),
    goal_scale: base.goal_stats.scale.copy(),
    context_mean: model.context_stats.mean.copy(),
    context_scale: model.context_stats.scale.copy(),
    gamma,
    dt,
    duration,
    fall_height,
    fall_upright,
    net: @numeric.MLP::new([features, width, 64, 1], rng, zero_last=true),
  }
}

///|
/// Callback collection keeps simulator resets, teacher labels and validation physics outside the numerical optimizer. Selection only uses held-out validation summaries.
pub(all) struct AggregationConfig {
  rounds : Int32
  updates_per_round : Int32
  batch_size : Int32
  recent_points : Int32
  learning_rate : Double
} derive(Debug)

///|
pub(all) struct TemporalFitResult {
  selected_round : Int32
  best_parameters : Array[Double]
  latest_parameters : Array[Double]
  validation : Array[@training.PhysicsSummary]
  collected_points : Int32
} derive(Debug)

///|
pub fn fit_temporal(
  actor : TemporalPolicy,
  original : Array[TemporalPoint],
  config : AggregationConfig,
  rng : @numeric.Rng,
  collect : (TemporalPolicy, Int32) -> Array[TemporalPoint],
  validate : (TemporalPolicy) -> @training.PhysicsSummary,
) -> TemporalFitResult {
  guard !original.is_empty() &&
    config.batch_size > 0 &&
    config.recent_points > 0 else {
    abort("invalid temporal aggregation data/config")
  }
  let optimizer = @numeric.Adam::new(
    actor.parameters().length(),
    config.learning_rate,
  )
  let recent : Array[TemporalPoint] = []
  let mut best_parameters = actor.parameters()
  let mut best = validate(actor)
  let validation = [best]
  let mut selected_round = 0
  let mut collected_points = 0
  for round in 0..<config.rounds {
    let fresh = collect(actor, round)
    collected_points += fresh.length()
    recent.append(fresh)
    while recent.length() > config.recent_points {
      recent.remove(0) |> ignore
    }
    guard !recent.is_empty() else {
      abort("student collection returned no training points")
    }
    for _ in 0..<config.updates_per_round {
      let batch = Array::makei(config.batch_size, fn(i) {
        if i < config.batch_size / 2 {
          original[rng.index(original.length())]
        } else {
          recent[rng.index(recent.length())]
        }
      })
      ignore(actor.clone_update(optimizer, batch))
    }
    let current = validate(actor)
    validation.push(current)
    if @training.ranks_above(current, best) {
      best = current
      best_parameters = actor.parameters()
      selected_round = round + 1
    }
  }
  let latest_parameters = actor.parameters()
  actor.restore(best_parameters)
  {
    selected_round,
    best_parameters,
    latest_parameters,
    validation,
    collected_points,
  }
}
