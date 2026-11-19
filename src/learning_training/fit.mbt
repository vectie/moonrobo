///|
pub(all) struct DynamicsFitConfig {
  updates : Int32
  batch_size : Int32
  evaluate_every : Int32
  learning_rate : Double
  late_window_fraction : Double
  late_validation_weight : Double
} derive(Debug)

///|
pub struct FitRow {
  update : Int32
  training_loss : Double?
  validation : DynamicsMetrics
  selection_score : Double
} derive(Debug)

///|
pub struct DynamicsFitResult {
  selected_update : Int32
  best_parameters : Array[Double]
  latest_parameters : Array[Double]
  history : Array[FitRow]
  validation : DynamicsMetrics
  test_metrics : DynamicsMetrics
} derive(Debug)

///|
/// Residual dynamics training with time-stratified replacement sampling and validation-only selection.
pub fn fit_dynamics(
  model : Dynamics,
  train : Array[Window],
  validation : Array[Window],
  test_data : Array[Window],
  config : DynamicsFitConfig,
  rng : @numeric.Rng,
) -> DynamicsFitResult {
  guard config.updates > 0 && config.batch_size > 0 && config.evaluate_every > 0 else {
    abort("invalid dynamics fit configuration")
  }
  let (early, late, late_count) = sampling_pools(
    train.map(w => w.start_time_s),
    config.batch_size,
    config.late_window_fraction,
  )
  let optimizer = @numeric.Adam::new(
    model.network.parameters.length(),
    config.learning_rate,
  )
  let mut best_score = 1.0 / 0.0
  let mut selected = 0
  let mut best_parameters = model.network.parameters.copy()
  let history = []
  for update in 1..<=config.updates {
    let batch = Array::makei(config.batch_size, i => {
      let id = if config.late_window_fraction == 0 {
        rng.index(train.length())
      } else if i < config.batch_size - late_count {
        early[rng.index(early.length())]
      } else {
        late[rng.index(late.length())]
      }
      train[id]
    })
    let loss = model.update(optimizer, batch)
    if update % config.evaluate_every == 0 || update == config.updates {
      let metrics = model.evaluate(validation)
      let score = validation_score(metrics, config.late_validation_weight)
      history.push({
        update,
        training_loss: Some(loss),
        validation: metrics,
        selection_score: score,
      })
      if score < best_score {
        best_score = score
        selected = update
        best_parameters = model.network.parameters.copy()
      }
    }
  }
  let latest = model.network.parameters.copy()
  restore_parameters(model.network, best_parameters)
  {
    selected_update: selected,
    best_parameters,
    latest_parameters: latest,
    history,
    validation: model.evaluate(validation),
    test_metrics: model.evaluate(test_data),
  }
}

///|
/// Dynamic refit retains incoming normalization, includes update zero in model selection.
pub fn refit_dynamics(
  model : Dynamics,
  original : Array[Window],
  added : Array[Window],
  validation : Array[Window],
  test_data : Array[Window],
  config : DynamicsFitConfig,
  rng : @numeric.Rng,
  mixed : Bool,
) -> DynamicsFitResult {
  guard original.length() > 0 &&
    (!mixed || added.length() > 0) &&
    config.evaluate_every > 0 &&
    config.batch_size > 0 else {
    abort("invalid refit data")
  }
  let optimizer = @numeric.Adam::new(
    model.network.parameters.length(),
    config.learning_rate,
  )
  let initial = model.evaluate(validation)
  let mut best_score = validation_score(initial, config.late_validation_weight)
  let mut best_parameters = model.network.parameters.copy()
  let mut selected = 0
  let history = [
    {
      update: 0,
      training_loss: None,
      validation: initial,
      selection_score: best_score,
    },
  ]
  for update in 1..<=config.updates {
    let batch = Array::makei(config.batch_size, i => {
      if mixed && i >= config.batch_size / 2 {
        added[rng.index(added.length())]
      } else {
        original[rng.index(original.length())]
      }
    })
    let loss = model.update(optimizer, batch)
    if update % config.evaluate_every == 0 {
      let metrics = model.evaluate(validation)
      let score = validation_score(metrics, config.late_validation_weight)
      history.push({
        update,
        training_loss: Some(loss),
        validation: metrics,
        selection_score: score,
      })
      if score < best_score {
        best_score = score
        best_parameters = model.network.parameters.copy()
        selected = update
      }
    }
  }
  let latest = model.network.parameters.copy()
  restore_parameters(model.network, best_parameters)
  {
    selected_update: selected,
    best_parameters,
    latest_parameters: latest,
    history,
    validation: model.evaluate(validation),
    test_metrics: model.evaluate(test_data),
  }
}

///|
pub struct GradientProbe {
  passed : Bool
  action_gradient_norm : Double
  state_gradient_norm : Double
  analytic_directional : Double
  finite_difference_directional : Double
} derive(Debug)

///|
/// Frozen weights retain input gradients across the full unrolled horizon.
pub fn Dynamics::gradient_probe(
  self : Dynamics,
  window : Window,
) -> GradientProbe {
  let tape = @numeric.Tape::new()
  let state = tape.vector(window.state[0])
  let actions = window.action.map(row => tape.vector(row))
  let predicted = self.imagine(
    tape,
    self.network.bind(tape),
    state,
    actions,
    tape.vector(window.context),
  )
  let ns = state.length()
  let weights = Array::makei(ns, i => {
    if ns == 1 {
      0.1
    } else {
      0.1 + 0.9 * i.to_double() / (ns - 1).to_double()
    }
  })
  let mut scalar = tape.scalar(0)
  for i in 0..<ns {
    scalar = tape.add(
      scalar,
      tape.scale(predicted[predicted.length() - 1][i], weights[i]),
    )
  }
  tape.backward(scalar)
  let total = actions.length() * actions[0].length()
  let direction = Array::makei(actions.length(), t => {
    Array::makei(actions[t].length(), j => {
      if total == 1 {
        -1.0
      } else {
        -1.0 +
        2.0 *
        (t * actions[t].length() + j).to_double() /
        (total - 1).to_double()
      }
    })
  })
  let mut analytic = 0.0
  let mut action_norm2 = 0.0
  let mut state_norm2 = 0.0
  for t in 0..<actions.length() {
    for j in 0..<actions[t].length() {
      let g = tape.gradient(actions[t][j])
      analytic += g * direction[t][j]
      action_norm2 += g * g
    }
  }
  for v in state {
    let g = tape.gradient(v)
    state_norm2 += g * g
  }
  let endpoint = fn(sign : Double) -> Double {
    let mut current = window.state[0]
    for t in 0..<window.action.length() {
      current = self.predict(
        current,
        Array::makei(window.action[t].length(), j => {
          window.action[t][j] + sign * 0.000001 * direction[t][j]
        }),
        window.context,
      )
    }
    let mut value = 0.0
    for i in 0..<ns {
      value += current[i] * weights[i]
    }
    value
  }
  let numeric = (endpoint(1) - endpoint(-1)) / 0.000002
  {
    passed: @numeric.finite(action_norm2) &&
    @numeric.finite(state_norm2) &&
    action_norm2 > 0 &&
    state_norm2 > 0 &&
    (analytic - numeric).abs() < 0.00001 + 0.001 * numeric.abs(),
    action_gradient_norm: action_norm2.sqrt(),
    state_gradient_norm: state_norm2.sqrt(),
    analytic_directional: analytic,
    finite_difference_directional: numeric,
  }
}
