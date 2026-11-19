///|
/// Parameters are separate from immutable normalization buffers, as named_parameters.
pub fn scaled_actor(
  parameters : Array[Double],
  delta : Array[Double],
  multiplier : Double,
) -> Array[Double] raise ProbeError {
  require_width(parameters, delta)
  Array::makei(parameters.length(), i => parameters[i] + delta[i] * multiplier)
}

///|
pub(all) struct AdamDirection {
  delta : Array[Double]
  objective_before : Double
  gradient_norm : Double
} derive(Debug, ToJson)

///|
/// A fresh Adam optimizer's first ascent update, beta=(.9,.999), epsilon=1e-8.
/// The callback must return the actual objective and its analytic/autodiff gradient.
/// Gradient clipping occurs after the loss is divided by horizon, matching PyTorch.
pub fn adam_direction(
  parameters : Array[Double],
  objective : (Array[Double]) -> (Double, Array[Double]),
  learning_rate : Double,
  horizon : Int32,
) -> AdamDirection raise ProbeError {
  if horizon <= 0 || learning_rate <= 0 {
    raise Invalid("positive horizon and learning rate required")
  }
  let (before, gradient) = objective(parameters.copy())
  require_width(parameters, gradient)
  let loss_gradient = gradient.map(g => -g / horizon.to_double())
  let mut sum = 0.0
  for g in loss_gradient {
    if g.is_nan() || g.is_inf() {
      raise Invalid("nonfinite actor gradient")
    }
    sum += g * g
  }
  let norm = sum.sqrt()
  let clip = if norm + 0.000001 > 1 { 1.0 / (norm + 0.000001) } else { 1.0 }
  let delta = loss_gradient.map(g => {
    let clipped = g * clip
    // Bias correction cancels first moments exactly in real arithmetic.
    -learning_rate * clipped / (clipped.abs() + 0.00000001)
  })
  { delta, objective_before: before, gradient_norm: norm, }
}

///|
pub fn predicted_changes(
  parameters : Array[Double],
  candidate : Array[Double],
  objective : (Array[Double], Bool) -> Double,
) -> (Double, Double) {
  (
    objective(candidate, false) - objective(parameters, false),
    objective(candidate, true) - objective(parameters, true),
  )
}

///|
/// Common scale metrics for compare_dynamics; scale is always the initial model's.
pub(all) struct CommonMetrics {
  windows : Int32
  normalized_state_mse : Double
  persistence_mse : Double
  after_two_seconds_windows : Int32
  after_two_seconds_normalized_state_mse : Double?
} derive(Debug, ToJson)

///|
pub fn common_metrics(
  predictions : Array[Array[Array[Double]]],
  targets : Array[Array[Array[Double]]],
  initials : Array[Array[Double]],
  start_time_s : Array[Double],
  scale : Array[Double],
) -> CommonMetrics raise ProbeError {
  if predictions.is_empty() ||
    predictions.length() != targets.length() ||
    initials.length() != targets.length() ||
    start_time_s.length() != targets.length() {
    raise Invalid("common metric window lengths differ")
  }
  let mut total = 0.0
  let mut persistence = 0.0
  let mut count = 0
  let mut late = 0.0
  let mut late_count = 0
  let mut late_windows = 0
  for i, trajectory in predictions {
    if trajectory.is_empty() || trajectory.length() != targets[i].length() {
      raise Invalid("common metric horizons differ")
    }
    if start_time_s[i] >= 2 {
      late_windows += 1
    }
    for t, prediction in trajectory {
      let error = normalized_mse(prediction, targets[i][t], scale)
      total += error
      persistence += normalized_mse(initials[i], targets[i][t], scale)
      count += 1
      if start_time_s[i] >= 2 {
        late += error
        late_count += 1
      }
    }
  }
  {
    windows: predictions.length(),
    normalized_state_mse: total / count.to_double(),
    persistence_mse: persistence / count.to_double(),
    after_two_seconds_windows: late_windows,
    after_two_seconds_normalized_state_mse: if late_count > 0 {
      Some(late / late_count.to_double())
    } else {
      None
    },
  }
}

///|
/// Teacher first-update verification preserves selected_update=1 semantics.
pub fn verify_teacher_step(
  initial : Array[Double],
  delta : Array[Double],
  selected : Array[Double],
  tolerance~ : Double = 0.0000001,
) -> (Double, Bool) raise ProbeError {
  let predicted = scaled_actor(initial, delta, 1)
  require_width(predicted, selected)
  let mut maximum = 0.0
  let mut exact = true
  for i, x in predicted {
    let d = (x - selected[i]).abs()
    if d > maximum {
      maximum = d
    }
    if x != selected[i] {
      exact = false
    }
  }
  if maximum > tolerance {
    raise Invalid(
      "teacher-only first update differs from diagnosed parameter direction",
    )
  }
  (maximum, exact)
}

///|
/// Replay distribution indices are injected from a seeded generator so cross-runtime
/// checks can reuse PyTorch draws, rather than silently substituting another RNG.
pub fn[T] sampled_batches(
  teacher : Array[T],
  current : Array[T],
  old : Array[Int32],
  new : Array[Int32],
  extra_old : Array[Int32],
  extra_new : Array[Int32],
) -> (Array[T], Array[T], Array[T]) raise ProbeError {
  if old.length() != extra_new.length() || new.length() != extra_old.length() {
    raise Invalid("replay half-batch widths differ")
  }
  if old.any(i => i < 0 || i >= teacher.length()) ||
    extra_old.any(i => i < 0 || i >= teacher.length()) ||
    new.any(i => i < 0 || i >= current.length()) ||
    extra_new.any(i => i < 0 || i >= current.length()) {
    raise Invalid("replay index out of bounds")
  }
  let a = old.map(i => teacher[i])
  a.append(extra_old.map(i => teacher[i]))
  let b = new.map(i => current[i])
  b.append(extra_new.map(i => current[i]))
  let mixed = old.map(i => teacher[i])
  mixed.append(new.map(i => current[i]))
  (a, b, mixed)
}
