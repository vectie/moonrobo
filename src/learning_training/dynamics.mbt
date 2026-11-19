///|
/// Array-based translation of dynamics.py; time-major windows preserve BPTT.
pub(all) struct Window {
  state : Array[Array[Double]]
  action : Array[Array[Double]]
  target : Array[Array[Double]]
  context : Array[Double]
  start_time_s : Double
} derive(Debug)

///|
pub struct Dynamics {
  state_stats : @numeric.Normalization
  action_stats : @numeric.Normalization
  context_stats : @numeric.Normalization
  network : @numeric.MLP
  translation_invariant : Bool
  root_integration_dt : Double?
} derive(Debug)

///|
pub fn Dynamics::new(
  state_stats : @numeric.Normalization,
  action_stats : @numeric.Normalization,
  context_stats : @numeric.Normalization,
  width : Int32,
  rng : @numeric.Rng,
  translation_invariant~ : Bool = false,
  root_integration_dt~ : Double? = None,
) -> Dynamics {
  let ns = state_stats.mean.length()
  match root_integration_dt {
    Some(dt) => {
      guard ns == 71 && dt > 0 else {
        abort("root integration requires G1 71-state and positive dt")
      }
    }
    None => ()
  }
  {
    state_stats,
    action_stats,
    context_stats,
    network: @numeric.MLP::new(
      [
        ns + action_stats.mean.length() + context_stats.mean.length(),
        width,
        width,
        ns,
      ],
      rng,
      zero_last=true,
    ),
    translation_invariant: translation_invariant ||
    root_integration_dt is Some(_),
    root_integration_dt,
  }
}

///|
pub fn Dynamics::forward(
  self : Dynamics,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  state : Array[@numeric.Value],
  action : Array[@numeric.Value],
  context : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  guard state.length() >= 7 else { abort("dynamics requires root quaternion") }
  let inputs = self.state_stats.apply(tape, state)
  if self.translation_invariant {
    inputs[0] = tape.scalar(0)
    inputs[1] = tape.scalar(0)
  }
  inputs.append(self.action_stats.apply(tape, action))
  inputs.append(self.context_stats.apply(tape, context))
  let residual = self.network.forward(tape, parameters, inputs)
  let output = Array::makei(state.length(), i => {
    tape.add(state[i], tape.scale(residual[i], self.state_stats.scale[i]))
  })
  let mut norm2 = tape.scalar(0)
  for i in 3..<7 {
    norm2 = tape.add(norm2, tape.mul(output[i], output[i]))
  }
  // F.normalize uses max(norm, eps); avoid sqrt derivative at an exactly zero norm.
  let norm = if norm2.value < 0.000000000000000000000001 {
    tape.scalar(0.000000000001)
  } else {
    tape.sqrt(norm2)
  }
  for i in 3..<7 {
    output[i] = tape.div(output[i], norm)
  }
  match self.root_integration_dt {
    Some(dt) =>
      for i in 0..<3 {
        output[i] = tape.add(
          state[i],
          tape.scale(tape.add(state[36 + i], output[36 + i]), 0.5 * dt),
        )
      }
    None => ()
  }
  output
}

///|
pub fn Dynamics::imagine(
  self : Dynamics,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  initial : Array[@numeric.Value],
  actions : Array[Array[@numeric.Value]],
  context : Array[@numeric.Value],
) -> Array[Array[@numeric.Value]] {
  let mut state = initial
  let predicted = []
  for action in actions {
    state = self.forward(tape, parameters, state, action, context)
    predicted.push(state)
  }
  predicted
}

///|
pub fn Dynamics::predict(
  self : Dynamics,
  state : Array[Double],
  action : Array[Double],
  context : Array[Double],
) -> Array[Double] {
  let tape = @numeric.Tape::new()
  self
  .forward(
    tape,
    self.network.bind(tape),
    tape.vector(state),
    tape.vector(action),
    tape.vector(context),
  )
  .map(x => x.value)
}

///|
pub fn Dynamics::loss(
  self : Dynamics,
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
  windows : Array[Window],
) -> @numeric.Value {
  let errors = []
  for w in windows {
    guard w.state.length() > 0 && w.action.length() == w.target.length() else {
      abort("invalid dynamics window")
    }
    let predictions = self.imagine(
      tape,
      parameters,
      tape.vector(w.state[0]),
      w.action.map(row => tape.vector(row)),
      tape.vector(w.context),
    )
    for t in 0..<predictions.length() {
      for i in 0..<self.state_stats.mean.length() {
        let delta = tape.scale(
          tape.sub(predictions[t][i], tape.scalar(w.target[t][i])),
          1 / self.state_stats.scale[i],
        )
        errors.push(tape.mul(delta, delta))
      }
    }
  }
  tape.mean(errors)
}

///|
pub fn Dynamics::update(
  self : Dynamics,
  optimizer : @numeric.Adam,
  windows : Array[Window],
) -> Double {
  let tape = @numeric.Tape::new()
  let parameters = self.network.bind(tape)
  let loss = self.loss(tape, parameters, windows)
  guard @numeric.finite(loss.value) else { abort("nonfinite dynamics loss") }
  tape.backward(loss)
  ignore(optimizer.step(self.network.parameters, tape, parameters))
  loss.value
}

///|
pub struct DynamicsMetrics {
  windows : Int32
  mse : Double
  persistence_mse : Double
  per_step_mse : Array[Double]
  persistence_per_step_mse : Array[Double]
  late_windows : Int32
  late_mse : Double?
  late_persistence_mse : Double?
} derive(Debug)

///|
pub fn Dynamics::evaluate(
  self : Dynamics,
  windows : Array[Window],
) -> DynamicsMetrics {
  guard windows.length() > 0 else { abort("empty evaluation") }
  let horizon = windows[0].action.length()
  guard horizon > 0 else { abort("empty horizon") }
  let errors = Array::make(horizon, 0.0)
  let persistence = Array::make(horizon, 0.0)
  let mut late_errors = 0.0
  let mut late_persistence = 0.0
  let mut late_windows = 0
  for w in windows {
    guard w.action.length() == horizon else { abort("inconsistent horizon") }
    let mut state = w.state[0]
    if w.start_time_s >= 2 {
      late_windows += 1
    }
    for t in 0..<horizon {
      state = self.predict(state, w.action[t], w.context)
      for i in 0..<state.length() {
        let delta = (state[i] - w.target[t][i]) / self.state_stats.scale[i]
        let baseline = (w.state[0][i] - w.target[t][i]) /
          self.state_stats.scale[i]
        let error = delta * delta / state.length().to_double()
        let base_error = baseline * baseline / state.length().to_double()
        errors[t] += error
        persistence[t] += base_error
        if w.start_time_s >= 2 {
          late_errors += error
          late_persistence += base_error
        }
      }
    }
  }
  let mut mse = 0.0
  let mut persistence_mse = 0.0
  for t in 0..<horizon {
    errors[t] /= windows.length().to_double()
    persistence[t] /= windows.length().to_double()
    mse += errors[t] / horizon.to_double()
    persistence_mse += persistence[t] / horizon.to_double()
  }
  {
    windows: windows.length(),
    mse,
    persistence_mse,
    per_step_mse: errors,
    persistence_per_step_mse: persistence,
    late_windows,
    late_mse: if late_windows > 0 {
      Some(late_errors / (late_windows * horizon).to_double())
    } else {
      None
    },
    late_persistence_mse: if late_windows > 0 {
      Some(late_persistence / (late_windows * horizon).to_double())
    } else {
      None
    },
  }
}

///|
pub fn validation_score(
  metrics : DynamicsMetrics,
  late_weight : Double,
) -> Double {
  guard late_weight >= 0 && late_weight <= 1 else {
    abort("late weight outside [0,1]")
  }
  if late_weight == 0 {
    metrics.mse
  } else {
    let late = match metrics.late_mse {
      Some(v) => v
      None => abort("late-weighted selection needs late windows")
    }
    (1 - late_weight) * metrics.mse + late_weight * late
  }
}
