///|
test "zero residual model agrees with persistence on the shared initial scale" {
  let stats : @numeric.Normalization = {
    mean: Array::make(7, 0.0),
    scale: Array::make(7, 1.0),
  }
  let one : @numeric.Normalization = { mean: [0.0], scale: [1.0], }
  let model = @training.Dynamics::new(stats, one, one, 4, @numeric.Rng::new(3U))
  let initial = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0]
  let windows : Array[@training.Window] = [
    {
      state: [initial],
      action: [[0.0]],
      target: [[1.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0]],
      context: [0.0],
      start_time_s: 0.0,
    },
    {
      state: [initial],
      action: [[0.0]],
      target: [[2.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0]],
      context: [0.0],
      start_time_s: 2.0,
    },
  ]
  let metrics = @learning_comparison.common_metrics(model, windows, stats.scale)
  let expected : Json = {
    "windows": 2,
    "normalized_state_mse": Json(5.0 / 14.0),
    "persistence_mse": Json(5.0 / 14.0),
    "after_two_seconds": {
      "windows": 1,
      "normalized_state_mse": Json(4.0 / 7.0),
    },
  }
  assert_eq(metrics, expected)
  assert_true(
    (try? @learning_comparison.common_metrics(model, windows, [0.0])) is Err(_),
  )
}
