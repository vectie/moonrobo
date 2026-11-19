///|
/// Pure per-origin/gradient contract from test_temporal_probe.py. Native restore/phase contracts are translated in physics/probe_contract_test.mbt.
fn toy_probe_returns(
  actor : TemporalPolicy,
  states : Array[Array[Double]],
  goals : Array[Array[Double]],
  tape : @numeric.Tape,
  bound : Array[@numeric.Value],
) -> Array[@numeric.Value] {
  states.map(fn(state) {
    let history = Array::makei(3, fn(_) {
      tape.vector(contract_observation(state, [0.0]))
    })
    temporal_imagination(
      tape,
      tape.vector(state),
      history,
      goals.map(fn(row) { tape.vector(row) }),
      tape.vector([1.0, 1.0]),
      3,
      2,
      0.99,
      fn(h, g, f) { actor.forward(tape, bound, h, g, f) },
      fn(s, a, _) {
        Array::makei(s.length(), fn(i) {
          if i == 7 {
            tape.add(s[i], tape.scale(a[0], 0.1))
          } else {
            s[i]
          }
        })
      },
      fn(s, a) { @training.observation(tape, s, a, actor.base.body) },
      fn(s, a, p, g) {
        @training.step_reward(tape, s, a, p, g, actor.base.body.q_indices, 1.0)
      },
      fn(_, _, _) { tape.scalar(0.0) },
      false,
    ).total
  })
}

///|
test "per-origin returns average and temporal Adam improve the same frozen toy dynamics" {
  let actor = contract_actor(3, 2)
  let rng = @numeric.Rng::new(3U)
  let offset = actor.temporal.adapter.parameters.length() - 9
  for i in offset..<(actor.temporal.adapter.parameters.length() - 1) {
    actor.temporal.adapter.parameters[i] = 0.3 * (2.0 * rng.uniform() - 1.0)
  }
  let state = contract_state()
  state[2] = 1.0
  let other = state.copy()
  other[7] = -0.2
  let states = [state, other]
  let goals = [[0.1], [0.2], [0.05], [-0.1], [-0.2], [0.1]]
  let tape = @numeric.Tape::new()
  let parameters = actor.parameters()
  let bound = tape.vector(parameters)
  let returns = toy_probe_returns(actor, states, goals, tape, bound)
  let mean = tape.mean(returns)
  assert_eq(mean.value, (returns[0].value + returns[1].value) / 2.0)
  tape.backward(tape.scale(mean, -1.0 / 3.0))
  ignore(check_finite_gradients(tape, bound))
  let optimizer = @numeric.Adam::new(parameters.length(), 1.0e-5)
  let norm = optimizer.step(parameters, tape, bound)
  assert_true(norm > 0.0)
  actor.restore(parameters)
  let after_tape = @numeric.Tape::new()
  let after = after_tape.mean(
    toy_probe_returns(
      actor,
      states,
      goals,
      after_tape,
      after_tape.vector(actor.parameters()),
    ),
  )
  assert_true(after.value > mean.value)
}
