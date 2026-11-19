///|
fn micro_upload(
  backend : @tensor.Backend,
  shape : Array[Int32],
  values : Array[Double],
) -> @tensor.Tensor raise {
  backend.from_values(
    shape,
    values,
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
}

///|
fn micro_context(
  backend : @tensor.Backend,
  cuda_device~ : Int32 = -1,
) -> @geometry.Context raise {
  let kin : @aligned.Kinematics = {
    bodies: [
      {
        name: "root",
        parent: -1,
        joint: -1,
        axis: [0.0, 0.0, 1.0],
        offset_p: [0.0, 0.0, 0.0],
        offset_rotation: @aligned.identity(),
        pivot: [0.0, 0.0, 0.0],
        qref: 0.0,
      },
    ],
    tracked: Array::make(14, 0),
    q_lo: Array::make(29, -2.0),
    q_hi: Array::make(29, 2.0),
  }
  @geometry.Context::new(backend, kin, cuda_device)
}

///|
fn micro_config() -> @aligned.LearnerConfig {
  {
    ..@aligned.LearnerConfig::default(),
    wm_hidden: [8, 8],
    policy_hidden: [8],
    critic_hidden: [8],
    policy_batch: 5,
    wm_batch: 5,
    wm_batches: 1,
    critic_epochs: 2,
    critic_minibatches: 3,
    observation_noise: true,
  }
}

///|
fn micro_base() -> Array[Double] {
  @aligned.flatten_state({
    p: [0.0, 0.0, 0.75],
    rotation: @aligned.identity(),
    v: [0.0, 0.0, 0.0],
    w: [0.0, 0.0, 0.0],
    q: @aligned.default_joint_positions(),
    qd: Array::make(29, 0.0),
  })
}

///|
fn micro_world_batch(backend : @tensor.Backend) -> WorldBatch raise {
  let states = []
  let next = []
  let xis = []
  let actions = []
  let masks = []
  for b in 0..<5 {
    for t in 0..<8 {
      let row = micro_base()
      row[0] = 0.004 * b.to_double()
      row[13] += 0.002 * (b + 1).to_double() * t.to_double()
      row[42] = 0.1 * (b + 1).to_double()
      states.append(row)
      let later = row.copy()
      later[13] += 0.002 * (b + 1).to_double()
      later[0] += 0.001 * (b + 1).to_double()
      next.append(later)
      let xi = Array::make(33, 0.0)
      xi[0] = 0.75 + 0.02 * b.to_double()
      xis.append(xi)
      actions.append(
        Array::makei(29, j => 0.01 * ((b + t + j) % 7 - 3).to_double()),
      )
      // Unequal final-step mask counts, including an all-masked final chunk.
      masks.push(if b == 4 || (b % 2 == 1 && t >= 4) { 0.0 } else { 1.0 })
    }
  }
  {
    s: micro_upload(backend, [5, 8, 71], states),
    s1: micro_upload(backend, [5, 8, 71], next),
    actions: micro_upload(backend, [5, 8, 29], actions),
    xi: micro_upload(backend, [5, 8, 33], xis),
    mask: micro_upload(backend, [5, 8], masks),
  }
}

///|
fn micro_observe(learner : Learner, batch : WorldBatch) -> Unit raise {
  learner.observe(
    batch.s.reshape([40, 71]),
    batch.actions.reshape([40, 29]),
    batch.xi.reshape([40, 33]),
    batch.s1.reshape([40, 71]),
  )
}

///|
fn micro_near(
  actual : Array[Double],
  expected : Array[Double],
  label : String,
  absolute~ : Double = 2.0e-6,
  relative~ : Double = 2.0e-4,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    let tolerance = absolute + relative * expected[i].abs()
    guard @numeric.finite(actual[i]) &&
      (actual[i] - expected[i]).abs() <= tolerance else {
      fail(
        "\{label}[\{i}]: \{actual[i]} vs \{expected[i]}, tolerance \{tolerance}",
      )
    }
  }
}

///|
fn micro_compare_adam(
  a : @tensor.Adam,
  b : @tensor.Adam,
  count : Int32,
) -> Unit raise {
  assert_eq(a.audit_metadata(), b.audit_metadata())
  for p in 0..<count {
    for kind in 0..<3 {
      micro_near(
        a.audit_tensor(p, kind~).values(),
        b.audit_tensor(p, kind~).values(),
        "Adam \{p}/\{kind}",
      )
    }
  }
}

///|
fn micro_detached_scalar(value : @tensor.Tensor) -> Double raise {
  assert_eq(value.shape(), [])
  assert_eq(value.dtype(), @tensor.Float32)
  let values = value.values()
  assert_eq(values.length(), 1)
  assert_true(@numeric.finite(values[0]))
  // Reject a retained-but-already-consumed graph as well as a live graph. The
  // LibTorch error must specifically say this scalar does not require gradients.
  try value.backward() catch {
    @tensor.TensorError::Native(message) =>
      assert_true(message.contains("does not require grad"))
  } noraise {
    _ => fail("microbatch metric retained an autograd graph")
  }
  values[0]
}

///|
test "critic metric readback bounds 256 scalars and preserves sum across flushes" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP microbatch CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  for count in [0, 20, 255, 256, 257, 258, 259, 511, 512, 513, 1025] {
    let metrics = CriticLossMetrics::new(backend)
    let mut expected = 0.0
    for i in 0..<count {
      // All values are exactly representable in FP32. The cancellation just
      // after the first flush distinguishes sequential CPU addition from
      // accumulating each block from zero and then adding a block subtotal.
      let value = match i {
        0 => 1.0
        256 => 1152921504606846976.0
        257 => -1152921504606846976.0
        258 => 3.0
        _ => 0.0
      }
      let scalar = backend.from_values(
        [],
        [value],
        cuda_device=-1,
        requires_grad=true,
        dtype=Float32,
      )
      metrics.append(scalar)
      expected += value
      assert_eq(metrics.pending.length(), (i + 1) % 256)
      if metrics.pending.is_empty() {
        assert_eq(
          metrics.total.reinterpret_as_uint64(),
          expected.reinterpret_as_uint64(),
        )
      }
    }
    if !metrics.pending.is_empty() {
      ignore(micro_detached_scalar(metrics.pending[0]))
    }
    let actual = metrics.finish()
    assert_eq(metrics.pending.length(), 0)
    assert_eq(actual.reinterpret_as_uint64(), expected.reinterpret_as_uint64())
    // Finalizing an empty or already flushed accumulator performs no stack or
    // repeated accumulation, including exact multiples of the block size.
    assert_eq(
      metrics.finish().reinterpret_as_uint64(),
      actual.reinterpret_as_uint64(),
    )
  }
}

///|
test "microbatch metrics stay detached and packed readback preserves scalar bits" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP microbatch CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let learner = Learner::new(
    backend,
    micro_context(backend),
    config=micro_config(),
  )
  let world = micro_world_batch(backend)
  micro_observe(learner, world)
  let world_metrics = []
  let immediate_world = []
  learner.opt_world.zero_grad()
  for start in [0, 2, 4] {
    let (loss, last, count) = learner.backward_world_chunk(
      world_batch_slice(world, start, (5 - start).min(2)),
      5,
    )
    for value in [loss, last, count] {
      immediate_world.push(micro_detached_scalar(value))
      world_metrics.push(value)
    }
  }
  // The final single sample is fully masked. Earlier metric storage survives
  // later backwards unchanged, without retaining any window's activation graph.
  assert_eq(immediate_world[6:], [0.0, 0.0, 0.0][:])
  let packed_world = backend.stack(world_metrics).values()
  for i in 0..<packed_world.length() {
    assert_eq(
      packed_world[i].reinterpret_as_uint64(),
      immediate_world[i].reinterpret_as_uint64(),
    )
  }
  for _ in 0..<2 {
    ignore(learner.fit_world_batch(world))
  }
  let policy = micro_policy_batch(backend)
  learner.policy.update_normalizers(
    policy.history.reshape([50, 93]),
    policy.goals[0],
  )
  learner.opt_policy.zero_grad()
  let frozen_world = learner.world.net.frozen()
  let frozen_critic = learner.critic.net.frozen()
  let actor_metrics = []
  let immediate_actor = []
  for start in [0, 2, 4] {
    let chunk = learner.backward_actor_chunk(
      policy_batch_slice(policy, start, (5 - start).min(2)),
      5,
      frozen_world,
      frozen_critic,
      true,
    )
    for value in [chunk.loss, chunk.weighted_reward_sum, chunk.survival_sum] {
      immediate_actor.push(micro_detached_scalar(value))
      actor_metrics.push(value)
    }
  }
  let packed_actor = backend.stack(actor_metrics).values()
  for i in 0..<packed_actor.length() {
    assert_eq(
      packed_actor[i].reinterpret_as_uint64(),
      immediate_actor[i].reinterpret_as_uint64(),
    )
  }
}

///|
test "world microbatches preserve full-window masked loss gradients and Adam steps" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP microbatch CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let context = micro_context(backend)
  let config = micro_config()
  let full = Learner::new(backend, context, config~)
  let split = Learner::new(backend, context, config~, world_microbatch=2)
  assert_eq(full.batch_execution(), {
    world_microbatch: 0,
    actor_microbatch: 0,
  })
  assert_eq(split.batch_execution(), {
    world_microbatch: 2,
    actor_microbatch: 0,
  })
  let batch = micro_world_batch(backend)
  micro_observe(full, batch)
  micro_observe(split, batch)
  for _ in 0..<2 {
    let a = full.fit_world_batch(batch)
    let b = split.fit_world_batch(batch)
    assert_eq(a.wm_updates, 1)
    assert_eq(b.wm_updates, 1)
    micro_near(
      [a.wm_loss, a.wm_error_last],
      [b.wm_loss, b.wm_error_last],
      "WM metrics",
    )
    for i, parameter in full.world.net.parameters() {
      micro_near(
        parameter.gradient_values(),
        split.world.net.parameters()[i].gradient_values(),
        "WM gradient \{i}",
      )
    }
    micro_compare_adam(
      full.opt_world,
      split.opt_world,
      full.world.net.parameters().length(),
    )
  }
  assert_eq(
    full.checkpoint_metadata().normalizers.to_json(),
    split.checkpoint_metadata().normalizers.to_json(),
  )
}

///|
test "microbatch controls reject invalid sizes without changing logical caps" {
  let config = micro_config()
  for
    plan in [
      { world_microbatch: -1, actor_microbatch: 0, },
      { world_microbatch: 0, actor_microbatch: -1, },
      { world_microbatch: 6, actor_microbatch: 0, },
      { world_microbatch: 0, actor_microbatch: 6, },
    ] {
    try plan.validate(config) catch {
      _ => ()
    } noraise {
      _ => fail("invalid microbatch accepted")
    }
  }
  ({ world_microbatch: 5, actor_microbatch: 5, } : BatchExecutionPlan).validate(
    config,
  )
}

///|
fn micro_policy_batch(backend : @tensor.Backend) -> PolicyBatch raise {
  let rows = []
  let xis = []
  for b in 0..<5 {
    let row = micro_base()
    row[0] += 0.015 * b.to_double()
    row[2] -= 0.045 * b.to_double()
    row[13] += 0.01 * b.to_double()
    rows.append(row)
    let xi = Array::make(33, 0.0)
    xi[0] = 0.75 + 0.02 * b.to_double()
    xis.append(xi)
  }
  let refs = []
  let goals = []
  let noise = []
  for t in 0..<33 {
    let reference = []
    for b in 0..<5 {
      let row = micro_base()
      row[0] += 0.001 * t.to_double() + 0.01 * b.to_double()
      row[13] += 0.002 * (b + 1).to_double() * t.to_double()
      reference.append(row)
    }
    refs.push(
      @geometry.State::from_flat71(
        backend,
        micro_upload(backend, [5, 71], reference),
      ),
    )
    goals.push(
      micro_upload(
        backend,
        [5, 730],
        Array::makei(5 * 730, i => {
          0.01 * (i % 11 - 5).to_double() +
          0.002 * t.to_double() +
          0.003 * (i / 730).to_double()
        }),
      ),
    )
    if t < 32 {
      noise.push(
        micro_upload(
          backend,
          [5, 93],
          Array::makei(5 * 93, i => 0.0003 * ((i + t) % 7 - 3).to_double()),
        ),
      )
    }
  }
  {
    state: micro_upload(backend, [5, 71], rows),
    xi: micro_upload(backend, [5, 33], xis),
    previous: micro_upload(
      backend,
      [5, 29],
      Array::makei(145, i => 0.005 * (i % 7 - 3).to_double()),
    ),
    history: micro_upload(
      backend,
      [5, 10, 93],
      Array::makei(4650, i => 0.02 * (i % 17 - 8).to_double()),
    ),
    references: refs,
    reference_fk: None,
    goals,
    step_noise: noise,
    critic_orders: Array::makei(2, epoch => {
      backend.from_values(
        [160],
        Array::makei(160, i => ((i * 37 + epoch * 17) % 160).to_double()),
        cuda_device=-1,
        requires_grad=false,
        dtype=Int64,
      )
    }),
  }
}

///|
test "actor microbatches preserve full horizon tail GAE noise permutations and Adam schedule" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP microbatch CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let context = micro_context(backend)
  let config = micro_config()
  let full = Learner::new(backend, context, config~)
  let split = Learner::new(backend, context, config~, actor_microbatch=2)
  let world = micro_world_batch(backend)
  for learner in [full, split] {
    micro_observe(learner, world)
    // Nonzero fitted head makes imagined state depend on policy action.
    for _ in 0..<2 {
      ignore(learner.fit_world_batch(world))
    }
  }
  let differentiable = backend.from_values(
    [1, 133],
    Array::makei(133, i => 0.01 * (i % 7 - 3).to_double()),
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  full.world
  .delta(differentiable, frozen_net=full.world.net.frozen())
  .square()
  .sum()
  .backward()
  assert_true(
    differentiable.gradient_values()[71:100].any(v => v.abs() > 1.0e-12),
  )
  let batch = micro_policy_batch(backend)
  for learner in [full, split] {
    learner.policy.update_normalizers(
      batch.history.reshape([50, 93]),
      batch.goals[0],
    )
  }
  let world_parameters = full.world.net.parameters().map(p => p.values())
  for iteration in 0..<2 {
    let a = full.update_policy(batch)
    let b = split.update_policy(batch)
    assert_eq(a.imagined_steps, 160)
    assert_eq(b.imagined_steps, 160)
    assert_eq(a.critic_updates, 6)
    assert_eq(b.critic_updates, 6)
    micro_near(
      [a.policy_loss, a.critic_loss, a.imagined_reward, a.imagined_survival],
      [b.policy_loss, b.critic_loss, b.imagined_reward, b.imagined_survival],
      "actor metrics",
    )
    for i, parameter in full.policy.parameters() {
      micro_near(
        parameter.gradient_values(),
        split.policy.parameters()[i].gradient_values(),
        "actor gradient \{i}",
      )
    }
    micro_compare_adam(
      full.opt_policy,
      split.opt_policy,
      full.policy.parameters().length(),
    )
    micro_compare_adam(
      full.opt_critic,
      split.opt_critic,
      full.critic.net.parameters().length(),
    )
    assert_eq(full.critic.norm.count, (165 * (iteration + 1)).to_double())
    assert_eq(split.critic.norm.count, full.critic.norm.count)
    for i, norm in full.normalizers() {
      micro_near(
        norm.mean.values(),
        split.normalizers()[i].mean.values(),
        "norm mean \{i}",
      )
      micro_near(
        norm.variance.values(),
        split.normalizers()[i].variance.values(),
        "norm variance \{i}",
      )
    }
    assert_eq(
      full.world.net.parameters().map(p => p.values()),
      world_parameters,
    )
    assert_eq(
      split.world.net.parameters().map(p => p.values()),
      world_parameters,
    )
  }
  let critic_before = full.critic.net.parameters().map(p => p.values())
  let split_critic_before = split.critic.net.parameters().map(p => p.values())
  let a = full.update_policy(batch, train_critic=false)
  let b = split.update_policy(batch, train_critic=false)
  micro_near(
    [a.policy_loss, a.imagined_reward, a.imagined_survival],
    [b.policy_loss, b.imagined_reward, b.imagined_survival],
    "actor-only still includes tail",
  )
  assert_eq(a.critic_updates, 0)
  assert_eq(b.critic_updates, 0)
  assert_eq(full.critic.norm.count, 330.0)
  assert_eq(split.critic.norm.count, 330.0)
  assert_eq(full.critic.net.parameters().map(p => p.values()), critic_before)
  assert_eq(
    split.critic.net.parameters().map(p => p.values()),
    split_critic_before,
  )
  micro_compare_adam(
    full.opt_policy,
    split.opt_policy,
    full.policy.parameters().length(),
  )
}
