///|
/// Port of test_temporal_value.py: finite task cap, XY invariance, causal history/future encoding, paired reload and actual predicted-history tail gradients.
async test "value enforces task cap fall mask translation invariance and paired reload" {
  let actor = contract_actor(3, 2)
  let value = make_value(
    contract_model(),
    actor,
    8,
    0.9,
    10.0,
    @numeric.Rng::new(3U),
  )
  let rng = @numeric.Rng::new(3U)
  let offset = value.net.parameters.length() - 65
  for i in offset..<(value.net.parameters.length() - 1) {
    value.net.parameters[i] = 0.1 * (2.0 * rng.uniform() - 1.0)
  }
  let state = contract_state()
  let history = Array::makei(10, fn(_) {
    Array::makei(9, fn(_) { rng.normal() })
  })
  let goals = Array::makei(11, fn(_) { [rng.normal()] })
  let result = value.predict(state, history, goals, [1.0, 1.0], 1.0)
  let moved = state.copy()
  moved[0] += 10000.0
  moved[1] += 10000.0
  assert_eq(value.predict(moved, history, goals, [1.0, 1.0], 1.0), result)
  assert_eq(value.predict(state, history, goals, [1.0, 1.0], 0.0), 0.0)
  let fallen = state.copy()
  fallen[2] = 0.3
  assert_eq(value.predict(fallen, history, goals, [1.0, 1.0], 1.0), 0.0)
  assert_true(
    value.predict(
      state,
      history.map(fn(row) { row.map(fn(x) { x + 1.0 }) }),
      goals,
      [1.0, 1.0],
      1.0,
    ) !=
    result,
  )
  assert_true(
    value.predict(
      state,
      history,
      goals.map(fn(row) { row.map(fn(x) { x + 1.0 }) }),
      [1.0, 1.0],
      1.0,
    ) !=
    result,
  )
  let folder = @fs.tmpdir(prefix="moonrobo-temporal-value-")
  defer (@fs.rmdir(folder, recursive=true) catch { _ => () })
  let path = folder + "/temporal-value-pair-contract.moon.json"
  ignore(
    save_temporal(path, actor, {
      "temporal_value_checkpoint": value.checkpoint(Json::null()).to_json(),
    }),
  )
  let restored = load_value(path)
  assert_eq(restored.predict(state, history, goals, [1.0, 1.0], 1.0), result)
}

///|
test "finite tail consumes predicted H10 history future phase and original remaining time" {
  let actor = contract_actor(3, 2)
  let model = contract_model()
  let critic = make_value(model, actor, 8, 0.9, 10.0, @numeric.Rng::new(3U))
  model.network.parameters[model.network.parameters.length() - 14 + 7] = 0.01
  critic.net.parameters[critic.net.parameters.length() - 1] = 10.0
  let state = contract_state()
  let history = Array::makei(10, fn(_) { contract_observation(state, [0.0]) })
  let goals = Array::makei(14, fn(i) { [i.to_double() * 0.01] })
  let point : ValuePoint = {
    state,
    history,
    goals,
    context: [1.0, 1.0],
    remaining: 1.0,
    target: 0.0,
  }
  let tape = @numeric.Tape::new()
  let actor_parameters = tape.vector(actor.parameters())
  let model_parameters = model.network.bind(tape)
  let value_parameters = critic.net.bind(tape)
  let off = finite_imagination(
    model,
    actor,
    critic,
    tape,
    model_parameters,
    actor_parameters,
    value_parameters,
    point,
    { horizon: 3, gamma: 0.9, target_height: 0.8, bootstrap: false, },
  )
  let captured : Array[
    (Array[@numeric.Value], Array[Array[@numeric.Value]], Int32),
  ] = []
  let graph_goals = goals.map(fn(row) { tape.vector(row) })
  let on = temporal_imagination(
    tape,
    tape.vector(state),
    history.map(fn(row) { tape.vector(row) }),
    graph_goals,
    tape.vector([1.0, 1.0]),
    3,
    2,
    0.9,
    fn(h, g, f) {
      actor.forward(
        tape,
        actor_parameters,
        Array::makei(3, fn(i) { h[h.length() - 3 + i] }),
        g,
        f,
      )
    },
    fn(s, a, c) { model.forward(tape, model_parameters, s, a, c) },
    fn(s, a) { @training.observation(tape, s, a, actor.base.body) },
    fn(s, a, p, g) {
      @training.step_reward(tape, s, a, p, g, actor.base.body.q_indices, 0.8)
    },
    fn(s, h, horizon) {
      captured.push((s, h, horizon))
      critic.forward(
        tape,
        value_parameters,
        s,
        h,
        Array::makei(11, fn(i) { graph_goals[horizon + i] }),
        tape.vector([1.0, 1.0]),
        tape.scalar(point.remaining - horizon.to_double() * 0.02),
      )
    },
    true,
  )
  assert_eq(captured.length(), 1)
  assert_eq(captured[0].1.length(), 10)
  assert_eq(captured[0].2, 3)
  assert_true((captured[0].0[7].value - state[7] - 0.03).abs() < 1.0e-14)
  let expected_tail = critic.predict(
    captured[0].0.map(fn(v) { v.value }),
    captured[0].1.map(fn(row) { row.map(fn(v) { v.value }) }),
    goals[3:14].to_owned(),
    [1.0, 1.0],
    0.94,
  )
  let survive = on.continuations.fold(init=1.0, fn(s, v) { s * v.value })
  assert_true(
    (on.total.value - off.value - 0.9 * 0.9 * 0.9 * survive * expected_tail).abs() <
    1.0e-12,
  )
  let finite_on = finite_imagination(
    model,
    actor,
    critic,
    tape,
    model_parameters,
    actor_parameters,
    value_parameters,
    point,
    { horizon: 3, gamma: 0.9, target_height: 0.8, bootstrap: true, },
  )
  assert_eq(finite_on.value, on.total.value)
  tape.backward(finite_on)
  ignore(check_finite_gradients(tape, actor_parameters))
  let frozen_model = model.network.parameters.copy()
  let frozen_critic = critic.net.parameters.copy()
  ignore(
    imagination_update(
      model,
      actor,
      critic,
      @numeric.Adam::new(actor.parameters().length(), 1.0e-5),
      [point],
      { horizon: 3, gamma: 0.9, target_height: 0.8, bootstrap: true, },
    ),
  )
  assert_eq(model.network.parameters, frozen_model)
  assert_eq(critic.net.parameters, frozen_critic)
}

///|
test "physical time-limit return includes terminal reward but has no task-cap tail" {
  let continuation = 1.0 / (1.0 + @math.exp(-22.5)) / (1.0 + @math.exp(-10.0))
  let targets = @training.physical_return_targets(
    [3.0, 3.0],
    [continuation, continuation],
    [false, false],
    0.0,
    0.9,
  )
  assert_eq(targets[1], 3.0)
  assert_true((targets[0] - (3.0 + 0.9 * continuation * 3.0)).abs() < 1.0e-12)
  assert_eq([0.04 - 0.0, 0.04 - 0.02], [0.04, 0.02])
}
