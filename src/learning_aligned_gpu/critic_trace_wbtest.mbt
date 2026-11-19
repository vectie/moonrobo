///|
fn trace_test_values(trace : CriticTrace, name : String) -> Array[Double] raise {
  for record in trace.records {
    if record.name == name {
      return record.values
    }
  }
  fail("missing trace fixture member \{name}")
}

///|
fn trace_test_prepare(
  learner : Learner,
  world : WorldBatch,
  policy : PolicyBatch,
) -> Unit raise {
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

///|
fn trace_test_bits(a : Array[Double], b : Array[Double]) -> Unit raise {
  assert_eq(a.length(), b.length())
  for i in 0..<a.length() {
    assert_eq(a[i].reinterpret_as_uint64(), b[i].reinterpret_as_uint64())
  }
}

///|
test "critic trace bounds reject invalid/incomplete captures" {
  for rows in [0, 257] {
    try CriticTrace::new(rows) catch {
      _ => ()
    } noraise {
      _ => fail("invalid row bound accepted")
    }
  }
  for shape in [[133, 914], [2147483647, 2], [-1], [0], [1, 1, 1]] {
    try critic_trace_count(shape) catch {
      _ => ()
    } noraise {
      _ => fail("invalid trace shape accepted")
    }
  }
  assert_eq(critic_trace_count([132, 914]), 120648)
  assert_eq(critic_trace_count([]), 1)
  try CriticTrace::new(8).finish() catch {
    _ => ()
  } noraise {
    _ => fail("incomplete trace accepted")
  }
}

///|
test "actual critic trace preserves full and split CPU updates and actual permutation inputs" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP critic trace CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let config = {
    ..micro_config(),
    wm_batch: 4,
    policy_batch: 4,
    critic_epochs: 5,
    critic_minibatches: 4,
  }
  let (world, policy) = gate_batches(backend, -1, 5)
  for size in [0, 2] {
    let plain = Learner::new(
      backend,
      micro_context(backend),
      config~,
      seed=1U,
      world_microbatch=size,
      actor_microbatch=size,
    )
    let observed = Learner::new(
      backend,
      micro_context(backend),
      config~,
      seed=1U,
      world_microbatch=size,
      actor_microbatch=size,
    )
    trace_test_prepare(plain, world, policy)
    trace_test_prepare(observed, world, policy)
    let trace = CriticTrace::new(8)
    let before = gate_input_identity(backend, world, policy)
    let a = plain.update_policy(policy)
    let b = observed.update_policy_impl(
      policy,
      train_critic=true,
      trace=Some(trace),
    )
    trace.finish()
    assert_eq(gate_input_identity(backend, world, policy), before)
    assert_eq(
      plain.shared_state_digest().to_json(),
      observed.shared_state_digest().to_json(),
    )
    trace_test_bits(
      [a.policy_loss, a.critic_loss, a.imagined_reward, a.imagined_survival],
      [b.policy_loss, b.critic_loss, b.imagined_reward, b.imagined_survival],
    )
    assert_eq(a.critic_updates, 20)
    assert_eq(b.critic_updates, 20)
    for
      pair in [
        (plain.policy.parameters(), observed.policy.parameters()),
        (plain.critic.net.parameters(), observed.critic.net.parameters()),
      ] {
      for i in 0..<pair.0.length() {
        assert_eq(
          tensor_state_digest(pair.0[i].gradient()).to_json(),
          tensor_state_digest(pair.1[i].gradient()).to_json(),
        )
      }
    }
    assert_eq(trace.records.length(), 251)
    assert_true(trace.used_values < 1048576)
    let normalized = trace_test_values(trace, "bootstrap-normalized-input")
    let targets = trace_test_values(trace, "gae-targets")
    for step in 0..<20 {
      let actual = trace_test_values(trace, "step-\{step}-normalized-input")
      let index = trace_test_values(trace, "step-\{step}-indices")
      let target = trace_test_values(trace, "step-\{step}-targets")
      for row in 0..<32 {
        let sample = ((step % 4 * 32 + row) * 37 + step / 4 * 17) % 128
        assert_eq(index[row], sample.to_double())
        assert_eq(
          target[row].reinterpret_as_uint64(),
          targets[sample].reinterpret_as_uint64(),
        )
        trace_test_bits(
          actual[row * 914:(row + 1) * 914].to_owned(),
          normalized[sample * 914:(sample + 1) * 914].to_owned(),
        )
      }
      if step > 0 {
        for field in ["weight", "m", "v"] {
          trace_test_bits(
            trace_test_values(trace, "step-\{step}-before-\{field}"),
            trace_test_values(trace, "step-\{step - 1}-after-\{field}"),
          )
        }
      }
    }
    trace_test_bits(
      trace_test_values(trace, "step-19-after-weight"),
      observed.critic.net.parameters()[0].narrow(1, 146, 2).values(),
    )
    trace_test_bits(
      trace_test_values(trace, "step-19-after-gradient"),
      observed.critic.net.parameters()[0].gradient().narrow(1, 146, 2).values(),
    )
    assert_true(!trace.records.any(r => r.name == "step-0-before-m"))
    // One-use and total-value admission fail before copying any new values.
    try trace.bind(observed, 4, true) catch {
      _ => ()
    } noraise {
      _ => fail("trace reuse accepted")
    }
    let limited = CriticTrace::new(8)
    limited.used_values = 1048576
    try limited.capture("exceeds-budget", policy.previous, [4, 29]) catch {
      _ => ()
    } noraise {
      _ => fail("trace budget exceeded")
    }
    assert_eq(limited.records.length(), 0)
  }
}
