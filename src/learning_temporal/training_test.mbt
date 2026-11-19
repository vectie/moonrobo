///|
test "zero adapter preserves parent with arbitrary causal and future inputs" {
  let base = @training.Actor::new(
    { mean: Array::make(9, 0.0), scale: Array::make(9, 1.0), },
    { mean: [0.0], scale: [1.0], },
    [-1.0],
    [1.0],
    0.3,
    { q_indices: [7], v_state_indices: [8], nq: 8, },
    8,
    @numeric.Rng::new(4U),
  )
  base.network.parameters[base.network.parameters.length() - 1] = 0.4
  let actor = TemporalPolicy::new(base, 3, 2, 8, @numeric.Rng::new(5U))
  let history = [Array::make(9, 2.0), Array::make(9, -4.0), Array::make(9, 0.1)]
  let goal = [0.2]
  assert_eq(
    actor.predict(history, goal, [[2.0], [-3.0]]),
    base.predict(history[2], goal),
  )
}

///|
test "PPO clipped objective has the expected plateau and signed derivative" {
  let tape = @numeric.Tape::new()
  let p = tape.scalar(0.0)
  let loss = policy_loss(tape, [p], [0.0], [2.0], [1.0], 0.2)
  tape.backward(loss)
  assert_eq(loss.value, -2.0)
  assert_eq(tape.gradient(p), -2.0)
  let tape2 = @numeric.Tape::new()
  let p2 = tape2.scalar(@math.ln(1.5))
  let clipped = policy_loss(tape2, [p2], [0.0], [2.0], [1.0], 0.2)
  tape2.backward(clipped)
  assert_true((clipped.value + 2.4).abs() < 1.0e-14)
  assert_eq(tape2.gradient(p2), 0.0)
}
