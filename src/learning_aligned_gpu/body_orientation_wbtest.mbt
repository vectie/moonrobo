///|
test "batched body orientation preserves same-plan 32-step learner GAE and Adam" {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("body orientation learner test device must be cpu or cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA body-orientation learner gate needs plugin")
    }
    println("SKIP body orientation learner gate: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  if device >= 0 {
    guard backend.cuda_device_count() > 0 &&
      backend.cuda_free_bytes(device) > 17179869184L else {
      fail("body orientation learner gate requires 16 GiB CUDA free reserve")
    }
  }
  let config = {
    ..micro_config(),
    wm_batch: 4,
    policy_batch: 4,
    critic_epochs: 5,
    critic_minibatches: 4,
  }
  let (world, policy) = gate_batches(backend, device, 5)
  for size in [0, 2] {
    for reuse in [false, true] {
      let make = (batched : Bool) => {
        Learner::new(
          backend,
          micro_context(backend, cuda_device=device),
          config~,
          cuda_device=device,
          world_microbatch=size,
          actor_microbatch=size,
          optimizations={
            ..ExecutionOptimizations::default(),
            body_orientation_batched: batched,
            reuse_geometry: reuse,
          },
        )
      }
      let baseline = make(false)
      let candidate = make(true)
      for learner in [baseline, candidate] {
        trace_test_prepare(learner, world, policy)
      }
      for iteration in 0..<4 {
        let label = "body-batched chunk \{size} reuse \{reuse} iteration \{iteration}"
        let (a, b) = if iteration == 0 {
          let ta = CriticTrace::new(8)
          let tb = CriticTrace::new(8)
          let a = baseline.update_policy_impl(
            policy,
            train_critic=true,
            trace=Some(ta),
          )
          let b = candidate.update_policy_impl(
            policy,
            train_critic=true,
            trace=Some(tb),
          )
          critic_graph_test_trace(tb, ta)
          (a, b)
        } else {
          (baseline.update_policy(policy), candidate.update_policy(policy))
        }
        assert_eq(a.imagined_steps, 128)
        assert_eq(b.imagined_steps, 128)
        assert_eq(a.critic_updates, 20)
        assert_eq(b.critic_updates, 20)
        micro_near(
          [b.policy_loss, b.critic_loss, b.imagined_reward, b.imagined_survival],
          [a.policy_loss, a.critic_loss, a.imagined_reward, a.imagined_survival],
          label,
        )
        for
          (actual, expected) in [
            (candidate.policy.parameters(), baseline.policy.parameters()),
            (
              candidate.critic.net.parameters(),
              baseline.critic.net.parameters(),
            ),
          ] {
          for i, parameter in actual {
            micro_near(
              parameter.values(),
              expected[i].values(),
              label + " parameter",
            )
            micro_near(
              parameter.gradient_values(),
              expected[i].gradient_values(),
              label + " gradient",
            )
          }
        }
        micro_compare_adam(
          candidate.opt_policy,
          baseline.opt_policy,
          candidate.policy.parameters().length(),
        )
        micro_compare_adam(
          candidate.opt_critic,
          baseline.opt_critic,
          candidate.critic.net.parameters().length(),
        )
        for i, norm in candidate.normalizers() {
          assert_eq(norm.count, baseline.normalizers()[i].count)
          micro_near(
            norm.mean.values(),
            baseline.normalizers()[i].mean.values(),
            label + " normalizer mean",
          )
          micro_near(
            norm.variance.values(),
            baseline.normalizers()[i].variance.values(),
            label + " normalizer variance",
          )
        }
      }
    }
  }
}
