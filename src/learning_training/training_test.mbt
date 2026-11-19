///|
fn close_array(actual : Array[Double], expected : Array[Double]) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    assert_true((actual[i] - expected[i]).abs() < 0.0000000001)
  }
}

///|
test "physical returns preserve truncation tail and stop at true terminal" {
  close_array(
    @training.physical_return_targets(
      [1.0, 2.0],
      [0.5, 0.25],
      [false, false],
      8,
      0.9,
    ),
    [2.71, 3.8],
  )
  close_array(
    @training.physical_return_targets(
      [1.0, 2.0],
      [0.5, 0.25],
      [false, true],
      8,
      0.9,
    ),
    [1.9, 2.0],
  )
}

///|
test "imagined GAE terminal and time-limit targets" {
  close_array(
    @training.gae_targets([5.0, 5.0, 5.0], [1.0, 2.0], [1.0, 0.0], 0.9, 1),
    [2.8, 2.0],
  )
  close_array(
    @training.gae_targets([5.0, 5.0, 5.0], [1.0, 2.0], [1.0, 1.0], 0.9, 1),
    [6.85, 6.5],
  )
}

///|
test "physical GAE does not leak across episode resets" {
  let (advantage, target) = @training.physical_gae(
    [1.0, 2.0],
    [3.0, 4.0],
    [4.0, 500.0],
    [false, true],
    [false, false],
    0.9,
    1,
  )
  close_array(advantage, [-0.2, -2.0])
  close_array(target, [2.8, 2.0])
  let (_, timelimit) = @training.physical_gae(
    [1.0, 100.0],
    [0.0, 0.0],
    [5.0, 0.0],
    [false, true],
    [true, false],
    0.9,
    1,
  )
  close_array(timelimit, [5.5, 100.0])
}

///|
test "late sampling time boundary and Python round ties" {
  let (early, late, count) = @training.sampling_pools(
    [0.0, 1.98, 2.0, 4.0],
    64,
    0.5,
  )
  assert_eq(early, [0, 1])
  assert_eq(late, [2, 3])
  assert_eq(count, 32)
  let (_, _, even) = @training.sampling_pools([0.0, 2.0], 5, 0.5)
  assert_eq(even, 2)
}

///|
test "root translation trapezoid and native checkpoint round trip" {
  let state_stats : @numeric.Normalization = {
    mean: Array::make(71, 0.0),
    scale: Array::make(71, 1.0),
  }
  let action_stats : @numeric.Normalization = { mean: [0.0], scale: [1.0], }
  let context_stats : @numeric.Normalization = {
    mean: [0.0, 0.0],
    scale: [1.0, 1.0],
  }
  let model = @training.Dynamics::new(
    state_stats,
    action_stats,
    context_stats,
    4,
    @numeric.Rng::new(82U),
    root_integration_dt=Some(0.02),
  )
  let state = Array::make(71, 0.0)
  state[3] = 1
  state[36] = 0.1
  state[37] = -0.2
  state[38] = 0.05
  let next = model.predict(state, [0.0], [1.0, 1.0])
  for i in 0..<3 {
    assert_true(
      (next[i] - state[i] - 0.01 * (state[36 + i] + next[36 + i])).abs() <
      0.000000000001,
    )
  }
  let shifted = state.copy()
  shifted[0] += 2
  shifted[1] -= 3
  let translated = model.predict(shifted, [0.0], [1.0, 1.0])
  assert_true((translated[0] - next[0] - 2).abs() < 0.000000000001)
  assert_true((translated[1] - next[1] + 3).abs() < 0.000000000001)
  let restored = @training.dynamics_from_checkpoint(model.checkpoint({}))
  close_array(restored.predict(state, [0.0], [1.0, 1.0]), next)
}

///|
test "unrolled dynamics action gradient agrees with central differences" {
  let state_stats : @numeric.Normalization = {
    mean: Array::make(14, 0.0),
    scale: Array::make(14, 1.0),
  }
  let action_stats : @numeric.Normalization = { mean: [0.0], scale: [1.0], }
  let context_stats : @numeric.Normalization = {
    mean: [0.0, 0.0],
    scale: [1.0, 1.0],
  }
  let rng = @numeric.Rng::new(23U)
  let model = @training.Dynamics::new(
    state_stats,
    action_stats,
    context_stats,
    4,
    rng,
    translation_invariant=true,
  )
  // Nonzero output coefficients exercise the entire recurrent graph.
  for i in 0..<model.network.parameters.length() {
    model.network.parameters[i] = 0.05 * (2 * rng.uniform() - 1)
  }
  let state = Array::make(14, 0.0)
  state[2] = 0.8
  state[3] = 1
  let actions = Array::makei(8, _ => [0.0])
  let window : @training.Window = {
    state: Array::makei(8, _ => state.copy()),
    action: actions,
    target: Array::makei(8, _ => state.copy()),
    context: [1.0, 1.0],
    start_time_s: 0,
  }
  let probe = model.gradient_probe(window)
  assert_true(probe.passed)
  assert_true(probe.action_gradient_norm > 0)
}

///|
test "online windows exclude gaps and terminals before window end" {
  let make_episode = fn(
    id : String,
    start : Double,
    times : Array[Double],
    early_done : Bool,
  ) -> @training.Episode {
    let steps : Array[@training.Transition] = Array::makei(times.length(), i => {
      let state = Array::make(14, 0.0)
      state[2] = 0.8
      state[3] = 1
      state[7] = start + i.to_double()
      {
        time_s: times[i],
        state,
        observation: [],
        applied_action: [0.1],
        next_state: state,
        goal: [],
        terminated: i == times.length() - 1,
        truncated: early_done && i == 1,
      }
    })
    { id, split: "train", context: [1.0, 1.0], steps, }
  }
  let episodes = [
    make_episode("a", 0, [0.0, 0.02, 0.04, 0.06], false),
    make_episode("b", 100, [0.0, 0.02, 0.10, 0.12], false),
    make_episode("c", 200, [0.0, 0.02, 0.04, 0.06], true),
  ]
  let windows = @training.episode_windows(episodes, 2, 0.02)
  assert_eq(windows.map(w => w.state[0][7]), [
    0.0, 1.0, 2.0, 100.0, 102.0, 200.0, 202.0,
  ])
}
