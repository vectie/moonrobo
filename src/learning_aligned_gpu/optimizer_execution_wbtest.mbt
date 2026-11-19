///|
fn optimizer_gate_compare(
  a : Learner,
  b : Learner,
  world_gradients~ : Bool,
  policy_gradients~ : Bool,
  critic_gradients~ : Bool,
) -> Unit raise {
  for
    (pa, pb, oa, ob, compare_gradients) in [
      (
        a.world.net.parameters(),
        b.world.net.parameters(),
        a.opt_world,
        b.opt_world,
        world_gradients,
      ),
      (
        a.policy.parameters(),
        b.policy.parameters(),
        a.opt_policy,
        b.opt_policy,
        policy_gradients,
      ),
      (
        a.critic.net.parameters(),
        b.critic.net.parameters(),
        a.opt_critic,
        b.opt_critic,
        critic_gradients,
      ),
    ] {
    assert_eq(oa.audit_metadata(), ob.audit_metadata())
    for i, parameter in pa {
      assert_eq(parameter.values(), pb[i].values())
      if compare_gradients {
        assert_eq(parameter.gradient_values(), pb[i].gradient_values())
      }
    }
    // An optimizer is populated only after its first actual update.
    if compare_gradients {
      for i in 0..<pa.length() {
        for kind in 1..<3 {
          assert_eq(
            oa.audit_tensor(i, kind~).values(),
            ob.audit_tensor(i, kind~).values(),
          )
        }
      }
    }
  }
  for i, norm in a.normalizers() {
    assert_eq(norm.count, b.normalizers()[i].count)
    assert_eq(norm.mean.values(), b.normalizers()[i].mean.values())
    assert_eq(norm.variance.values(), b.normalizers()[i].variance.values())
  }
}

///|
fn optimizer_execution_gate(stage : Ref[String]) -> Unit raise {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("optimizer gate device must be cpu or cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA optimizer gate requires tensor plugin")
    }
    println("SKIP actual learner optimizer gate: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  assert_true(backend.has_checked_norm_adam())
  if device >= 0 {
    guard backend.cuda_device_count() > 0 &&
      backend.cuda_free_bytes(device) > 17179869184L else {
      fail("actual learner optimizer gate needs CUDA and 16 GiB free")
    }
  }
  let (world, batch) = gate_batches(backend, device, 2)
  let config = { ..micro_config(), wm_batch: 4, policy_batch: 4, }
  for chunk in [0, 2] {
    for (checked, deferred) in [(true, false), (false, true), (true, true)] {
      stage.val = "construct chunk=\{chunk} checked=\{checked} deferred=\{deferred}"
      let baseline = Learner::new(
        backend,
        micro_context(backend, cuda_device=device),
        config~,
        cuda_device=device,
        world_microbatch=chunk,
        actor_microbatch=chunk,
      )
      let candidate = Learner::new(
        backend,
        micro_context(backend, cuda_device=device),
        config~,
        cuda_device=device,
        world_microbatch=chunk,
        actor_microbatch=chunk,
        optimizations={
          ..ExecutionOptimizations::default(),
          adam_checked_norm: checked,
          defer_scalar_metrics: deferred,
        },
      )
      for learner in [baseline, candidate] {
        learner.observe(
          world.s.reshape([32, 71]),
          world.actions.reshape([32, 29]),
          world.xi.reshape([32, 33]),
          world.s1.reshape([32, 71]),
        )
        learner.policy.update_normalizers(
          batch.history.reshape([40, 93]),
          batch.goals[0],
        )
      }
      for step in 0..<2 {
        stage.val = "world step=\{step} chunk=\{chunk} checked=\{checked} deferred=\{deferred}"
        let a = baseline.fit_world_batch(world)
        let b = candidate.fit_world_batch(world)
        assert_eq(a.wm_loss, b.wm_loss)
        assert_eq(a.wm_error_last, b.wm_error_last)
        assert_eq(a.wm_updates, b.wm_updates)
        optimizer_gate_compare(
          baseline,
          candidate,
          world_gradients=true,
          policy_gradients=false,
          critic_gradients=false,
        )
      }
      for step in 0..<2 {
        stage.val = "actor-critic step=\{step} chunk=\{chunk} checked=\{checked} deferred=\{deferred}"
        let a = baseline.update_policy(batch)
        let b = candidate.update_policy(batch)
        assert_eq(a.policy_loss, b.policy_loss)
        assert_eq(
          a.critic_loss.reinterpret_as_uint64(),
          b.critic_loss.reinterpret_as_uint64(),
        )
        assert_eq(a.imagined_reward, b.imagined_reward)
        assert_eq(a.imagined_survival, b.imagined_survival)
        assert_eq(a.imagined_steps, b.imagined_steps)
        assert_eq(a.critic_updates, 6)
        assert_eq(a.critic_updates, b.critic_updates)
        optimizer_gate_compare(
          baseline,
          candidate,
          world_gradients=false,
          policy_gradients=true,
          critic_gradients=true,
        )
      }
      stage.val = "actor-only chunk=\{chunk} checked=\{checked} deferred=\{deferred}"
      let critic_state = candidate.opt_critic.audit_metadata()
      let critic_parameters = candidate.critic.net
        .parameters()
        .map(p => p.values())
      let a = baseline.update_policy(batch, train_critic=false)
      let b = candidate.update_policy(batch, train_critic=false)
      assert_eq(a.policy_loss, b.policy_loss)
      assert_eq(a.critic_loss, 0.0)
      assert_eq(b.critic_loss, 0.0)
      assert_eq(a.critic_updates, 0)
      assert_eq(b.critic_updates, 0)
      optimizer_gate_compare(
        baseline,
        candidate,
        world_gradients=false,
        policy_gradients=true,
        critic_gradients=false,
      )
      assert_eq(candidate.opt_critic.audit_metadata(), critic_state)
      assert_eq(
        candidate.critic.net.parameters().map(p => p.values()),
        critic_parameters,
      )
    }
  }
  println(
    "Actual learner checked-norm/scalar-readback gate passed: 6 route/plan combinations; 8-step WM, 32-step actor, critic/remainder/noise, gradients/parameters/Adam/norms and metric bits exact",
  )
}

///|
test "actual learner checked-norm Adam and deferred metrics preserve all update paths" {
  let stage = Ref::new("startup")
  optimizer_execution_gate(stage) catch {
    @tensor.TensorError::Native(message) =>
      fail("optimizer learner gate at \{stage.val}: " + message)
    error => raise error
  }
}

///|
test "actual learner refuses unavailable checked-norm Adam before constructing networks" {
  guard @env.get_env_var("MOONROBO_TENSOR_CHECKED_NORM_LEGACY_LIBRARY")
    is Some(path) else {
    println(
      "SKIP old-plugin learner admission: set MOONROBO_TENSOR_CHECKED_NORM_LEGACY_LIBRARY",
    )
    return
  }
  let backend = @tensor.Backend::open(path)
  assert_true(!backend.has_checked_norm_adam())
  try
    Learner::new(backend, micro_context(backend), config=micro_config(), optimizations={
      ..ExecutionOptimizations::default(),
      adam_checked_norm: true,
    })
  catch {
    error =>
      assert_true(
        error.to_string().contains("checked-norm Adam explicitly requested"),
      )
  } noraise {
    _ => fail("unavailable learner optimizer route was accepted")
  }
}
