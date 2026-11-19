///|
/// Exact finite-distribution score-function identity from test_temporal_ppo.py. This uses an enumerated two-step Bernoulli task, independent of the Gaussian rollout implementation.
test "soft discounted visitation weighted PPO score equals exact expected-return gradient" {
  let tape = @numeric.Tape::new()
  let theta = tape.vector([0.2, -0.3])
  let probabilities = theta.map(fn(v) { tape.sigmoid(v) })
  let mut exact = tape.scalar(0.0)
  let mut surrogate = tape.scalar(0.0)
  for a0 in [0.0, 1.0] {
    for a1 in [0.0, 1.0] {
      let actions = [a0, a1]
      let log_probability = Array::makei(2, fn(i) {
        tape.log(
          if actions[i] == 1.0 {
            probabilities[i]
          } else {
            tape.sub(tape.scalar(1.0), probabilities[i])
          },
        )
      })
      let probability = tape.exp(
        tape.add(log_probability[0], log_probability[1]),
      )
      let continuation = [0.2 + 0.6 * a0, 0.8]
      let returns = @training.physical_return_targets(
        [1.0 + a0, 2.0 - a1],
        continuation,
        [false, false],
        0.0,
        0.9,
      )
      exact = tape.add(exact, tape.scale(probability, returns[0]))
      let weights = discounted_visitation(continuation, 0.9)
      let loss = policy_loss(
        tape,
        log_probability,
        log_probability.map(fn(v) { v.value }),
        [returns[0] - 0.8, returns[1] - 1.1],
        weights,
        0.2,
      )
      surrogate = tape.add(
        surrogate,
        tape.scale(loss, -2.0 * probability.value),
      )
    }
  }
  tape.backward(exact)
  let actual = theta.map(fn(v) { tape.gradient(v) })
  tape.backward(surrogate)
  let estimate = theta.map(fn(v) { tape.gradient(v) })
  for i in 0..<2 {
    assert_true(
      (estimate[i] - actual[i]).abs() < 1.0e-7 + 1.0e-6 * actual[i].abs(),
    )
  }
}
