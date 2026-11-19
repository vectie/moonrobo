///|
test "actor Tape gradients reach learned decoder and input feedback" {
  let rng = @numeric.Rng::new(13U)
  let actor = @learning_reference.ReferenceActor::new(
    68,
    29,
    Array::make(29, -1.0),
    Array::make(29, 1.0),
    Array::makei(4, _ => [16.0, 32.0, -0.02, 1.0, 0.25]),
    [4, 5, 10, 11],
    rng,
    history_length=1,
    future_length=0,
    width=4,
    latent_dim=2,
  )
  let current = Array::make(68, 0.0)
  current[60] = -1.0
  let obs = @learning_reference.reference_observation(current)
  let tape = @numeric.Tape::new()
  let parameters = tape.vector(actor.parameters())
  let history = [tape.vector(obs)]
  let features = tape.vector([0.001, 0.0, 0.0, 0.0, 0.0, 0.0])
  let latent = actor.latent_graph(
    tape,
    parameters,
    history,
    tape.vector(current),
    [],
    [],
  )
  let action = actor.action_graph(
    tape,
    latent,
    history,
    tape.vector(current),
    features,
    tape.vector(Array::make(6, 0.0)),
  )
  tape.backward(action[4])
  assert_true((tape.gradient(features[0]) - 16.0).abs() < 1.0e-10)
  assert_true(parameters.any(parameter => tape.gradient(parameter).abs() > 0.0))
  assert_true(
    parameters.all(parameter => @numeric.finite(tape.gradient(parameter))),
  )
  let epsilon = 1.0e-6
  let plus = actor.action_from_latent(
      Array::make(29, 0.0),
      [obs],
      current,
      [0.001 + epsilon, 0.0, 0.0, 0.0, 0.0, 0.0],
      Array::make(6, 0.0),
    )[4]
  let minus = actor.action_from_latent(
      Array::make(29, 0.0),
      [obs],
      current,
      [0.001 - epsilon, 0.0, 0.0, 0.0, 0.0, 0.0],
      Array::make(6, 0.0),
    )[4]
  assert_true(
    @learning_reference.autodiff_consistent(
      tape.gradient(features[0]),
      (plus - minus) / (2.0 * epsilon),
    ),
  )
}

///|
test "perfect tracked root has 0.06 reward and sign-invariant orientation" {
  let state = Array::make(71, 0.0)
  state[2] = 0.8
  state[3] = 1.0
  let id = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
  let result = @learning_reference.reference_reward(
    state,
    Array::make(29, 0.0),
    Array::make(29, 0.0),
    [[0.0, 0.0, 0.8]],
    [-1.0, 0.0, 0.0, 0.0],
    Array::make(29, 0.0),
    [[0.0, 0.0, 0.0]],
    [id],
    [[0.0, 0.0, 0.0]],
    [1.0],
    [0],
    [[0.0, 0.0, 0.0]],
  )
  assert_true((result.reward - 0.06).abs() < 1.0e-12)
  assert_false(result.fallen)
  assert_eq(result.error, [0.0, 0.0, 0.0])
}
