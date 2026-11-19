///|
fn actor_snapshot_test_backend() -> (@tensor.Backend, Int32)? raise {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("actor norm snapshot test device must be cpu or cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA actor norm snapshot gate needs tensor plugin")
    }
    println("SKIP actor norm snapshot gate: set MOONROBO_TENSOR_LIBRARY")
    return None
  }
  let backend = @tensor.Backend::open(path)
  if device >= 0 {
    guard backend.cuda_device_count() > 0 &&
      backend.cuda_free_bytes(device) > 17179869184L else {
      fail("actor norm snapshot gate requires 16 GiB CUDA free reserve")
    }
  }
  Some((backend, device))
}

///|
test "actor norm snapshot preserves inputs and gradients and expires at update boundary" {
  guard actor_snapshot_test_backend() is Some((backend, device)) else { return }
  for dtype in [@tensor.Float32, @tensor.Float64] {
    let norm = RunningNorm::new(backend, 4, cuda_device=device)
    assert_true(norm.compiled_bf16_input is None)
    let upload = (values : Array[Double], grad : Bool) => {
      backend.from_values(
        [2, 4],
        values,
        cuda_device=device,
        requires_grad=grad,
        dtype~,
      )
    }
    norm.update(upload([0.1, -0.2, 0.3, 0.0, 0.4, -0.1, -0.5, 0.0], false))
    let snapshot = norm.actor_snapshot()
    assert_true(snapshot.compiled_bf16_input is None)
    let mean = snapshot.mean.values()
    let std = snapshot.std.values()
    let a = upload([0.8, 0.1, -0.4, 0.01, -0.2, 0.3, 0.9, -0.01], true)
    let b = upload(a.values(), true)
    let original = norm.apply(a)
    let cached = snapshot.apply(b)
    micro_near(cached.values(), original.values(), "snapshot normalization")
    original.square().mean().backward()
    cached.square().mean().backward()
    micro_near(
      b.gradient_values(),
      a.gradient_values(),
      "snapshot input gradient",
    )
    // Running statistics remain detached; sharing std must not create a graph
    // that the first microbatch backward consumes before subsequent chunks.
    for value in [snapshot.mean, snapshot.std] {
      try value.sum().backward() catch {
        @tensor.TensorError::Native(message) =>
          assert_true(message.contains("does not require grad"))
        error => raise error
      } noraise {
        _ => fail("snapshot running statistics unexpectedly require gradients")
      }
    }
    norm.update(upload([1.0, 2.0, 3.0, 4.0, 1.5, 2.5, 3.5, 4.5], false))
    assert_eq(norm.count, 4.0)
    assert_eq(snapshot.mean.values(), mean)
    assert_eq(snapshot.std.values(), std)
    let current = norm.actor_snapshot()
    assert_true(current.mean.values() != mean)
    assert_true(current.std.values() != std)
    micro_near(
      current.apply(b).values(),
      norm.apply(a).values(),
      "refreshed normalization",
    )
    assert_true(snapshot.apply(b).values() != current.apply(b).values())
  }
}

///|
fn actor_snapshot_test_state(
  actual : Learner,
  expected : Learner,
  label : String,
  train_critic~ : Bool = true,
) -> Unit raise {
  for
    (parameters, other, needs_grad) in [
      (actual.world.net.parameters(), expected.world.net.parameters(), false),
      (actual.policy.parameters(), expected.policy.parameters(), true),
      (
        actual.critic.net.parameters(),
        expected.critic.net.parameters(),
        train_critic,
      ),
    ] {
    for i, parameter in parameters {
      micro_near(parameter.values(), other[i].values(), label + " parameter")
      if needs_grad {
        micro_near(
          parameter.gradient_values(),
          other[i].gradient_values(),
          label + " gradient",
        )
      } else {
        critic_graph_test_absent_gradient(parameter)
        critic_graph_test_absent_gradient(other[i])
      }
    }
  }
  for
    (optimizer, other, count) in [
      (
        actual.opt_world,
        expected.opt_world,
        actual.world.net.parameters().length(),
      ),
      (
        actual.opt_policy,
        expected.opt_policy,
        actual.policy.parameters().length(),
      ),
      (
        actual.opt_critic,
        expected.opt_critic,
        actual.critic.net.parameters().length(),
      ),
    ] {
    micro_compare_adam(optimizer, other, count)
  }
  for i, norm in actual.normalizers() {
    let other = expected.normalizers()[i]
    assert_eq(norm.count, other.count)
    micro_near(norm.mean.values(), other.mean.values(), label + " mean")
    micro_near(
      norm.variance.values(),
      other.variance.values(),
      label + " variance",
    )
  }
}

///|
fn actor_snapshot_test_learner(
  backend : @tensor.Backend,
  device : Int32,
  width : Int32,
  microbatch : Int32,
  reuse_critic : Bool,
) -> Unit raise {
  let (world, four) = gate_batches(backend, device, 5)
  let policy = if width == 4 {
    four
  } else {
    guard width == 8 else { fail("bounded snapshot fixture supports B4 or B8") }
    {
      state: backend.concat([four.state, four.state]),
      previous: backend.concat([four.previous, four.previous]),
      xi: backend.concat([four.xi, four.xi]),
      history: backend.concat([four.history, four.history]),
      references: four.references.map(s => concat_states(backend, [s, s])),
      reference_fk: None,
      goals: four.goals.map(g => backend.concat([g, g])),
      step_noise: four.step_noise.map(g => backend.concat([g, g])),
      critic_orders: Array::makei(5, epoch => {
        backend.from_values(
          [256],
          Array::makei(256, i => ((i * 37 + epoch * 17) % 256).to_double()),
          cuda_device=device,
          requires_grad=false,
          dtype=Int64,
        )
      }),
    }
  }
  let config = {
    ..micro_config(),
    wm_batch: 4,
    policy_batch: width,
    critic_epochs: 5,
    critic_minibatches: 4,
  }
  let make = (snapshot : Bool) => {
    Learner::new(
      backend,
      micro_context(backend, cuda_device=device),
      config~,
      cuda_device=device,
      actor_microbatch=microbatch,
      optimizations={
        ..ExecutionOptimizations::default(),
        actor_norm_snapshot: snapshot,
        reuse_critic_normalization: reuse_critic,
      },
    )
  }
  let baseline = make(false)
  let candidate = make(true)
  assert_true(baseline.snapshot_actor_norms() is None)
  for learner in [baseline, candidate] {
    learner.observe(
      world.s.reshape([32, 71]),
      world.actions.reshape([32, 29]),
      world.xi.reshape([32, 33]),
      world.s1.reshape([32, 71]),
    )
    learner.policy.update_normalizers(
      policy.history.reshape([width * 10, 93]),
      policy.goals[0],
    )
    for _ in 0..<2 {
      ignore(learner.fit_world_batch(world))
    }
  }
  for iteration in 0..<4 {
    let label = "snapshot B\{width} chunk\{microbatch} critic-reuse\{reuse_critic} iter\{iteration}"
    if iteration > 0 {
      // Deliberately update every cached statistic between logical updates.
      // A learner-level persistent cache would make the following gate fail.
      for learner in [baseline, candidate] {
        for
          norm in [
            learner.policy.goal_norm,
            learner.policy.obs_norm,
            learner.world.input_norm,
            learner.world.output_norm,
          ] {
          norm.update(norm.mean.reshape([1, norm.dim]).affine(1.0, bias=0.001))
        }
      }
    }
    let (a, b) = if iteration == 0 && width == 4 {
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
    assert_eq(a.imagined_steps, 32 * width)
    assert_eq(b.imagined_steps, 32 * width)
    assert_eq(a.critic_updates, 20)
    assert_eq(b.critic_updates, 20)
    micro_near(
      [b.policy_loss, b.critic_loss, b.imagined_reward, b.imagined_survival],
      [a.policy_loss, a.critic_loss, a.imagined_reward, a.imagined_survival],
      label,
    )
    actor_snapshot_test_state(candidate, baseline, label)
  }
  let count = candidate.critic.norm.count
  let a = baseline.update_policy(policy, train_critic=false)
  let b = candidate.update_policy(policy, train_critic=false)
  assert_eq(a.critic_updates, 0)
  assert_eq(b.critic_updates, 0)
  assert_eq(candidate.critic.norm.count, count)
  micro_near(
    [b.policy_loss, b.imagined_reward, b.imagined_survival],
    [a.policy_loss, a.imagined_reward, a.imagined_survival],
    "snapshot actor-only tail",
  )
  actor_snapshot_test_state(
    candidate,
    baseline,
    "snapshot actor-only",
    train_critic=false,
  )
}

///|
test "actor norm snapshot preserves same-plan full and split H32 GAE Adam and normalizer updates" {
  guard actor_snapshot_test_backend() is Some((backend, device)) else { return }
  for microbatch in [0, 2] {
    for reuse_critic in [false, true] {
      actor_snapshot_test_learner(backend, device, 4, microbatch, reuse_critic)
    }
  }
}

///|
test "actor norm snapshot shares detached statistics across eight H32 backwards" {
  guard actor_snapshot_test_backend() is Some((backend, device)) else { return }
  actor_snapshot_test_learner(backend, device, 8, 1, false)
}
