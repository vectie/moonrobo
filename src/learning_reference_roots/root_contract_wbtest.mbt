///|
fn contract_root_model(integrated : Bool) -> @training.Dynamics {
  let norm = n => {
    (
      { mean: Array::make(n, 0.0), scale: Array::make(n, 1.0), } :
      @numeric.Normalization)
  }
  @training.Dynamics::new(
    norm(71),
    norm(29),
    norm(2),
    8,
    @numeric.Rng::new(810U),
    translation_invariant=true,
    root_integration_dt=if integrated { Some(0.02) } else { None },
  )
}

///|
test "root integration paired models share initialization and exact trapezoid position edge" {
  let free = contract_root_model(false)
  let integrated = contract_root_model(true)
  assert_eq(free.network.parameters, integrated.network.parameters)
  let initial = Array::make(71, 0.0)
  initial[0] = 3.0
  initial[1] = -2.0
  initial[2] = 0.8
  initial[3] = 1.0
  initial[36] = 0.4
  initial[37] = -0.2
  initial[38] = 0.1
  let actions = Array::make(29, 0.0)
  let prediction = integrated.predict(initial, actions, [1.0, 1.0])
  let residual = @ref.trapezoid_residual(
    initial,
    prediction,
    root=true,
    dt=0.02,
  )
  for x in residual {
    assert_true(x.abs() < 1.0e-14)
  }
  for i in 0..<3 {
    assert_true(
      (prediction[i] - initial[i] - 0.02 * initial[36 + i]).abs() < 1.0e-14,
    )
  }
  assert_eq(free.predict(initial, actions, [1.0, 1.0])[0], initial[0])
  let t = @numeric.Tape::new()
  let state = t.vector(initial)
  let output = integrated.forward(
    t,
    integrated.network.bind(t),
    state,
    t.vector(actions),
    t.vector([1.0, 1.0]),
  )
  t.backward(output[0])
  assert_eq(t.gradient(state[0]), 1.0)
  assert_true((t.gradient(state[36]) - 0.02).abs() < 1.0e-14)
  assert_true(state.all(x => @numeric.finite(t.gradient(x))))
}

///|
test "root integration dynamics preserve horizontal translation without altering velocities" {
  let model = contract_root_model(true)
  let first = Array::make(71, 0.0)
  first[2] = 0.8
  first[3] = 1.0
  first[36] = 0.5
  let shifted = first.copy()
  shifted[0] += 7.0
  shifted[1] -= 4.0
  let a = model.predict(first, Array::make(29, 0.0), [1.0, 1.0])
  let b = model.predict(shifted, Array::make(29, 0.0), [1.0, 1.0])
  assert_true((b[0] - a[0] - 7.0).abs() < 1.0e-14)
  assert_true((b[1] - a[1] + 4.0).abs() < 1.0e-14)
  assert_eq(a[2:].to_owned(), b[2:].to_owned())
}

///|
test "root decomposition prefix full return and first points respect episode boundaries" {
  let point = (step : Int32) => {
    (
      {
        state: [step.to_double()],
        history: [],
        actual_features: [],
        reference_features: [],
        context: [],
        clip: 0,
        step,
        origin: 0,
      } : @ref.LearningPoint)
  }
  let batch : @ref.CollectedBatch = {
    points: [point(0), point(1), point(2), point(3), point(4)],
    actions: [],
    next_states: [],
    latent: [],
    old_mean: [],
    reward: [1.0, 2.0, 4.0, 8.0, 16.0],
    done: [false, true, false, false, true],
    returns: [],
    episode_lengths: [2, 3],
  }
  assert_eq(first_points(batch).map(p => p.step), [0, 2])
  let result = returns_by_episode(batch, [7, 9], 0.5)
  assert_eq(integer(result[0], "clip_index"), 7)
  assert_eq(number(result[0], "full_return"), 2.0)
  assert_eq(number(result[1], "prefix_return"), 12.0)
  assert_eq(number(result[1], "full_return"), 12.0)
  let analytic = 3.0
  let numeric = @ref.central_secant(5.0 + 3.0 * 0.01, 5.0 - 3.0 * 0.01, 0.01)
  assert_true(@ref.autodiff_consistent(analytic, numeric))
  assert_true(
    (rms_difference([[1.0, 3.0]], [[0.0, 2.0]]) - 1.0).abs() < 1.0e-14,
  )
}

///|
test "root diagnostics prediction metrics keep root position and velocity component units" {
  let model = contract_root_model(true)
  let state = Array::make(71, 0.0)
  state[2] = 0.8
  state[3] = 1.0
  state[36] = 0.5
  let point : @ref.LearningPoint = {
    state,
    history: [],
    actual_features: [],
    reference_features: [],
    context: [1.0, 1.0],
    clip: 0,
    step: 0,
    origin: 0,
  }
  let batch : @ref.CollectedBatch = {
    points: Array::make(32, point),
    actions: Array::makei(32, _ => Array::make(29, 0.0)),
    next_states: Array::make(32, state),
    latent: [],
    old_mean: [],
    reward: [],
    done: [],
    returns: [],
    episode_lengths: [32],
  }
  let metrics = prediction_metrics(model, batch)
  assert_eq(integer(metrics[0], "windows"), 7)
  assert_eq(integer(metrics[1], "windows"), 1)
  for row in metrics {
    assert_eq(number(row, "root_linear_velocity_component_rmse_m_per_s"), 0.0)
    let h = integer(row, "horizon")
    let expected = (Array::makei(h, i => {
      let d = (i + 1).to_double() * 0.01
      d * d
    }).fold(init=0.0, (a, b) => a + b) /
    (3 * h).to_double()).sqrt()
    assert_true(
      (number(row, "root_position_component_rmse_m") - expected).abs() < 1.0e-12,
    )
  }
}
