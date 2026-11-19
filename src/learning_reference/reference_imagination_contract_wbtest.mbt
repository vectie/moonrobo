///|
test "original learning imagination freezes world model and critic while actor receives gradient" {
  let f = contract_fixture()
  let rng = @numeric.Rng::new(9U)
  let model = contract_model(rng)
  let value = ReferenceValue::new(
    f.actor,
    Array::make(71, 0.0),
    Array::make(71, 1.0),
    1,
    rng,
  )
  for row in value.net[2].weight {
    for i in 0..<row.length() {
      row[i] = rng.normal() * 0.002
    }
  }
  let before = model.network.parameters.copy()
  let critic_before = value.parameters()
  let tape = @numeric.Tape::new()
  let params = tape.vector(f.actor.parameters())
  let (objective, active) = imagined_objective(
    tape,
    model,
    f.actor,
    params,
    Some(value),
    f.points,
    f.geometry,
    f.schedule,
    4,
    0.99,
  )
  tape.backward(objective)
  assert_eq(active, 8)
  assert_true(params.all(x => @numeric.finite(tape.gradient(x))))
  assert_true(params.any(x => tape.gradient(x).abs() > 0.0))
  let last_weight = params.length() -
    29 * (f.actor.decoder[1].weight[0].length() + 1)
  assert_true(
    params[last_weight:params.length() - 29].any(x => {
      tape.gradient(x).abs() > 0.0
    }),
  )
  assert_eq(model.network.parameters, before)
  assert_eq(value.parameters(), critic_before)
}

///|
test "original learning stop policy inputs cuts observer edge but retains plant BPTT" {
  let f = contract_fixture()
  let rng = @numeric.Rng::new(29U)
  let model = contract_model(rng)
  for row in f.actor.decoder[1].weight {
    for j in 0..<row.length() {
      row[j] = rng.normal() * 0.01
    }
  }
  for row in f.actor.feedback_coefficients {
    row[0] = 0.02
    row[1] = 0.02
  }
  let evaluate = (mode : FeedbackGradient) => {
    let tape = @numeric.Tape::new()
    let params = tape.vector(f.actor.parameters())
    let states : Array[@numeric.Value] = []
    let features : Array[@numeric.Value] = []
    let (objective, active) = imagined_objective(
      tape,
      model,
      f.actor,
      params,
      None,
      f.points,
      f.geometry,
      f.schedule,
      4,
      0.99,
      feedback_gradient=mode,
      critic_tail=false,
      initial_graph=(_, state, actual) => {
        states.append(state)
        features.append(actual)
      },
    )
    tape.backward(objective)
    (
      objective.value,
      active,
      params.map(x => tape.gradient(x)),
      states.map(x => tape.gradient(x)),
      features.map(x => tape.gradient(x)),
    )
  }
  let (full, nfull, pfull, sfull, ffull) = evaluate(Full)
  let (stop, nstop, pstop, sstop, fstop) = evaluate(StopPolicyInputs)
  assert_eq(full, stop)
  assert_eq(nfull, nstop)
  for gradients in [pfull, pstop, sfull, sstop] {
    assert_true(gradients.all(@numeric.finite))
    assert_true(gradients.any(x => x.abs() > 0.0))
  }
  assert_true(ffull.any(x => x.abs() > 0.0))
  assert_true(fstop.all(x => x == 0.0))
  assert_true(pfull.mapi((i, x) => (x - pstop[i]).abs()).any(x => x > 1.0e-14))
}

///|
test "original learning prefix ignores unused critic and stops bootstrap at reference end" {
  let f = contract_fixture()
  let rng = @numeric.Rng::new(8U)
  let model = contract_model(rng)
  let zero = ReferenceValue::new(
    f.actor,
    Array::make(71, 0.0),
    Array::make(71, 1.0),
    1,
    rng,
  )
  let unused = ReferenceValue::new(
    f.actor,
    Array::make(71, 0.0),
    Array::make(71, 1.0),
    1,
    rng,
  )
  unused.net[2].bias[0] = 200.0
  let two = ReferenceValue::new(
    f.actor,
    Array::make(71, 0.0),
    Array::make(71, 1.0),
    1,
    rng,
  )
  two.net[2].bias[0] = 2.0794415416798357
  for horizon in [4, 20] {
    let evaluate = (v : ReferenceValue, tail : Bool) => {
      let t = @numeric.Tape::new()
      let (objective, active) = imagined_objective(
        t,
        model,
        f.actor,
        t.vector(f.actor.parameters()),
        Some(v),
        [f.points[0]],
        f.geometry,
        f.schedule,
        horizon,
        0.99,
        critic_tail=tail,
      )
      (objective.value, active)
    }
    let (prefix, active) = evaluate(zero, false)
    let (no_critic, nunused) = evaluate(unused, false)
    let (zero_tail, nzero) = evaluate(zero, true)
    let (tail, ntail) = evaluate(two, true)
    let t = @numeric.Tape::new()
    let (without_value, without_value_active) = imagined_objective(
      t,
      model,
      f.actor,
      t.vector(f.actor.parameters()),
      None,
      [f.points[0]],
      f.geometry,
      f.schedule,
      horizon,
      0.99,
      critic_tail=false,
    )
    assert_eq(without_value.value, prefix)
    assert_eq(without_value_active, active)
    assert_eq(prefix, no_critic)
    assert_eq(prefix, zero_tail)
    assert_eq(active, nunused)
    assert_eq(active, nzero)
    assert_eq(active, ntail)
    assert_eq(active, horizon.min(f.schedule.length))
    let expected = if horizon < f.schedule.length {
      2.0 * @math.pow(0.99, horizon.to_double())
    } else {
      0.0
    }
    assert_true((tail - prefix - expected).abs() < 1.0e-10)
  }
}

///|
test "original learning calibrated actor updates remain nonzero below requested logit cap" {
  let f = contract_fixture()
  let rng = @numeric.Rng::new(44U)
  let model = contract_model(rng)
  let before = model.network.parameters.copy()
  let actor_before = f.actor.parameters()
  let optimizer = @numeric.Adam::new(actor_before.length(), 0.001)
  let updates = optimize_model_actor(
    model,
    f.actor,
    None,
    optimizer,
    contract_batch(f),
    f.geometry,
    f.schedule,
    contract_config(),
    rng,
    logit_cap=0.0001,
  )
  assert_eq(updates.length(), 2)
  for (_, applied) in updates {
    assert_true(applied > 0.0 && applied <= 0.0001)
  }
  assert_false(f.actor.parameters() == actor_before)
  assert_eq(model.network.parameters, before)
}
