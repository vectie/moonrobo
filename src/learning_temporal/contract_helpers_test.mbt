///|
/// Shared deterministic fixtures for the per-source temporal test translations. Random streams are native MoonBit; planted laws and contract assertions are independent of Torch seed equivalence.
fn contract_actor(history : Int32, future : Int32) -> TemporalPolicy {
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
  TemporalPolicy::new(base, history, future, 8, @numeric.Rng::new(7U))
}

///|
fn contract_model() -> @training.Dynamics {
  @training.Dynamics::new(
    { mean: Array::make(14, 0.0), scale: Array::make(14, 1.0), },
    { mean: [0.0], scale: [1.0], },
    { mean: [0.0, 0.0], scale: [1.0, 1.0], },
    8,
    @numeric.Rng::new(3U),
  )
}

///|
fn contract_state() -> Array[Double] {
  let state = Array::make(14, 0.0)
  state[2] = 0.8
  state[3] = 1.0
  state[7] = -0.1
  state
}

///|
fn contract_observation(
  state : Array[Double],
  previous : Array[Double],
) -> Array[Double] {
  let tape = @numeric.Tape::new()
  @training.observation(tape, tape.vector(state), tape.vector(previous), {
    q_indices: [7],
    v_state_indices: [8],
    nq: 8,
  }).map(fn(v) { v.value })
}

///|
fn check_finite_gradients(
  tape : @numeric.Tape,
  parameters : Array[@numeric.Value],
) -> Double raise {
  let mut total = 0.0
  for p in parameters {
    let gradient = tape.gradient(p)
    assert_true(@numeric.finite(gradient))
    total += gradient * gradient
  }
  assert_true(total > 0.0)
  total.sqrt()
}
