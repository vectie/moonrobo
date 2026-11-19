///|
/// Actual teacher targets for cloning and dataset aggregation, independent of applied student actions.
pub(all) struct TeacherPoint {
  observation : Array[Double]
  goal : Array[Double]
  target : Array[Double]
  time_s : Double
} derive(Debug)

///|
pub(all) struct PhysicsSummary {
  falls : Int32
  survival_s : Double
  joint_rmse_rad : Double
} derive(Debug)

///|
/// Lexicographic validation-physics ranking from policy.ranking.
pub fn ranks_above(candidate : PhysicsSummary, best : PhysicsSummary) -> Bool {
  if candidate.falls != best.falls {
    candidate.falls < best.falls
  } else if candidate.survival_s != best.survival_s {
    candidate.survival_s > best.survival_s
  } else {
    candidate.joint_rmse_rad < best.joint_rmse_rad
  }
}

///|
pub fn qualifies(
  summary : PhysicsSummary,
  max_mean_joint_rmse_rad : Double,
) -> Bool {
  summary.falls == 0 && summary.joint_rmse_rad <= max_mean_joint_rmse_rad
}

///|
pub fn Actor::clone_update(
  self : Actor,
  optimizer : @numeric.Adam,
  points : Array[TeacherPoint],
) -> Double {
  let tape = @numeric.Tape::new()
  let bound = self.network.bind(tape)
  let errors = []
  for point in points {
    let action = self.forward(
      tape,
      bound,
      tape.vector(point.observation),
      tape.vector(point.goal),
    )
    for j in 0..<action.length() {
      let delta = tape.scale(
        tape.sub(action[j], tape.scalar(point.target[j])),
        1 / self.action_delta_rad,
      )
      errors.push(tape.mul(delta, delta))
    }
  }
  let loss = tape.mean(errors)
  guard @numeric.finite(loss.value) else {
    abort("nonfinite cloning/aggregation loss")
  }
  tape.backward(loss)
  ignore(optimizer.step(self.network.parameters, tape, bound))
  loss.value
}

///|
pub(all) struct CloningConfig {
  updates : Int32
  batch_size : Int32
  evaluation_updates : Array[Int32]
  learning_rate : Double
} derive(Debug)

///|
pub struct CloningRow {
  update : Int32
  action_loss : Double?
  validation : PhysicsSummary
} derive(Debug)

///|
pub struct CloningResult {
  selected_update : Int32
  best_parameters : Array[Double]
  latest_parameters : Array[Double]
  history : Array[CloningRow]
  action_rmse_rad : Double
} derive(Debug)

///|
/// Caller supplies actual validation physics; callback is also invoked at update zero.
pub fn behavior_clone(
  actor : Actor,
  points : Array[TeacherPoint],
  config : CloningConfig,
  rng : @numeric.Rng,
  validate : (Actor) -> PhysicsSummary,
) -> CloningResult {
  guard points.length() > 0 && config.batch_size > 1 else {
    abort("cloning needs nonempty point batch")
  }
  let early = points.filter(p => p.time_s < 2)
  guard early.length() > 0 else { abort("cloning needs early points") }
  let optimizer = @numeric.Adam::new(
    actor.network.parameters.length(),
    config.learning_rate,
  )
  let mut best = validate(actor)
  let mut best_parameters = actor.network.parameters.copy()
  let mut selected = 0
  let history = [{ update: 0, action_loss: None, validation: best, }]
  for update in 1..<=config.updates {
    let batch = Array::makei(config.batch_size, i => {
      if i < config.batch_size / 2 {
        points[rng.index(points.length())]
      } else {
        early[rng.index(early.length())]
      }
    })
    let loss = actor.clone_update(optimizer, batch)
    if config.evaluation_updates.contains(update) {
      let current = validate(actor)
      history.push({ update, action_loss: Some(loss), validation: current, })
      if ranks_above(current, best) {
        best = current
        selected = update
        best_parameters = actor.network.parameters.copy()
      }
    }
  }
  let latest = actor.network.parameters.copy()
  restore_parameters(actor.network, best_parameters)
  let mut errors = 0.0
  let mut count = 0
  for point in points {
    let predicted = actor.predict(point.observation, point.goal)
    for j in 0..<predicted.length() {
      let d = predicted[j] - point.target[j]
      errors += d * d
      count += 1
    }
  }
  {
    selected_update: selected,
    best_parameters,
    latest_parameters: latest,
    history,
    action_rmse_rad: (errors / count.to_double()).sqrt(),
  }
}

///|
pub fn restore_parameters(
  network : @numeric.MLP,
  parameters : Array[Double],
) -> Unit {
  guard network.parameters.length() == parameters.length() else {
    abort("parameter shape mismatch")
  }
  for i in 0..<parameters.length() {
    network.parameters[i] = parameters[i]
  }
}

///|
pub(all) struct AggregationConfig {
  rounds : Int32
  updates_per_round : Int32
  batch_size : Int32
  recent_points : Int32
  learning_rate : Double
} derive(Debug)

///|
pub struct AggregationResult {
  selected_round : Int32
  best_parameters : Array[Double]
  latest_parameters : Array[Double]
  history : Array[CloningRow]
  collected_points : Int32
} derive(Debug)

///|
/// Physics collector returns teacher labels for states visited by the student.
pub fn dataset_aggregate(
  actor : Actor,
  original : Array[TeacherPoint],
  config : AggregationConfig,
  rng : @numeric.Rng,
  collect : (Actor, Int32) -> Array[TeacherPoint],
  validate : (Actor) -> PhysicsSummary,
) -> AggregationResult {
  guard original.length() > 0 &&
    config.batch_size > 1 &&
    config.recent_points > 0 &&
    config.updates_per_round > 0 else {
    abort("invalid aggregation configuration")
  }
  let optimizer = @numeric.Adam::new(
    actor.network.parameters.length(),
    config.learning_rate,
  )
  let recent = []
  let mut best = validate(actor)
  let mut best_parameters = actor.network.parameters.copy()
  let mut selected = 0
  let mut collected = 0
  let history = [{ update: 0, action_loss: None, validation: best, }]
  for round in 1..<=config.rounds {
    let fresh = collect(actor, round - 1)
    guard fresh.length() > 0 else {
      abort("aggregation collected no teacher labels")
    }
    collected += fresh.length()
    recent.append(fresh)
    while recent.length() > config.recent_points {
      ignore(recent.remove(0))
    }
    let mut loss = 0.0
    for _ in 0..<config.updates_per_round {
      let batch = Array::makei(config.batch_size, i => {
        if i < config.batch_size / 2 {
          original[rng.index(original.length())]
        } else {
          recent[rng.index(recent.length())]
        }
      })
      loss = actor.clone_update(optimizer, batch)
    }
    let current = validate(actor)
    history.push({
      update: round,
      action_loss: Some(loss),
      validation: current,
    })
    if ranks_above(current, best) {
      best = current
      selected = round
      best_parameters = actor.network.parameters.copy()
    }
  }
  let latest = actor.network.parameters.copy()
  restore_parameters(actor.network, best_parameters)
  {
    selected_round: selected,
    best_parameters,
    latest_parameters: latest,
    history,
    collected_points: collected,
  }
}
