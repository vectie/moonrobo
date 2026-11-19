///|
/// Gradient contracts from test_balance_features.py. These exercise the actual shared MoonBit reverse-mode FK and observation-only observer graph, not a finite-difference replacement for the implementation.
test "FK observation gradients match independent central differences" {
  let geometry = fixture_geometry()
  let obs = [0.41, 0.02, 0.1, -0.2, -0.95, 0.03, -0.01, 0.02, 0.0]
  let tape = @numeric.Tape::new()
  let variables = tape.vector(obs)
  let result = @reference.from_observation_graph(geometry, tape, variables)
  let scalar = tape.mean(result)
  tape.backward(scalar)
  for i in [0, 2, 3, 4] {
    let plus = obs.copy()
    let minus = obs.copy()
    plus[i] += 1.0e-6
    minus[i] -= 1.0e-6
    let positive = geometry
      .from_observation(plus)
      .fold(init=0.0, fn(s, x) { s + x }) /
      3.0
    let negative = geometry
      .from_observation(minus)
      .fold(init=0.0, fn(s, x) { s + x }) /
      3.0
    let numeric = (positive - negative) / 2.0e-6
    let analytic = tape.gradient(variables[i])
    assert_true(@numeric.finite(analytic))
    assert_true((analytic - numeric).abs() < 1.0e-6 + 1.0e-4 * numeric.abs())
  }
}

///|
test "causal observer has finite past gradients and zero future dependence" {
  let geometry = fixture_geometry()
  let observations = Array::makei(25, fn(i) {
    let a = i.to_double() * 0.02
    [
      0.3 + 0.1 * @math.sin(0.2 * i.to_double()),
      0.0,
      @math.sin(a),
      0.0,
      -@math.cos(a),
      0.0,
      1.0,
      0.0,
      0.0,
    ]
  })
  let tape = @numeric.Tape::new()
  let values = observations.map(fn(row) { tape.vector(row) })
  let error = @reference.from_observation_graph(geometry, tape, values[0])
  let initial = error.copy()
  initial.append(tape.vector([0.0, 0.0, 0.0]))
  let mut memory = @reference.observer_memory_graph(
    tape,
    values[0],
    initial,
    nu=1,
  )
  let mut feature = initial
  for i in 1..<8 {
    let error = @reference.from_observation_graph(geometry, tape, values[i])
    let (next_features, next_memory) = @reference.observer_advance_graph(
      tape,
      values[i],
      memory,
      0.02,
      error,
      nu=1,
    )
    feature = next_features
    memory = next_memory
  }
  tape.backward(tape.mean(feature))
  let mut maximum = 0.0
  for i, row in values {
    for v in row {
      let g = tape.gradient(v)
      assert_true(@numeric.finite(g))
      if i >= 8 {
        assert_eq(g, 0.0)
      } else {
        maximum = maximum.max(g.abs())
      }
    }
  }
  assert_true(maximum > 0.0)
  let offline = sequence_features(
      geometry,
      observations,
      0.02,
      Some(10),
      GravityGyro,
    )[7]
  for i, v in feature {
    assert_true((v.value - offline[i]).abs() < 1.0e-12)
  }
}
