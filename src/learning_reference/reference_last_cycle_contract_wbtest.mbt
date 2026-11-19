///|
test "original last cycle window boundary examples and short prediction fields" {
  for
    (n, h, expected) in [
      (7, 8, []),
      (8, 8, [0]),
      (11, 8, [0, 3]),
      (16, 8, [0, 4, 8]),
    ] {
    assert_eq(window_starts(n, h), expected)
  }
  let s = Array::make(71, 0.0)
  s[3] = 1.0
  let metric = prediction_metrics(
      [s],
      [Array::make(29, 0.0)],
      [s],
      [1.0, 1.0],
      Array::make(71, 1.0),
      [2],
      (state, _, _) => state,
    )[0]
  assert_eq(metric.windows, 0)
  assert_eq(metric.last_window_offset, None)
  assert_eq(metric.normalized_state_mse, None)
  assert_eq(metric.persistence_mse, None)
  assert_eq(metric.root_position_component_rmse_m, None)
  assert_eq(metric.joint_rmse_rad, None)
  assert_eq(metric.root_velocity_component_rmse_m_per_s, None)
  assert_eq(metric.root_orientation_rmse_rad, None)
}

///|
test "original last cycle discounted returns keep all observed short prefix rewards" {
  let first = discounted_returns([1.0, 2.0, 4.0], 0.5, 2)
  assert_eq(first.prefix_return, 2.0)
  assert_eq(first.full_return, 3.0)
  assert_eq(first.prefix_observed_steps, 2)
  assert_eq(first.full_observed_steps, 3)
  let short = discounted_returns([1.0, -2.0], 0.5, 32)
  assert_eq(short.prefix_return, 0.0)
  assert_eq(short.full_return, 0.0)
  assert_eq(short.prefix_observed_steps, 2)
  assert_eq(short.full_observed_steps, 2)
}

///|
test "original learning actor origin sampler covers resets or complete trajectory exclusively" {
  assert_eq(actor_origin_candidates([3, 5]), [0, 3])
  assert_eq(actor_origin_candidates([3, 5], trajectory_states=true), [
    0, 1, 2, 3, 4, 5, 6, 7,
  ])
  for trajectory in [false, true] {
    let candidates = actor_origin_candidates(
      [3, 5],
      trajectory_states=trajectory,
    )
    let rng = @numeric.Rng::new(1024U)
    let seen : Map[Int32, Bool] = {}
    for _ in 0..<1024 {
      seen[candidates[rng.index(candidates.length())]] = true
    }
    assert_eq(seen.length(), candidates.length())
    for i in candidates {
      assert_true(seen.contains(i))
    }
  }
}
