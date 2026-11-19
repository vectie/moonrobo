///|
fn near(
  actual : Array[Double],
  expected : Array[Double],
  tolerance~ : Double = 2.0e-6,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    guard (actual[i] - expected[i]).abs() <= tolerance else {
      fail("tensor parity mismatch at \{i}: \{actual[i]} vs \{expected[i]}")
    }
  }
}

///|
fn upload(
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
test "device network initialization forward and norms match scalar numerical port" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP GPU learner CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  for activation in [@aligned.Elu, @aligned.Silu] {
    let scalar = @aligned.Network::new(
      [3, 5, 2],
      @numeric.Rng::new(7U),
      activation~,
      layer_norm=true,
    )
    let net = @learning_aligned_gpu.Network::new(
      backend,
      [3, 5, 2],
      @numeric.Rng::new(7U),
      activation~,
      layer_norm=true,
    )
    let input = [[1.0, -0.5, 0.2], [-0.1, 0.3, 0.5]]
    let values = []
    let expected = []
    for row in input {
      values.append(row)
      expected.append(scalar.predict(row))
    }
    near(net.forward(upload(backend, [2, 3], values)).values(), expected)
    let flattened = []
    for parameter in net.parameters() {
      flattened.append(parameter.values())
    }
    near(flattened, scalar.parameters, tolerance=5.0e-8)
    let differentiable = backend.from_values(
      [2, 3],
      values,
      cuda_device=-1,
      requires_grad=true,
      dtype=Float32,
    )
    net.frozen().forward(differentiable).square().sum().backward()
    assert_true(differentiable.gradient_values().any(v => v.abs() > 1.0e-8))
    for parameter in net.parameters() {
      try parameter.gradient_values() catch {
        @tensor.TensorError::Native(_) => ()
      } noraise {
        _ => fail("frozen network must not accumulate parameter gradients")
      }
    }
  }
  let norm = @learning_aligned_gpu.RunningNorm::new(backend, 3)
  let scalar = @aligned.RunningNorm::new(3)
  let rows = [[1.0, 2.0, 3.0], [2.0, 4.0, 6.0]]
  norm.update(upload(backend, [2, 3], [1.0, 2.0, 3.0, 2.0, 4.0, 6.0]))
  scalar.update(rows)
  norm.update(upload(backend, [1, 3], [0.0, 0.0, 0.0]))
  scalar.update([[0.0, 0.0, 0.0]])
  let (mean, variance, count) = scalar.snapshot()
  near(norm.mean.values(), mean)
  near(norm.variance.values(), variance)
  assert_eq(norm.count, count)
  let rewards = [[0.1, 0.2], [0.05, 0.1], [0.3, 0.15]]
  let values = [[0.4, 0.2], [0.2, 0.3], [0.1, 0.25], [0.2, 0.1]]
  let failures = [[0.0, 0.1], [0.2, 0.0], [0.0, 1.0]]
  let expected = @aligned.lambda_returns(rewards, values, failures)
  let flattened = []
  for row in expected {
    flattened.append(row)
  }
  near(
    @learning_aligned_gpu.lambda_returns(
      backend,
      upload(backend, [3, 2], [0.1, 0.2, 0.05, 0.1, 0.3, 0.15]),
      upload(backend, [4, 2], [0.4, 0.2, 0.2, 0.3, 0.1, 0.25, 0.2, 0.1]),
      upload(backend, [3, 2], [0.0, 0.1, 0.2, 0.0, 0.0, 1.0]),
    ).values(),
    flattened,
  )
}

///|
/// This is a tiny offline numerical fixture, not a physics/training result.
test "native tensor learner executes 8 step WM and 32 step actor with imagined critic" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP GPU learner CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
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
  let context = @geometry.Context::new(backend, kin, -1)
  let defaults = @aligned.LearnerConfig::default()
  let config = {
    ..defaults,
    wm_hidden: [8, 8],
    policy_hidden: [8],
    critic_hidden: [8],
    policy_batch: 2,
    wm_batch: 2,
    wm_batches: 1,
    critic_epochs: 1,
    critic_minibatches: 2,
    observation_noise: false,
  }
  let learner = @learning_aligned_gpu.Learner::new(backend, context, config~)
  let state : @aligned.State = {
    p: [0.0, 0.0, 0.75],
    rotation: @aligned.identity(),
    v: [0.0, 0.0, 0.0],
    w: [0.0, 0.0, 0.0],
    q: @aligned.default_joint_positions(),
    qd: Array::make(29, 0.0),
  }
  let base = @aligned.flatten_state(state)
  let states = []
  let next = []
  let xis = []
  for b in 0..<2 {
    for j in 0..<8 {
      let row = base.copy()
      row[13] += 0.001 * (b + 1).to_double() * j.to_double()
      states.append(row)
      let later = row.copy()
      later[13] += 0.001 * (b + 1).to_double()
      next.append(later)
      let xi = Array::make(33, 0.0)
      xi[0] = 0.75
      xis.append(xi)
    }
  }
  let s = upload(backend, [2, 8, 71], states)
  let s1 = upload(backend, [2, 8, 71], next)
  let xi = upload(backend, [2, 8, 33], xis)
  let action = upload(backend, [2, 8, 29], Array::make(2 * 8 * 29, 0.0))
  learner.observe(
    s.reshape([16, 71]),
    action.reshape([16, 29]),
    xi.reshape([16, 33]),
    s1.reshape([16, 71]),
  )
  let before = learner.world.net.parameters().map(p => p.values())
  let metrics = learner.fit_world_batch({
    s,
    s1,
    xi,
    actions: action,
    mask: upload(backend, [2, 8], Array::make(16, 1.0)),
  })
  assert_eq(metrics.wm_updates, 1)
  assert_true(metrics.wm_loss > 0.0 && metrics.wm_loss < 1000.0)
  assert_true(learner.world.net.parameters().map(p => p.values()) != before)
  let current = upload(
    backend,
    [2, 71],
    {
      let rows = base.copy()
      rows.append(base)
      rows
    },
  )
  let reference = @geometry.State::from_flat71(backend, current)
  let goal = upload(backend, [2, 730], Array::make(1460, 0.0))
  let history = upload(backend, [2, 10, 93], Array::make(1860, 0.0))
  learner.policy.update_normalizers(history.reshape([20, 93]), goal)
  let frozen = learner.world.net.parameters().map(p => p.values())
  let actor = learner.policy.parameters().map(p => p.values())
  let policy_batch : @learning_aligned_gpu.PolicyBatch = {
    state: current,
    previous: upload(backend, [2, 29], Array::make(58, 0.0)),
    xi: xi.narrow(1, 0, 1).reshape([2, 33]),
    history,
    references: Array::make(33, reference),
    reference_fk: None,
    goals: Array::make(33, goal),
    step_noise: [],
    critic_orders: [
      backend.from_values(
        [64],
        Array::makei(64, i => i.to_double()),
        cuda_device=-1,
        requires_grad=false,
        dtype=Int64,
      ),
    ],
  }
  let result = learner.update_policy(policy_batch)
  assert_eq(result.imagined_steps, 64)
  assert_eq(result.critic_updates, 2)
  assert_true(
    result.policy_loss == result.policy_loss && result.critic_loss >= 0.0,
  )
  assert_true(learner.policy.parameters().map(p => p.values()) != actor)
  assert_eq(learner.world.net.parameters().map(p => p.values()), frozen)
  assert_eq(learner.critic.norm.count, 66.0)
  let saved = learner.checkpoint_metadata()
  let directory = @env.get_env_var("MOONROBO_GPU_CHECKPOINT_DIR").unwrap_or(
    "target/learning-tensor",
  )
  learner.save_optimizers(directory)
  let resumed = @learning_aligned_gpu.Learner::new(backend, context, config~)
  resumed.restore_metadata(saved)
  resumed.load_optimizers(directory)
  let continued = learner.update_policy(policy_batch)
  let restored = resumed.update_policy(policy_batch)
  assert_eq(restored.policy_loss, continued.policy_loss)
  assert_eq(restored.critic_loss, continued.critic_loss)
  assert_eq(
    resumed.policy.parameters().map(p => p.values()),
    learner.policy.parameters().map(p => p.values()),
  )
  assert_eq(
    resumed.critic.net.parameters().map(p => p.values()),
    learner.critic.net.parameters().map(p => p.values()),
  )
  println(
    "8-step WM, 32-step actor, imagined GAE critic and exact learner resume passed on CPU",
  )
}
