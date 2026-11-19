///|
test "fork repeats Adam update and sampler without aliased moments" {
  let weights = [0.3, -0.7]
  let optimizer = @numeric.Adam::new(2, 0.001)
  let sampler = Sampler::new(23000, None)
  let update = fn(
    parameters : Array[Double],
    opt : @numeric.Adam,
    draws : Array[Int32],
  ) {
    let tape = @numeric.Tape::new()
    let bound = tape.vector(parameters)
    let scalar = tape.add(
      tape.scale(bound[0], draws[0].to_double() + 1),
      tape.mul(bound[1], bound[1]),
    )
    tape.backward(scalar)
    ignore(opt.step(parameters, tape, bound))
  }
  update(weights, optimizer, sampler.indices(13, 1))
  let branch_weights = weights.copy()
  let branch_optimizer = optimizer.snapshot()
  let branch_sampler = sampler.fork()
  let draws = sampler.indices(17, 5)
  let branch_draws = branch_sampler.indices(17, 5)
  assert_eq(draws, branch_draws)
  update(weights, optimizer, draws)
  update(branch_weights, branch_optimizer, branch_draws)
  assert_eq(weights, branch_weights)
  assert_eq(optimizer.to_json(), branch_optimizer.to_json())
  assert_eq(sampler.state(), branch_sampler.state())
  let before = optimizer.to_json()
  branch_optimizer.first[0] += 1
  assert_eq(optimizer.to_json(), before)
  assert_true(optimizer.to_json() != branch_optimizer.to_json())
  let sampler_before = sampler.state()
  ignore(branch_sampler.indices(17, 1))
  assert_eq(sampler.state(), sampler_before)
  assert_true(sampler.state() != branch_sampler.state())
  let weight_before = weights.copy()
  branch_weights[0] += 10.0
  assert_eq(weights, weight_before)
  assert_true(branch_weights != weights)
}

///|
test "original final route warmed actor Adam and RNG fork repeat next update without aliases" {
  let actor = @reference.ReferenceActor::new(
    68,
    29,
    Array::make(29, -1.0),
    Array::make(29, 1.0),
    Array::makei(4, _ => Array::make(5, 0.0)),
    [4, 5, 10, 11],
    @numeric.Rng::new(42U),
    history_length=1,
    future_length=0,
    width=4,
    latent_dim=2,
  )
  let optimizer = @numeric.Adam::new(actor.parameters().length(), 0.001)
  let generator = @numeric.Rng::new(23000U)
  let update = (
    policy : @reference.ReferenceActor,
    opt : @numeric.Adam,
    rng : @numeric.Rng,
  ) => {
    let parameters = policy.parameters()
    let t = @numeric.Tape::new()
    let bound = t.vector(parameters)
    let draws = Array::makei(7, _ => rng.index(13))
    let terms = bound.mapi((i, x) => {
      t.scale(t.mul(x, x), 1.0 + draws[i % 7].to_double())
    })
    t.backward(t.mean(terms))
    ignore(opt.step(parameters, t, bound))
    policy.set_parameters(parameters)
    draws
  }
  ignore(update(actor, optimizer, generator))
  let (branch, branch_optimizer, branch_generator) = @reference.fork_actor_optimizer(
    actor, optimizer, generator,
  )
  assert_eq(
    update(actor, optimizer, generator),
    update(branch, branch_optimizer, branch_generator),
  )
  assert_eq(actor.parameters(), branch.parameters())
  assert_eq(optimizer.to_json(), branch_optimizer.to_json())
  assert_eq(generator.state(), branch_generator.state())
  let original_weights = actor.parameters()
  branch.decoder[1].bias[0] += 1.0
  assert_eq(actor.parameters(), original_weights)
  let original_moments = optimizer.to_json()
  branch_optimizer.first[0] += 1.0
  assert_eq(optimizer.to_json(), original_moments)
  let original_state = generator.state()
  ignore(branch_generator.index(13))
  assert_eq(generator.state(), original_state)
}
