///|
/// Physical stochastic history contract from test_temporal_ppo.py.
test "actual sampled PPO means actions histories likelihoods and truncation reconstruct" {
  let runtime = native_fixture()
  let actor = native_actor(runtime, 10, 10)
  let rng = @numeric.Rng::new(3U)
  let start = actor.temporal.adapter.parameters.length() - 9
  for i in start..<(actor.temporal.adapter.parameters.length() - 1) {
    actor.temporal.adapter.parameters[i] = 0.1 * (2.0 * rng.uniform() - 1.0)
  }
  let value = native_value(runtime, actor)
  let (batch, episode, _) = collect_ppo(
    runtime,
    actor,
    value,
    fixture_case(),
    5600,
    0.2,
    0.02,
    0.9,
    1.0,
    0.05,
    @numeric.Rng::new(3U),
  )
  assert_eq(batch.length(), 10)
  assert_true(episode.steps[9].truncated)
  let mut noise_max = 0.0
  for i, sample in batch {
    let point = sample.point
    let tape = @numeric.Tape::new()
    let mean = actor.latent_mean(
      tape,
      tape.vector(actor.parameters()),
      point.history.map(fn(row) { tape.vector(row) }),
      tape.vector(point.goals[0]),
      point.goals[1:11].map(fn(row) { tape.vector(row) }),
    )
    close_native(mean.map(fn(v) { v.value }), sample.old_mean, 1.0e-6)
    let action = actor.base
      .action_from_latent(
        tape,
        tape.vector(sample.latent),
        tape.vector(point.goals[0]),
      )
      .map(fn(v) { v.value })
    close_native(episode.steps[i].applied_action, action, 1.0e-14)
    let logp = @temporal.gaussian_log_probability(
      tape,
      mean,
      sample.latent,
      0.05,
    )
    assert_true((logp.value - sample.old_log_prob).abs() < 1.0e-12)
    noise_max = noise_max.max((sample.latent[0] - sample.old_mean[0]).abs())
    if i > 0 {
      assert_eq(point.history[9][8], episode.steps[i - 1].applied_action[0])
    }
  }
  assert_true(noise_max > 0.0)
}
