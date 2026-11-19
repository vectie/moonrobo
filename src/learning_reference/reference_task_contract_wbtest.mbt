///|
test "original task real G1 FK batched nesting observer transport and memory gradients" {
  let f = contract_fixture(seed=58U, motion="random_joint_sines", seconds=0.6)
  let observations = f.reference.observations
  let before = @balance.BalanceHistory::full_memory(f.geometry, 0.02)
  let expected = observations.map(obs => before.observe(obs))
  let t = @numeric.Tape::new()
  let first = t.vector(observations[0])
  let mut memory = observer_memory_graph(t, first, t.vector(expected[0]))
  let advanced : Array[@numeric.Value] = []
  for i in 1..<observations.length() {
    let obs = t.vector(observations[i])
    let error = from_observation_graph(f.geometry, t, obs)
    let (features, next_memory) = observer_advance_graph(
      t, obs, memory, 0.02, error,
    )
    contract_close(
      features.map(x => x.value),
      expected[i],
      atol=2.0e-6,
      rtol=2.0e-5,
    )
    memory = next_memory
    if i == observations.length() - 1 {
      advanced.append(obs)
    }
  }
  let nested = Array::makei(2, i => {
    Array::makei(3, j => {
      f.geometry.geometry(observations[i * 3 + j][:29].to_owned())
    })
  })
  assert_eq(nested.length(), 2)
  assert_eq(nested[0].length(), 3)
  let (com, feet) = nested[0][0]
  let (single_com, single_feet) = f.geometry.geometry(
    observations[0][:29].to_owned(),
  )
  assert_eq(com, single_com)
  assert_eq(feet, single_feet)
  assert_eq(feet.length(), 2)
  assert_eq(com.length(), 3)
  let state_inputs : Array[@numeric.Value] = []
  let losses : Array[@numeric.Value] = []
  for i, frame in f.reference.frames[:observations.length()] {
    let state = t.vector(frame.state)
    state_inputs.append(state)
    let (reward, fallen, error) = reference_reward_graph(
      f.geometry,
      t,
      state,
      t.vector(Array::make(29, 0.0)),
      t.vector(Array::make(29, 0.0)),
      frame.body_position,
      frame.state[3:7].to_owned(),
      frame.state[7:36].to_owned(),
    )
    assert_true((reward.value - 0.06).abs() < 2.0e-7)
    assert_false(fallen)
    contract_close(
      error.map(x => x.value),
      expected[i][:3].to_owned(),
      atol=2.0e-7,
      rtol=2.0e-5,
    )
    losses.push(reward)
  }
  // Detach carried memory, exactly as the original final-observation gradient check.
  let last = t.vector(observations.last().unwrap())
  let detached = observer_memory_graph(
    t,
    t.vector(observations[observations.length() - 2]),
    t.vector(expected[expected.length() - 2]),
  )
  let (feature, _) = observer_advance_graph(
    t,
    last,
    detached,
    0.02,
    from_observation_graph(f.geometry, t, last),
  )
  for x in feature {
    losses.push(t.mul(x, x))
  }
  let total = losses.fold(init=t.scalar(0.0), (sum, x) => t.add(sum, x))
  t.backward(total)
  assert_true(state_inputs.all(x => @numeric.finite(t.gradient(x))))
  assert_true(last.any(x => t.gradient(x).abs() > 0.0))
  assert_true(last.all(x => @numeric.finite(t.gradient(x))))
}
