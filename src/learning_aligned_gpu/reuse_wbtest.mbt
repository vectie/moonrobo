///|
test "reuse candidates preserve same-plan actor critic gradients Adam and normalizers" {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("MOONROBO_OPTIMIZATION_TEST_DEVICE must be cpu or cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA reuse test requires MOONROBO_TENSOR_LIBRARY")
    }
    println("SKIP learner reuse integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  if device >= 0 {
    guard backend.cuda_device_count() > 0 &&
      backend.cuda_free_bytes(device) > 17179869184L else {
      fail("CUDA reuse parity requires a device and more than 16 GiB free")
    }
  }
  let w = micro_world_batch(backend)
  let p = micro_policy_batch(backend)
  let world : WorldBatch = {
    s: gate_transfer(backend, w.s, device),
    s1: gate_transfer(backend, w.s1, device),
    actions: gate_transfer(backend, w.actions, device),
    xi: gate_transfer(backend, w.xi, device),
    mask: gate_transfer(backend, w.mask, device),
  }
  let batch : PolicyBatch = {
    state: gate_transfer(backend, p.state, device),
    previous: gate_transfer(backend, p.previous, device),
    xi: gate_transfer(backend, p.xi, device),
    history: gate_transfer(backend, p.history, device),
    references: p.references.map(s => {
      @geometry.State::from_flat71(
        backend,
        gate_transfer(backend, s.flatten71(backend), device),
      )
    }),
    goals: p.goals.map(t => gate_transfer(backend, t, device)),
    reference_fk: None,
    step_noise: p.step_noise.map(t => gate_transfer(backend, t, device)),
    critic_orders: p.critic_orders.map(t => gate_transfer(backend, t, device)),
  }
  for actor_microbatch in [0, 2] {
    for
      (geometry, normalization) in [(false, true), (true, false), (true, true)] {
      let baseline = Learner::new(
        backend,
        micro_context(backend, cuda_device=device),
        config=micro_config(),
        actor_microbatch~,
        cuda_device=device,
      )
      let candidate = Learner::new(
        backend,
        micro_context(backend, cuda_device=device),
        config=micro_config(),
        actor_microbatch~,
        cuda_device=device,
        optimizations={
          ..ExecutionOptimizations::default(),
          reuse_geometry: geometry,
          reuse_critic_normalization: normalization,
        },
      )
      for learner in [baseline, candidate] {
        micro_observe(learner, world)
        for _ in 0..<2 {
          ignore(learner.fit_world_batch(world))
        }
        learner.policy.update_normalizers(
          batch.history.reshape([50, 93]),
          batch.goals[0],
        )
      }
      for iteration in 0..<2 {
        let a = baseline.update_policy(batch)
        let b = candidate.update_policy(batch)
        let label = "reuse geometry=\{geometry} norm=\{normalization} chunk=\{actor_microbatch} iter=\{iteration}"
        assert_eq(a.imagined_steps, b.imagined_steps)
        assert_eq(a.critic_updates, 6)
        assert_eq(a.critic_updates, b.critic_updates)
        micro_near(
          [a.policy_loss, a.critic_loss, a.imagined_reward, a.imagined_survival],
          [b.policy_loss, b.critic_loss, b.imagined_reward, b.imagined_survival],
          label,
        )
        for
          (parameters_a, parameters_b) in [
            (baseline.policy.parameters(), candidate.policy.parameters()),
            (
              baseline.critic.net.parameters(),
              candidate.critic.net.parameters(),
            ),
          ] {
          for i, parameter in parameters_a {
            micro_near(
              parameter.values(),
              parameters_b[i].values(),
              label + " parameters",
            )
            micro_near(
              parameter.gradient_values(),
              parameters_b[i].gradient_values(),
              label + " gradients",
            )
          }
        }
        micro_compare_adam(
          baseline.opt_policy,
          candidate.opt_policy,
          baseline.policy.parameters().length(),
        )
        micro_compare_adam(
          baseline.opt_critic,
          candidate.opt_critic,
          baseline.critic.net.parameters().length(),
        )
        for i, norm in baseline.normalizers() {
          assert_eq(norm.count, candidate.normalizers()[i].count)
          micro_near(
            norm.mean.values(),
            candidate.normalizers()[i].mean.values(),
            label + " normalizer mean",
          )
          micro_near(
            norm.variance.values(),
            candidate.normalizers()[i].variance.values(),
            label + " normalizer variance",
          )
        }
      }
      let critic_before = candidate.critic.net.parameters().map(p => p.values())
      let count = candidate.critic.norm.count
      let a = baseline.update_policy(batch, train_critic=false)
      let b = candidate.update_policy(batch, train_critic=false)
      micro_near(
        [a.policy_loss, a.imagined_reward, a.imagined_survival],
        [b.policy_loss, b.imagined_reward, b.imagined_survival],
        "actor-only reuse tail",
      )
      assert_eq(b.critic_updates, 0)
      assert_eq(candidate.critic.norm.count, count)
      assert_eq(
        candidate.critic.net.parameters().map(p => p.values()),
        critic_before,
      )
    }
  }
}
