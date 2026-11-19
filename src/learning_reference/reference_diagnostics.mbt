///|
pub fn window_starts(length : Int32, horizon : Int32) -> Array[Int32] {
  guard horizon > 0 else { abort("positive horizon required") }
  if length < horizon {
    return []
  }
  let starts : Array[Int32] = []
  for i = 0; i <= length - horizon; i = i + (horizon / 2).max(1) {
    starts.push(i)
  }
  if starts[starts.length() - 1] != length - horizon {
    starts.push(length - horizon)
  }
  starts
}

///|
pub(all) struct DiscountedReturns {
  prefix_return : Double
  full_return : Double
  prefix_observed_steps : Int32
  full_observed_steps : Int32
} derive(Debug, ToJson)

///|
pub fn discounted_returns(
  rewards : Array[Double],
  gamma : Double,
  horizon : Int32,
) -> DiscountedReturns {
  let mut prefix = 0.0
  let mut full = 0.0
  let mut weight = 1.0
  for i, reward in rewards {
    full += weight * reward
    if i < horizon {
      prefix += weight * reward
    }
    weight *= gamma
  }
  {
    prefix_return: prefix,
    full_return: full,
    prefix_observed_steps: horizon.min(rewards.length()),
    full_observed_steps: rewards.length(),
  }
}

///|
pub fn first_action_tape(
  actions : Array[Array[Double]],
  direction : Array[Double],
  amplitude : Double,
  lower : Array[Double],
  upper : Array[Double],
) -> Array[Array[Double]] {
  guard !actions.is_empty() && actions[0].length() == direction.length() else {
    abort("action tape shape")
  }
  let result = actions.map(row => row.copy())
  for i, d in direction {
    result[0][i] = clamp(result[0][i] + amplitude * d, lower[i], upper[i])
  }
  result
}

///|
pub(all) struct FeasibleDirection {
  direction : Array[Array[Double]]
  gradient_rms : Double
  interior_coordinates : Int32
} derive(Debug)

///|
/// One-row tapes give reference_action_response.feasible_direction; full tapes
/// intersect all baseline interiors as in feedback_response.control_direction.
pub fn control_direction(
  gradient : Array[Array[Double]],
  baseline_controls : Array[Array[Array[Double]]],
  lower : Array[Double],
  upper : Array[Double],
  amplitude : Double,
) -> FeasibleDirection {
  guard !gradient.is_empty() && !gradient[0].is_empty() else {
    abort("gradient shape")
  }
  let count = gradient.length() * gradient[0].length()
  let margin = count.to_double().sqrt() * amplitude
  let mut interior = 0
  let feasible = gradient.mapi((i, row) => {
    row.mapi((j, x) => {
      let allowed = baseline_controls
        .iter()
        .all(tape => {
          tape[i][j] > lower[j] + margin && tape[i][j] < upper[j] - margin
        })
      if allowed {
        interior += 1
        x
      } else {
        0.0
      }
    })
  })
  let rms = (feasible.fold(init=0.0, (sum, row) => sum + dot(row, row)) /
  count.to_double()).sqrt()
  guard finite(rms) && rms > 1.0e-12 else {
    abort("nonfinite or zero interior action-response gradient")
  }
  {
    direction: feasible.map(row => row.map(x => x / rms)),
    gradient_rms: rms,
    interior_coordinates: interior,
  }
}

///|
/// Same iterative fixed-input raw-logit calibration as gradient_route.calibrate.
/// evaluate returns raw means for one parameter vector; no policy is mutated.
pub fn calibrate_direction(
  base : Array[Double],
  direction : Array[Double],
  target : Double,
  sign : Double,
  response : Double,
  evaluate : (Array[Double]) -> Array[Double],
) -> (Double, Double, Int32) {
  guard base.length() == direction.length() && target > 0.0 && response > 0.0 else {
    abort("direction calibration shape")
  }
  let initial = evaluate(base)
  let mut amount = sign * target / response
  for iteration in 0..<8 {
    let output = evaluate(base.mapi((i, x) => x + amount * direction[i]))
    let error = output.mapi((i, x) => x - initial[i])
    let achieved = (dot(error, error) / error.length().to_double()).sqrt()
    guard finite(achieved) && achieved > 0.0 else {
      abort("invalid parameter-direction calibration")
    }
    if (achieved - target).abs() <= 0.001 * target {
      return (amount, achieved, iteration + 1)
    }
    amount *= target / achieved
  }
  abort("fixed-input parameter step did not reach prescribed RMS")
}

///|
/// Integration residuals are approximations to simulator substeps, not gates.
pub fn trapezoid_residual(
  state : Array[Double],
  next_state : Array[Double],
  root~ : Bool = false,
  dt~ : Double = 0.02,
) -> Array[Double] {
  let (q, v, n) = if root { (0, 36, 3) } else { (7, 42, 29) }
  Array::makei(n, i => {
    next_state[q + i] -
    state[q + i] -
    0.5 * dt * (state[v + i] + next_state[v + i])
  })
}

///|
pub fn central_secant(
  plus : Double,
  minus : Double,
  amplitude : Double,
) -> Double {
  guard amplitude > 0.0 else {
    abort("positive finite-difference amplitude required")
  }
  (plus - minus) / (2.0 * amplitude)
}

///|
pub fn autodiff_consistent(
  analytic : Double,
  numeric : Double,
  absolute_tolerance~ : Double = 1.0e-5,
  relative_tolerance~ : Double = 1.0e-3,
) -> Bool {
  finite(analytic) &&
  finite(numeric) &&
  (analytic - numeric).abs() <=
  absolute_tolerance + relative_tolerance * numeric.abs()
}

///|
fn finite(x : Double) -> Bool {
  !x.is_nan() && !x.is_inf()
}
