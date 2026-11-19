///|
// Keep the numerical gate identical to the other execution candidates. Reject
// non-finite values on both sides rather than allowing NaN comparisons to pass.
fn critic_graph_test_near(
  actual : Array[Double],
  expected : Array[Double],
  label : String,
) -> Unit raise {
  for values in [actual, expected] {
    guard values.all(v => !v.is_nan() && !v.is_inf()) else {
      fail("critic graph learner non-finite values: \{label}")
    }
  }
  micro_near(actual, expected, "critic graph learner \{label}")
}

///|
fn critic_graph_test_adam(
  actual : @tensor.Adam,
  expected : @tensor.Adam,
  parameters : Int32,
  step : Int32,
  label : String,
) -> Unit raise {
  assert_eq(actual.audit_metadata(), expected.audit_metadata())
  for optimizer in [actual, expected] {
    let metadata : AdamAuditMetadata = @json.from_json(
      @json.parse(optimizer.audit_metadata()),
    )
    assert_eq(metadata.parameter_count, parameters)
    assert_eq(metadata.states.length(), parameters)
    assert_true(
      metadata.states.all(s => s.present && s.step == step.to_int64()),
    )
  }
  for parameter in 0..<parameters {
    for
      (kind, name) in [
        (0, "parameter"),
        (1, "first moment"),
        (2, "second moment"),
      ] {
      critic_graph_test_near(
        actual.audit_tensor(parameter, kind~).values(),
        expected.audit_tensor(parameter, kind~).values(),
        "\{label} parameter \{parameter} \{name}",
      )
    }
  }
}

///|
fn critic_graph_test_absent_gradient(parameter : @tensor.Tensor) -> Unit raise {
  try parameter.gradient() catch {
    @tensor.TensorError::Native(message) =>
      assert_eq(message, "gradient is undefined")
    error => raise error
  } noraise {
    _ =>
      fail("actor/critic update must leave the frozen world's gradients absent")
  }
}

///|
fn critic_graph_test_trace(
  actual : CriticTrace,
  expected : CriticTrace,
) -> Unit raise {
  actual.finish()
  expected.finish()
  assert_eq(actual.records.length(), 251)
  assert_eq(actual.records.length(), expected.records.length())
  assert_eq(actual.adam_metadata, expected.adam_metadata)
  assert_eq(actual.norm_count, expected.norm_count)
  assert_eq(actual.norm_epsilon, expected.norm_epsilon)
  for i, record in actual.records {
    let other = expected.records[i]
    assert_eq(record.name, other.name)
    assert_eq(record.source_dtype, other.source_dtype)
    assert_eq(record.shape, other.shape)
    critic_graph_test_near(record.values, other.values, "trace \{record.name}")
  }
  // Verify real minibatch routing against the fixture's exact five permutation
  // epochs, not only that two implementations happen to agree with each other.
  for trace in [actual, expected] {
    let normalized = trace_test_values(trace, "bootstrap-normalized-input")
    let gae = trace_test_values(trace, "gae-targets")
    for step in 0..<20 {
      let input = trace_test_values(trace, "step-\{step}-normalized-input")
      let index = trace_test_values(trace, "step-\{step}-indices")
      let target = trace_test_values(trace, "step-\{step}-targets")
      for row in 0..<32 {
        let sample = ((step % 4 * 32 + row) * 37 + step / 4 * 17) % 128
        assert_eq(index[row], sample.to_double())
        assert_eq(
          target[row].reinterpret_as_uint64(),
          gae[sample].reinterpret_as_uint64(),
        )
        trace_test_bits(
          input[row * 914:(row + 1) * 914].to_owned(),
          normalized[sample * 914:(sample + 1) * 914].to_owned(),
        )
      }
    }
  }
}

///|
fn critic_graph_test_learner(context : Ref[String]) -> Unit raise {
  guard @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") is Some(device) else {
    println(
      "SKIP CUDA learner graph parity: explicitly set MOONROBO_OPTIMIZATION_TEST_DEVICE=cuda:0",
    )
    return
  }
  guard device == "cuda:0" else {
    fail(
      "CUDA learner graph parity requires MOONROBO_OPTIMIZATION_TEST_DEVICE=cuda:0",
    )
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    fail("explicit CUDA learner graph parity requires MOONROBO_TENSOR_LIBRARY")
  }
  let backend = @tensor.Backend::open(path)
  guard backend.has_critic_cuda_graph() && backend.cuda_device_count() > 0 else {
    fail(
      "explicit CUDA learner graph parity requires the graph extension and CUDA",
    )
  }
  guard backend.cuda_free_bytes(0) > 18253611008L else {
    fail(
      "CUDA learner graph parity requires more than 17 GiB free before allocation",
    )
  }
  let config = {
    ..micro_config(),
    wm_batch: 4,
    policy_batch: 4,
    critic_epochs: 5,
    critic_minibatches: 4,
  }
  let (world, policy) = gate_batches(backend, 0, 5)
  let input_identity = gate_input_identity(backend, world, policy)
  // Compare graph and eager within the same full/split plan. This deliberately
  // does not substitute the separate full-versus-split numerical gate.
  for size in [0, 2] {
    for normalization in [false, true] {
      context.val = "chunk=\{size} norm=\{normalization} construct eager"
      let eager = Learner::new(
        backend,
        micro_context(backend, cuda_device=0),
        config~,
        seed=1U,
        cuda_device=0,
        world_microbatch=size,
        actor_microbatch=size,
        optimizations={
          ..ExecutionOptimizations::default(),
          reuse_critic_normalization: normalization,
        },
      )
      context.val = "chunk=\{size} norm=\{normalization} construct graph"
      let graph = Learner::new(
        backend,
        micro_context(backend, cuda_device=0),
        config~,
        seed=1U,
        cuda_device=0,
        world_microbatch=size,
        actor_microbatch=size,
        optimizations={
          ..ExecutionOptimizations::default(),
          reuse_critic_normalization: normalization,
          critic_cuda_graph: true,
        },
      )
      context.val = "chunk=\{size} norm=\{normalization} prepare eager"
      trace_test_prepare(eager, world, policy)
      context.val = "chunk=\{size} norm=\{normalization} prepare graph"
      trace_test_prepare(graph, world, policy)
      for i, parameter in graph.world.net.parameters() {
        critic_graph_test_near(
          parameter.gradient_values(),
          eager.world.net.parameters()[i].gradient_values(),
          "chunk=\{size} norm=\{normalization} prepared world gradient \{i}",
        )
      }
      for iteration in 0..<4 {
        let label = "chunk=\{size} norm=\{normalization} iteration=\{iteration}"
        let (a, b) = if iteration == 0 {
          let eager_trace = CriticTrace::new(8)
          let graph_trace = CriticTrace::new(8)
          context.val = label + " eager traced update"
          let a = eager.update_policy_impl(
            policy,
            train_critic=true,
            trace=Some(eager_trace),
          )
          context.val = label + " graph traced update"
          let b = graph.update_policy_impl(
            policy,
            train_critic=true,
            trace=Some(graph_trace),
          )
          context.val = label + " compare actual traces"
          critic_graph_test_trace(graph_trace, eager_trace)
          (a, b)
        } else {
          context.val = label + " eager update"
          let a = eager.update_policy(policy)
          context.val = label + " graph update"
          let b = graph.update_policy(policy)
          (a, b)
        }
        context.val = label + " compare resulting states"
        assert_eq(a.imagined_steps, 128)
        assert_eq(b.imagined_steps, 128)
        assert_eq(a.critic_updates, 20)
        assert_eq(b.critic_updates, 20)
        critic_graph_test_near(
          [b.policy_loss, b.critic_loss, b.imagined_reward, b.imagined_survival],
          [a.policy_loss, a.critic_loss, a.imagined_reward, a.imagined_survival],
          label + " losses and imagination metrics",
        )
        for
          (name, actual, expected, actual_opt, expected_opt, step) in [
            (
              "world",
              graph.world.net.parameters(),
              eager.world.net.parameters(),
              graph.opt_world,
              eager.opt_world,
              2,
            ),
            (
              "actor",
              graph.policy.parameters(),
              eager.policy.parameters(),
              graph.opt_policy,
              eager.opt_policy,
              iteration + 1,
            ),
            (
              "critic",
              graph.critic.net.parameters(),
              eager.critic.net.parameters(),
              graph.opt_critic,
              eager.opt_critic,
              (iteration + 1) * 20,
            ),
          ] {
          assert_eq(actual.length(), expected.length())
          for i, parameter in actual {
            context.val = "\{label} compare \{name} parameter \{i}"
            critic_graph_test_near(
              parameter.values(),
              expected[i].values(),
              "\{label} \{name} parameter \{i}",
            )
            context.val = "\{label} compare \{name} gradient \{i}"
            if name == "world" {
              // Both actual actor entrypoints clear world grads before using
              // detached weights. Absence is part of this lifecycle contract.
              critic_graph_test_absent_gradient(parameter)
              critic_graph_test_absent_gradient(expected[i])
            } else {
              critic_graph_test_near(
                parameter.gradient_values(),
                expected[i].gradient_values(),
                "\{label} \{name} gradient \{i}",
              )
            }
          }
          context.val = "\{label} compare \{name} Adam"
          critic_graph_test_adam(
            actual_opt,
            expected_opt,
            actual.length(),
            step,
            "\{label} \{name}",
          )
        }
        for i, actual in graph.normalizers() {
          let expected = eager.normalizers()[i]
          assert_eq(actual.count, expected.count)
          critic_graph_test_near(
            actual.mean.values(),
            expected.mean.values(),
            "\{label} normalizer \{i} mean",
          )
          critic_graph_test_near(
            actual.variance.values(),
            expected.variance.values(),
            "\{label} normalizer \{i} variance",
          )
        }
        assert_eq(graph.critic.norm.count, ((iteration + 1) * 132).to_double())
        assert_eq(eager.graph_diagnostics.captures, 0L)
        assert_eq(eager.graph_diagnostics.replays, 0L)
        assert_eq(graph.graph_diagnostics.captures, (iteration + 1).to_int64())
        assert_eq(
          graph.graph_diagnostics.replays,
          ((iteration + 1) * 20).to_int64(),
        )
        assert_true(graph.graph_diagnostics.peak_static_bytes > 0L)
        assert_true(graph.graph_diagnostics.peak_gradient_bytes > 0L)
        assert_true(
          graph.graph_diagnostics.peak_private_pool_reserved_bytes <=
          1073741824L,
        )
        assert_eq(gate_input_identity(backend, world, policy), input_identity)
      }
    }
  }
}

///|
test "critic CUDA graph learner preserves same-plan GAE 20 Adam steps and four iterations" {
  let context = Ref::new("startup / fixture preparation")
  critic_graph_test_learner(context) catch {
    @tensor.TensorError::Native(message) =>
      fail("critic graph learner \{context.val}: \{message}")
    error => raise error
  }
}
