///|
pub fn causal_history(
  observations : Array[Array[Double]],
  times : Array[Double],
  length : Int32,
  dt : Double,
) -> Array[Array[Array[Double]]] {
  guard length > 0 &&
    observations.length() == times.length() &&
    !times.is_empty() &&
    dt > 0.0 else {
    abort("nonempty aligned observations and positive history required")
  }
  let result : Array[Array[Array[Double]]] = []
  let mut start = 0
  for i in 0..<times.length() {
    if i > 0 &&
      (times[i] - times[i - 1] - dt).abs() >
      1.0e-6 * @math.maximum(dt, (times[i] - times[i - 1]).abs()) {
      start = i
    }
    result.push(
      Array::makei(length, fn(j) {
        let index = i - length + 1 + j
        observations[if index < start { start } else { index }].copy()
      }),
    )
  }
  result
}

///|
pub fn preview_goals(
  reference : (Double) -> Array[Double],
  time : Double,
  dt : Double,
  count : Int32,
) -> Array[Array[Double]] {
  guard count >= 0 && dt > 0.0 else {
    abort("invalid goal preview length or cadence")
  }
  Array::makei(count, fn(i) { reference(time + (i + 1).to_double() * dt) })
}

///|
pub(all) struct TemporalActor {
  history_length : Int32
  future_length : Int32
  obs_mean : Array[Double]
  obs_scale : Array[Double]
  goal_mean : Array[Double]
  goal_scale : Array[Double]
  lower : Array[Double]
  upper : Array[Double]
  action_delta : Double
  adapter : @numeric.MLP
} derive(Debug)

///|
pub fn TemporalActor::new(
  obs_mean : Array[Double],
  obs_scale : Array[Double],
  goal_mean : Array[Double],
  goal_scale : Array[Double],
  lower : Array[Double],
  upper : Array[Double],
  action_delta : Double,
  history_length : Int32,
  future_length : Int32,
  width : Int32,
  rng : @numeric.Rng,
) -> TemporalActor {
  guard history_length > 0 && future_length >= 0 else {
    abort("invalid temporal lengths")
  }
  let features = history_length * obs_mean.length() +
    (1 + future_length) * goal_mean.length()
  {
    history_length,
    future_length,
    obs_mean,
    obs_scale,
    goal_mean,
    goal_scale,
    lower,
    upper,
    action_delta,
    adapter: @numeric.MLP::new(
      [features, width, width, goal_mean.length()],
      rng,
      zero_last=true,
    ),
  }
}

///|
fn encode(
  tape : @numeric.Tape,
  row : Array[@numeric.Value],
  mean : Array[Double],
  scale : Array[Double],
) -> Array[@numeric.Value] {
  guard row.length() == mean.length() && mean.length() == scale.length() else {
    abort("normalization shape mismatch")
  }
  Array::makei(row.length(), fn(i) {
    tape.scale(tape.sub(row[i], tape.scalar(mean[i])), 1.0 / scale[i])
  })
}

///|
pub fn TemporalActor::latent_mean(
  self : TemporalActor,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  base_latent : Array[@numeric.Value],
  history : Array[Array[@numeric.Value]],
  goal : Array[@numeric.Value],
  future : Array[Array[@numeric.Value]],
) -> Array[@numeric.Value] {
  guard history.length() == self.history_length &&
    future.length() == self.future_length else {
    abort("temporal input shape mismatch")
  }
  let features : Array[@numeric.Value] = []
  for row in history {
    for x in encode(tape, row, self.obs_mean, self.obs_scale) {
      features.push(x)
    }
  }
  for x in encode(tape, goal, self.goal_mean, self.goal_scale) {
    features.push(x)
  }
  for row in future {
    for x in encode(tape, row, self.goal_mean, self.goal_scale) {
      features.push(x)
    }
  }
  let adapter = self.adapter.forward(tape, parameters, features)
  guard base_latent.length() == adapter.length() else {
    abort("base latent dimension mismatch")
  }
  Array::makei(adapter.length(), fn(i) { tape.add(base_latent[i], adapter[i]) })
}

///|
pub fn TemporalActor::action_from_latent(
  self : TemporalActor,
  tape : @numeric.Tape,
  latent : Array[@numeric.Value],
  goal : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  Array::makei(goal.length(), fn(i) {
    tape.clamp(
      tape.add(goal[i], tape.scale(tape.tanh(latent[i]), self.action_delta)),
      self.lower[i],
      self.upper[i],
    )
  })
}

///|
pub fn TemporalActor::predict(
  self : TemporalActor,
  base_latent : Array[Double],
  history : Array[Array[Double]],
  goal : Array[Double],
  future : Array[Array[Double]],
) -> Array[Double] {
  let tape = @numeric.Tape::new()
  let latent = self.latent_mean(
    tape,
    self.adapter.bind(tape),
    tape.vector(base_latent),
    history.map(fn(row) { tape.vector(row) }),
    tape.vector(goal),
    future.map(fn(row) { tape.vector(row) }),
  )
  self
  .action_from_latent(tape, latent, tape.vector(goal))
  .map(fn(v) { v.value })
}

///|
pub struct TemporalRunner {
  actor : TemporalActor
  dt : Double
  reference : (Double) -> Array[Double]
  base_latent : (Array[Double], Array[Double]) -> Array[Double]
  frames : Array[Array[Double]]
  mut index : Int32
}

///|
pub fn TemporalRunner::new(
  actor : TemporalActor,
  dt : Double,
  reference : (Double) -> Array[Double],
  base_latent : (Array[Double], Array[Double]) -> Array[Double],
) -> TemporalRunner {
  { actor, dt, reference, base_latent, frames: [], index: 0, }
}

///|
pub fn TemporalRunner::predict(
  self : TemporalRunner,
  observation : Array[Double],
  goal : Array[Double],
) -> Array[Double] {
  if self.frames.is_empty() {
    for _ in 0..<self.actor.history_length {
      self.frames.push(observation.copy())
    }
  } else {
    self.frames.remove(0) |> ignore
    self.frames.push(observation.copy())
  }
  let time = self.index.to_double() * self.dt
  let expected = (self.reference)(time)
  guard expected.length() == goal.length() else {
    abort("planned reference dimension mismatch")
  }
  for i in 0..<goal.length() {
    guard (expected[i] - goal[i]).abs() <= 1.0e-10 + 1.0e-10 * goal[i].abs() else {
      abort("planned reference and current physical goal disagree")
    }
  }
  let future = preview_goals(
    self.reference,
    time,
    self.dt,
    self.actor.future_length,
  )
  self.index += 1
  self.actor.predict(
    (self.base_latent)(observation, goal),
    self.frames,
    goal,
    future,
  )
}
