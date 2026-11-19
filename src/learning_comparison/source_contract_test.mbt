///|
/// test_dynamics.py: a shared scale must affect both learned and persistence error.
test "common prediction scale and late subset are explicit" {
  let stats : @numeric.Normalization = {
    mean: Array::make(7, 0.0),
    scale: Array::make(7, 1.0),
  }
  let one : @numeric.Normalization = { mean: [0.0], scale: [1.0], }
  let model = @training.Dynamics::new(stats, one, one, 4, @numeric.Rng::new(3U))
  let state = [0.0, 0.0, 0.8, 1.0, 0.0, 0.0, 0.0]
  let windows : Array[@training.Window] = Array::makei(2, i => {
    let target = state.copy()
    target[0] = (i + 1).to_double()
    {
      state: [state, state],
      action: [[0.0], [0.0]],
      target: [target, target],
      context: [0.0],
      start_time_s: 2 * i.to_double(),
    }
  })
  let m = @learning_comparison.common_metrics(
    model,
    windows,
    Array::make(7, 2.0),
  )
  let expected : Json = {
    "windows": 2,
    "normalized_state_mse": Json(2.5 / 28.0),
    "persistence_mse": Json(2.5 / 28.0),
    "after_two_seconds": {
      "windows": 1,
      "normalized_state_mse": Json(4.0 / 28.0),
    },
  }
  assert_eq(m, expected)
  let scaled = @learning_comparison.common_metrics(
    model,
    windows,
    Array::make(7, 4.0),
  )
  let expected_scaled : Json = {
    "windows": 2,
    "normalized_state_mse": Json(2.5 / 112.0),
    "persistence_mse": Json(2.5 / 112.0),
    "after_two_seconds": {
      "windows": 1,
      "normalized_state_mse": Json(4.0 / 112.0),
    },
  }
  assert_eq(scaled, expected_scaled)
}
