///|
// This gate is CPU-only. It tests the identical high-level diagnostic branches
// with bounded structural recording; it does not certify NVTX/CUDA capture.
fn diagnostic_test_backend() -> @tensor.Backend? raise {
  guard @env.get_env_var("MOONROBO_OPERATOR_DIAGNOSTIC_TEST") == Some("1") else {
    println(
      "SKIP operator diagnostic fixture: set MOONROBO_OPERATOR_DIAGNOSTIC_TEST=1",
    )
    return None
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    fail(
      "explicit operator diagnostic fixture requires a CPU-capable diagnostic plugin",
    )
  }
  Some(@tensor.Backend::open(path))
}

///|
fn diagnostic_test_field(value : Json, key : String) -> Json raise {
  guard value is Object(fields) && fields.get(key) is Some(found) else {
    fail("missing diagnostic report field " + key)
  }
  found
}

///|
fn diagnostic_test_ranges(report : Json) -> Array[Json] raise {
  guard diagnostic_test_field(report, "ranges") is Array(ranges) else {
    fail("diagnostic ranges must be an array")
  }
  ranges
}

///|
fn diagnostic_test_count(ranges : Array[Json], label : String) -> Int32 raise {
  let mut count = 0
  for entry in ranges {
    if diagnostic_test_field(entry, "label") == Json(label) {
      count += 1
    }
  }
  count
}

///|
fn diagnostic_test_state(actual : Learner, expected : Learner) -> Unit raise {
  for
    (a, b, gradient) in [
      (actual.world.net.parameters(), expected.world.net.parameters(), false),
      (actual.policy.parameters(), expected.policy.parameters(), true),
      (actual.critic.net.parameters(), expected.critic.net.parameters(), true),
    ] {
    assert_eq(a.length(), b.length())
    for i, parameter in a {
      assert_eq(parameter.values(), b[i].values())
      if gradient {
        assert_eq(parameter.gradient_values(), b[i].gradient_values())
      } else {
        critic_graph_test_absent_gradient(parameter)
        critic_graph_test_absent_gradient(b[i])
      }
    }
  }
  for
    (a, b, count) in [
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
    assert_eq(a.audit_metadata(), b.audit_metadata())
    for p in 0..<count {
      for kind in 0..<3 {
        assert_eq(
          a.audit_tensor(p, kind~).values(),
          b.audit_tensor(p, kind~).values(),
        )
      }
    }
  }
  for i, norm in actual.normalizers() {
    let other = expected.normalizers()[i]
    assert_eq(norm.count, other.count)
    assert_eq(norm.mean.values(), other.mean.values())
    assert_eq(norm.variance.values(), other.variance.values())
  }
}

///|
test "structural diagnostics preserve same-plan H32 actor critic state and label counts" {
  guard diagnostic_test_backend() is Some(backend) else { return }
  let (world, policy) = gate_batches(backend, -1, 5)
  let config = {
    ..micro_config(),
    wm_batch: 4,
    policy_batch: 4,
    critic_epochs: 5,
    critic_minibatches: 4,
  }
  for (microbatch, reuse) in [(0, false), (2, false), (2, true)] {
    let make = () => {
      Learner::new(
        backend,
        micro_context(backend),
        config~,
        actor_microbatch=microbatch,
        optimizations={
          ..ExecutionOptimizations::default(),
          reuse_geometry: reuse,
          reuse_critic_normalization: reuse,
          actor_norm_snapshot: reuse,
          body_orientation_batched: reuse,
        },
      )
    }
    let baseline = make()
    let candidate = make()
    assert_false(@tensor.operator_diagnostics_enabled())
    assert_false(@tensor.operator_diagnostic_iteration_selected(41))
    for learner in [baseline, candidate] {
      learner.observe(
        world.s.reshape([32, 71]),
        world.actions.reshape([32, 29]),
        world.xi.reshape([32, 33]),
        world.s1.reshape([32, 71]),
      )
      learner.policy.update_normalizers(
        policy.history.reshape([40, 93]),
        policy.goals[0],
      )
      for _ in 0..<2 {
        ignore(learner.fit_world_batch(world))
      }
    }
    let expected = baseline.update_policy(policy)
    @tensor.configure_operator_diagnostics(
      backend,
      cuda_device=-1,
      iteration=41,
      structural_only=true,
      max_ranges=16384,
    )
    defer (@tensor.clear_operator_diagnostics() catch { _ => () })
    assert_false(@tensor.operator_diagnostic_iteration_selected(40))
    assert_true(@tensor.operator_diagnostic_iteration_selected(41))
    assert_eq(@tensor.operator_diagnostic_iteration_begin(40), 0L)
    assert_false(@tensor.operator_diagnostics_enabled())
    let window = @tensor.operator_diagnostic_iteration_begin(41)
    errdefer @tensor.operator_diagnostic_iteration_cancel(window)
    assert_true(window != 0L && @tensor.operator_diagnostics_enabled())
    assert_false(@tensor.operator_diagnostic_iteration_selected(41))
    let actual = candidate.update_policy(policy)
    @tensor.operator_diagnostic_iteration_end(window)
    assert_false(@tensor.operator_diagnostics_enabled())
    assert_eq(actual.imagined_steps, 128)
    assert_eq(actual.critic_updates, 20)
    assert_eq(
      [
        actual.policy_loss,
        actual.critic_loss,
        actual.imagined_reward,
        actual.imagined_survival,
      ],
      [
        expected.policy_loss,
        expected.critic_loss,
        expected.imagined_reward,
        expected.imagined_survival,
      ],
    )
    diagnostic_test_state(candidate, baseline)
    let report = @json.parse(@tensor.operator_diagnostics_report())
    assert_eq(diagnostic_test_field(report, "structural_only"), Json(true))
    assert_eq(
      diagnostic_test_field(report, "automatic_aten_autograd_nvtx"),
      Json(false),
    )
    assert_eq(diagnostic_test_field(report, "cuda_events_created"), Json(0))
    assert_eq(diagnostic_test_field(report, "capture_verified"), Json(false))
    assert_eq(diagnostic_test_field(report, "completed"), Json(true))
    assert_eq(diagnostic_test_field(report, "cancelled"), Json(false))
    assert_eq(diagnostic_test_field(report, "open_ranges"), Json(0))
    let ranges = diagnostic_test_ranges(report)
    assert_eq(
      diagnostic_test_field(report, "range_count"),
      Json(ranges.length()),
    )
    for i, entry in ranges {
      assert_eq(diagnostic_test_field(entry, "id"), Json(i + 1))
      assert_eq(diagnostic_test_field(entry, "ended"), Json(true))
      assert_eq(diagnostic_test_field(entry, "cancelled"), Json(false))
      guard diagnostic_test_field(entry, "parent") is Number(parent) else {
        fail("invalid diagnostic parent")
      }
      assert_true(parent >= 0.0 && parent < (i + 1).to_double())
    }
    let chunks = if microbatch == 0 { 1 } else { 2 }
    for t in 0..<32 {
      assert_eq(diagnostic_test_count(ranges, "diag.actor.step.\{t}"), chunks)
    }
    for
      label in [
        "diag.actor.rollout", "diag.actor.reward.batch", "diag.actor.soft_failure",
        "diag.actor.return", "diag.critic.tail", "diag.actor.backward", "diag.actor.critic_features",
      ] {
      assert_eq(diagnostic_test_count(ranges, label), chunks)
    }
    assert_eq(diagnostic_test_count(ranges, "diag.policy.encoder"), chunks * 32)
    assert_eq(diagnostic_test_count(ranges, "diag.policy.decoder"), chunks * 32)
    assert_eq(diagnostic_test_count(ranges, "diag.world.mlp"), chunks * 32)
    assert_eq(
      diagnostic_test_count(ranges, "diag.network.ln.expanded"),
      chunks * 64,
    )
    assert_eq(diagnostic_test_count(ranges, "diag.network.ln.native"), 0)
    assert_eq(
      diagnostic_test_count(ranges, "diag.network.linear"),
      chunks * 226 + 42,
    )
    assert_eq(
      diagnostic_test_count(ranges, "diag.network.activation"),
      chunks * 129 + 21,
    )
    assert_eq(diagnostic_test_count(ranges, "diag.actor.adam"), 1)
    for
      label in [
        "diag.critic.normalizer", "diag.critic.bootstrap", "diag.critic.gae",
      ] {
      assert_eq(diagnostic_test_count(ranges, label), 1)
    }
    for epoch in 0..<5 {
      for minibatch in 0..<4 {
        assert_eq(
          diagnostic_test_count(
            ranges,
            "diag.critic.epoch\{epoch}.minibatch\{minibatch}",
          ),
          1,
        )
      }
    }
    for
      label in [
        "diag.critic.gather_and_forward", "diag.critic.target_gather", "diag.critic.loss",
        "diag.critic.backward", "diag.critic.adam",
      ] {
      assert_eq(diagnostic_test_count(ranges, label), 20)
    }
    assert_eq(
      diagnostic_test_count(ranges, "diag.geometry.robot_fk"),
      chunks * (if reuse { 2 } else { 3 }),
    )
    assert_eq(
      diagnostic_test_count(ranges, "diag.geometry.reference_fk"),
      chunks * (if reuse { 2 } else { 3 }),
    )
    for
      label in [
        "diag.reward.body_position.error", "diag.reward.body_linvel.error", "diag.reward.body_angvel.error",
      ] {
      assert_eq(diagnostic_test_count(ranges, label), chunks * 14)
    }
    assert_eq(
      diagnostic_test_count(ranges, "diag.reward.body_orientation.error"),
      if reuse {
        0
      } else {
        chunks * 14
      },
    )
    assert_eq(
      diagnostic_test_count(
        ranges, "diag.reward.body_orientation.batched_error",
      ),
      if reuse {
        chunks
      } else {
        0
      },
    )
    for
      label in [
        "diag.reward.root_position.error", "diag.reward.root_orientation.error",
        "diag.reward.tracking_scores", "diag.reward.action_rate", "diag.reward.joint_limit",
      ] {
      assert_eq(diagnostic_test_count(ranges, label), chunks)
    }
    assert_eq(diagnostic_test_count(ranges, "diag.world.step.0"), 0)
    @tensor.clear_operator_diagnostics()
  }
}

///|
test "network diagnostic ranges unwind when a native tensor operation fails" {
  guard diagnostic_test_backend() is Some(backend) else { return }
  let network = Network::new(
    backend,
    [3, 4, 2],
    @numeric.Rng::new(71U),
    layer_norm=true,
  )
  let invalid = micro_upload(backend, [2, 5], Array::make(10, 0.2))
  @tensor.configure_operator_diagnostics(
    backend,
    cuda_device=-1,
    iteration=41,
    structural_only=true,
    max_ranges=16,
  )
  defer (@tensor.clear_operator_diagnostics() catch { _ => () })
  let window = @tensor.operator_diagnostic_iteration_begin(41)
  errdefer @tensor.operator_diagnostic_iteration_cancel(window)
  try network.forward(invalid) catch {
    @tensor.TensorError::Native(message) => assert_true(message.length() > 0)
    error => raise error
  } noraise {
    _ => fail("invalid matrix unexpectedly succeeded")
  }
  let report = @json.parse(@tensor.operator_diagnostics_report())
  assert_eq(diagnostic_test_field(report, "open_ranges"), Json(0))
  let ranges = diagnostic_test_ranges(report)
  assert_eq(ranges.length(), 2)
  for entry in ranges {
    assert_eq(diagnostic_test_field(entry, "ended"), Json(true))
    assert_eq(diagnostic_test_field(entry, "cancelled"), Json(true))
  }
  @tensor.operator_diagnostic_iteration_cancel(window)
  let cancelled = @json.parse(@tensor.operator_diagnostics_report())
  assert_eq(diagnostic_test_field(cancelled, "cancelled"), Json(true))
  assert_eq(diagnostic_test_field(cancelled, "completed"), Json(false))
  assert_false(@tensor.operator_diagnostics_enabled())
}
