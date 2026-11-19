///|
// Admission arithmetic only: no LibTorch backend, replay payload or simulator
// is allocated by this test. The production CLI caps remain separate.
test "N128 SMC batch fits retained staging bounds at exact required limits" {
  let config : @aligned.LearnerConfig = {
    ..@aligned.LearnerConfig::default(),
    wm_batch: 128,
    policy_batch: 128,
    hist: 10,
    goal_frames: 10,
    horizon: 32,
    wm_window: 8,
    critic_epochs: 5,
    observation_noise: true,
  }
  check_policy_limits(config, 128, @aligned.Smc.dim(), BatchLimits::default())
  check_policy_limits(config, 128, @aligned.Smc.dim(), {
    max_reference_frames: 4224,
    max_tensor_values: 3953152L,
  })
  for
    limits in [
      { max_reference_frames: 4223, max_tensor_values: 3953152L, },
      { max_reference_frames: 4224, max_tensor_values: 3953151L, },
    ] {
    let rejected = try {
      check_policy_limits(config, 128, @aligned.Smc.dim(), limits)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_eq(bounded_product([128L, 8L, 205L], 16777216L), 209920L)
  assert_eq(bounded_product([128L, 256L, 234L], 16777216L), 7667712L)
}
