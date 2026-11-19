///|
async test "original actor causal runner checkpoint and teacher label independence" {
  let f = contract_fixture(seed=41U)
  let actor = ReferenceActor::new(
    f.reference.reference.goals[0].length(),
    29,
    f.actor.lower,
    f.actor.upper,
    Array::makei(4, _ => [16.0, 32.0, -0.02, 1.0, 0.25]),
    [4, 5, 10, 11],
    @numeric.Rng::new(41U),
    history_length=10,
    future_length=10,
    width=16,
    latent_dim=8,
  )
  let rng = @numeric.Rng::new(42U)
  for row in actor.decoder[1].weight {
    for i in 0..<row.length() {
      row[i] = rng.normal() * 0.002
    }
  }
  for row in actor.decoder[0].weight {
    for i in 8..<row.length() {
      row[i] = 0.0
    }
  }
  let observations = f.reference.observations
  let goals = f.reference.reference.goals
  let points = training_points(
    observations,
    goals,
    f.reference.controls,
    10,
    10,
  )
  let runner = ReferenceRunner::new(actor, f.geometry, 0.02)
  let expected = points.map(point => prediction(actor, point))
  for i, point in points {
    contract_close(
      runner.predict(observations[i], point.current, point.future, point.valid),
      expected[i],
      atol=1.0e-7,
      rtol=1.0e-6,
    )
  }
  let path = contract_path("actor")
  let sha = save_reference_actor(path, actor, contract_spec(f), 0.02, {
    "source": "original-actor-contract",
  })
  let (restored, metadata) = load_reference_actor(path, expected_sha256=sha)
  assert_false(metadata.physical_execution_allowed)
  assert_eq(metadata.dt_s, 0.02)
  assert_eq(
    kinematics_from_spec(metadata.kinematics).to_json(),
    f.geometry.to_json(),
  )
  for i, point in points {
    assert_eq(prediction(restored, point), expected[i])
  }
  let tape = @numeric.Tape::new()
  let parameters = tape.vector(restored.parameters())
  let point = points[5]
  let history = point.history.map(row => tape.vector(row))
  let latent = restored.latent_graph(
    tape,
    parameters,
    history,
    tape.vector(point.current),
    point.future.map(row => tape.vector(row)),
    point.valid,
  )
  let action = restored.action_graph(
    tape,
    latent,
    history,
    tape.vector(point.current),
    tape.vector(Array::make(6, 0.0)),
    tape.vector(Array::make(6, 0.0)),
  )
  tape.backward(tape.mean(action))
  // Locate decoder.0 weights by the original named-parameter order.
  let offset = [restored.goal_encoder, restored.observation_encoder].fold(
    init=0,
    (n, layers) => {
      n +
      layers.fold(init=0, (m, l) => {
        m + l.bias.length() + l.weight.length() * l.weight[0].length()
      })
    },
  )
  let width = restored.decoder[0].weight[0].length()
  let mut reached = false
  for row in 0..<restored.decoder[0].weight.length() {
    for column in 8..<width {
      if tape.gradient(parameters[offset + row * width + column]).abs() > 0.0 {
        reached = true
      }
    }
  }
  assert_true(reached)
  let changed = training_points(
    observations,
    goals,
    f.reference.controls.map(row => row.map(x => x + 0.1)),
    10,
    10,
  )
  for i, p in points {
    assert_eq(p.history, changed[i].history)
    assert_eq(p.current, changed[i].current)
    assert_eq(p.future, changed[i].future)
    assert_eq(p.valid, changed[i].valid)
    contract_close(changed[i].target, p.target.map(x => x + 0.1))
  }
  @fs.remove(path)
}

///|
test "original actor feedback coefficients stay outside learned parameter vector" {
  let f = contract_fixture(seed=43U)
  let before = f.actor.parameters()
  f.actor.feedback_coefficients[0][0] = 16.0
  assert_eq(f.actor.parameters(), before)
  let t = @numeric.Tape::new()
  let inputs = t.vector([0.001, 0.0, 0.0, 0.0, 0.0, 0.0])
  let p = f.points[0]
  let command = f.schedule.command(0, 0, f.actor.future_length)
  let action = f.actor.action_graph(
    t,
    t.vector(Array::make(29, 0.0)),
    p.history.map(row => t.vector(row)),
    t.vector(command.current),
    inputs,
    t.vector(Array::make(6, 0.0)),
  )
  t.backward(action[4])
  assert_true(inputs.all(x => @numeric.finite(t.gradient(x))))
  assert_true(inputs.any(x => t.gradient(x).abs() > 0.0))
}
