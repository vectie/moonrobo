///|
test "missing failure-tail evidence remains null" {
  let summaries = @learning_probes.summarize([], 32, "after-two-seconds", 2)
  for row in summaries {
    assert_eq(row.snapshots, 0)
    assert_eq(row.mean_normalized_mse, None)
    assert_eq(row.sign_agreement, None)
    assert_eq(row.ascent_improves_fraction_by_epsilon, [None, None])
  }
}

///|
test "zero gradient excluded from ascent denominator" {
  let records : Array[@learning_probes.Record] = []
  for t in [1.0, 2.0] {
    let ascent : Array[@learning_probes.Ascent] = if t == 1 {
      []
    } else {
      [{ plus_return_change: -0.02, }, { plus_return_change: 0.01, }]
    }
    records.push({
      horizon: 32,
      start_time_s: t,
      physical_return: 1.0,
      models: ["initial", "corrected"].map(model => {
        model,
        normalized_mse: 0.5,
        predicted_return: 2.0,
        ascent_physics: ascent,
        translation_checks: [],
      }),
      directions: [
        {
          initial_derivative: 1.0,
          corrected_derivative: -1.0,
          physics_derivatives: [1.0, -1.0],
        },
      ],
    })
  }
  let result = @learning_probes.summarize(records, 32, "all", 2)[0]
  assert_eq(result.snapshots, 2)
  assert_eq(result.ascent_snapshots, 1)
  assert_eq(result.ascent_improves_fraction_by_epsilon, [Some(0.0), Some(1.0)])
  assert_eq(result.fd_sign_agreement_between_scales, Some(0.0))
  assert_eq(
    @learning_probes.summarize(records, 32, "after-two-seconds", 2)[0].snapshots,
    1,
  )
}

///|
test "physics hard and soft returns include complete reward and zero tail" {
  let first = Array::make(14, 0.0)
  first[2] = 0.8
  first[3] = 1
  let last = first.copy()
  last[2] = 0.3
  let (r0, c0) = @learning_probes.step_reward(
    first,
    [0.0],
    [0.0],
    [0.0],
    [7],
    0.8,
  )
  let (r1, c1) = @learning_probes.step_reward(
    last,
    [0.0],
    [0.0],
    [0.0],
    [7],
    0.8,
  )
  let (hard, soft) = @learning_probes.recorded_returns(
    [r0, r1],
    [c0, c1],
    [false, true],
    0.9,
  )
  let last_reward = 2.0 + @math.exp(-(0.5 / 0.15 * (0.5 / 0.15)))
  let first_continuation = 1.0 /
    (1.0 + @math.exp(-(0.8 - 0.35) / 0.02)) /
    (1.0 + @math.exp(-(1.0 - 0.5) / 0.05))
  assert_true((r1 - last_reward).abs() < 0.000000001)
  assert_true((c0 - first_continuation).abs() < 0.000000001)
  assert_eq(r0, 3.0)
  assert_true((hard[0] - (3 + 0.9 * last_reward)).abs() < 0.000000001)
  assert_true((hard[1] - last_reward).abs() < 0.000000001)
  assert_true(
    (soft[0] - (3 + 0.9 * first_continuation * last_reward)).abs() < 0.000000001,
  )
  assert_true((soft[1] - last_reward).abs() < 0.000000001)
}

///|
test "fresh Adam ascent direction preserves source parameters" {
  let original = [0.01]
  let direction = @learning_probes.adam_direction(
    original,
    p => (p[0] * 20, [20.0]),
    0.001,
    4,
  )
  assert_true(direction.gradient_norm > 0)
  assert_true(direction.delta[0] > 0)
  for multiplier in [-1.0, 0.0, 1.0] {
    let candidate = @learning_probes.scaled_actor(
      original,
      direction.delta,
      multiplier,
    )
    if multiplier == 0 {
      assert_eq(candidate, original)
    } else {
      assert_true((candidate[0] - original[0]) * multiplier > 0)
    }
  }
  assert_eq(original, [0.01])
  assert_eq(@learning_probes.cosine([0.0], [1.0]), None)
}
