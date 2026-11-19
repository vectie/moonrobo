///|
fn hotspot_near(
  actual : Array[Double],
  expected : Array[Double],
  label : String,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    let limit = 2.0e-6 + 2.0e-4 * expected[i].abs()
    guard !actual[i].is_nan() &&
      !actual[i].is_inf() &&
      !expected[i].is_nan() &&
      !expected[i].is_inf() &&
      (actual[i] - expected[i]).abs() <= limit else {
      fail(
        "hotspot gate \{label} at \{i}: \{actual[i]} vs \{expected[i]}, limit \{limit}",
      )
    }
  }
}

///|
fn hotspot_tensor_near(
  actual : @tensor.Tensor,
  expected : @tensor.Tensor,
  label : String,
) -> Unit raise {
  assert_eq(actual.shape(), expected.shape())
  let a = actual.reshape([-1])
  let b = expected.reshape([-1])
  for start = 0; start < a.shape()[0]; {
    let count = (a.shape()[0] - start).min(65536)
    hotspot_near(
      a.narrow(0, start, count).values(),
      b.narrow(0, start, count).values(),
      label,
    )
    continue start + count
  }
}

///|
fn hotspot_gate_memory(backend : @tensor.Backend, label : String) -> Unit raise {
  let stats = backend.cuda_memory_stats(0, synchronize=true)
  println("HOTSPOT_GATE_MEMORY \{label} \{stats.to_json().stringify()}")
  guard stats.cuda_free_bytes > 17179869184L &&
    stats.reserved_peak_bytes < 34359738368L else {
    fail(
      "numerical fixture exceeded32GiB allocator envelope or16GiB free reserve",
    )
  }
}

///|
test "hotspot actual G1 batch4096 eight512 H32 two-update numerical gate" {
  guard @env.get_env_var("MOONROBO_HOTSPOT_GATE") is Some(mode) else {
    println("SKIP hotspot GPU gate: explicit mode required")
    return
  }
  guard [
    "layernorm", "cross", "reference_fk", "world_packed", "fused_tail", "fk_axis",
  ].contains(mode) else {
    fail("unsupported hotspot numerical gate")
  }
  let backend = @tensor.Backend::open(
    @env.get_env_var("MOONROBO_TENSOR_LIBRARY").unwrap(),
  )
  ignore(
    backend.configure_cuda_tf32(
      matmul=true,
      cudnn_conv=true,
      cudnn_rnn=true,
      before_first_tensor=true,
    ),
  )
  guard backend.cuda_free_bytes(0) > 68719476736L else {
    fail("numeric gate needs64GiB CUDA free including16GiB reserve")
  }
  let model = @sim.Runtime::open(
    "/opt/isaaclab-venv/lib/python3.12/site-packages/mujoco/libmujoco.so.3.15.0",
    "/workspace/moonrobo/data/g1_description/scene-no-self-collision.xml",
    require_position_servos=false,
  )
  let kin = @tracking.kinematics(model)
  let context = @geometry.Context::new(
    backend,
    kin,
    0,
    body_orientation_batched=true,
  )
  let candidate_context = @geometry.Context::new(
    backend,
    kin,
    0,
    body_orientation_batched=true,
    submitted_cross=mode == "cross",
    submitted_axis=mode == "fk_axis",
  )
  let config : @aligned.LearnerConfig = {
    ..@aligned.LearnerConfig::default(),
    wm_hidden: [2048, 2048, 2048],
    policy_hidden: [2048, 1024, 512, 256],
    critic_hidden: [256, 128],
    policy_batch: 4096,
    wm_batch: 2048,
    wm_batches: 1,
    hist: 10,
    goal_frames: 10,
    horizon: 32,
    wm_window: 8,
    critic_epochs: 5,
    critic_minibatches: 4,
  }
  let options : @gpu.ExecutionOptimizations = {
    ..@gpu.ExecutionOptimizations::default(),
    reuse_geometry: true,
    body_orientation_batched: true,
    adam_checked_norm: true,
  }
  let a = @gpu.Learner::new(
    backend,
    context,
    config~,
    mode=@aligned.Smc,
    cuda_device=0,
    actor_microbatch=512,
    optimizations=options,
  )
  let b = @gpu.Learner::new(
    backend,
    candidate_context,
    config~,
    mode=@aligned.Smc,
    cuda_device=0,
    actor_microbatch=512,
    optimizations={
      ..options,
      layer_norm_mode: if mode == "layernorm" {
        @gpu.Submitted
      } else if mode == "fused_tail" {
        @gpu.FusedTail
      } else {
        @gpu.Expanded
      },
    },
  )
  let upload = (shape, data) => {
    backend.from_values(
      shape,
      data,
      cuda_device=0,
      dtype=Float32,
      requires_grad=false,
    )
  }
  let default_q = @aligned.default_joint_positions()
  let flat = Array::makei(4096 * 71, i => {
    let j = i % 71
    let row = i / 71
    match j {
      0 | 1 => 0.01 * (row % 9 - 4).to_double() * (j + 1).to_double()
      2 => 0.76 + 0.002 * (row % 5).to_double()
      3 => 1.0
      4..<7 => 0.01 * ((row + j) % 11 - 5).to_double()
      7..<10 => 0.03 * (row % 13 - 6).to_double() * (j - 6).to_double()
      10..<13 => 0.02 * (row % 9 - 4).to_double() * (j - 9).to_double()
      13..<42 => default_q[j - 13] + (row % 17 - 8).to_double() * 0.0002
      _ => 0.05 * ((row + j) % 7 - 3).to_double()
    }
  })
  let state = upload([4096, 71], flat)
  let xis = upload(
    [4096, 33],
    Array::makei(4096 * 33, i => if i % 33 == 0 { 0.75 } else { 0.0 }),
  )
  // The world model starts with a zero final layer. A stationary s1==s
  // fixture would produce zero world loss and miss its backward path.
  let next_state = backend.concat([
    state.narrow(0, 1, 4095),
    state.narrow(0, 0, 1),
  ])
  let world : @gpu.WorldBatch = {
    s: backend.concat(Array::make(4, state)).reshape([2048, 8, 71]),
    s1: backend.concat(Array::make(4, next_state)).reshape([2048, 8, 71]),
    actions: upload([2048, 8, 29], Array::make(2048 * 8 * 29, 0.0)),
    xi: backend.concat(Array::make(4, xis)).reshape([2048, 8, 33]),
    mask: upload([2048, 8], Array::make(2048 * 8, 1.0)),
  }
  let reference = @geometry.State::from_flat71(backend, state)
  let (world, candidate_world) = if mode == "world_packed" {
    let replay = @aligned.ReplayBuffer::new(12, 256)
    for step in 0..<20 {
      replay.add(
        Array::makei(256, env => {
          let row = (step * 113 + env) % 4096
          let next = (row + 1) % 4096
          {
            s: flat[row * 71:(row + 1) * 71].to_owned(),
            s1: flat[next * 71:(next + 1) * 71].to_owned(),
            a: Array::make(29, 0.0),
            a_prev: Array::make(29, 0.0),
            xi: Array::makei(33, i => if i == 0 { 0.75 } else { 0.0 }),
            r: 0.0,
            frame: step,
            ep_step: step,
            terminated: step % 7 == env % 7,
            truncated: step % 11 == env % 11,
          }
        }),
      )
    }
    let ra = @numeric.Rng::new(71U)
    let rb = @numeric.Rng::new(71U)
    let expected = @runner.sample_world_batch(
      backend,
      replay,
      config,
      ra,
      cuda_device=0,
      staging_max_bytes=Some(134217728L),
    )
    let packed = @runner.sample_world_batch(
      backend,
      replay,
      config,
      rb,
      cuda_device=0,
      staging_max_bytes=Some(134217728L),
      packed_replay=true,
    )
    assert_eq(ra.state(), rb.state())
    for
      (a, b) in [
        (expected.s, packed.s),
        (expected.s1, packed.s1),
        (expected.actions, packed.actions),
        (expected.xi, packed.xi),
        (expected.mask, packed.mask),
      ] {
      assert_eq(a.values(), b.values())
    }
    (expected, packed)
  } else {
    (world, world)
  }
  let goals = upload([4096, 730], Array::make(4096 * 730, 0.0))
  let previous = upload([4096, 29], Array::make(4096 * 29, 0.0))
  let observation = context.observation(
    reference,
    previous,
    xis,
    reference,
    @aligned.Smc,
  )
  let policy : @gpu.PolicyBatch = {
    state,
    xi: xis,
    previous,
    history: backend.stack(Array::make(10, observation), axis=1),
    references: Array::make(33, reference),
    reference_fk: None,
    goals: Array::make(33, goals),
    step_noise: Array::make(
      32,
      upload(
        [4096, 99],
        Array::makei(4096 * 99, i => 0.001 * (i % 17 - 8).to_double()),
      ),
    ),
    critic_orders: Array::makei(5, epoch => {
      backend.from_values(
        [4096 * 32],
        Array::makei(4096 * 32, i => {
          ((i * 37 + epoch * 17) % (4096 * 32)).to_double()
        }),
        cuda_device=0,
        dtype=Int64,
        requires_grad=false,
      )
    }),
  }
  // Repeated/nonmonotone indices exercise a true immutable frame table; build
  // and gather separately, before the actor graph, just as the runtime does.
  let candidate_policy = if mode == "reference_fk" {
    let parts = Array::makei(8, block => {
      context.pack_reference_bodies(
        @geometry.State::from_flat71(backend, state.narrow(0, block * 512, 512)),
      )
    })
    let packed = backend.concat(parts, axis=0)
    let indices = backend.from_values(
      [33 * 4096],
      Array::makei(33 * 4096, i => (i % 4096).to_double()),
      cuda_device=0,
      dtype=Int64,
      requires_grad=false,
    )
    {
      ..policy,
      reference_fk: Some(
        packed
        .index_select(indices)
        .reshape([33, 4096, context.reference_body_width()]),
      ),
    }
  } else {
    policy
  }
  for learner in [a, b] {
    learner.observe(
      world.s.reshape([16384, 71]),
      world.actions.reshape([16384, 29]),
      world.xi.reshape([16384, 33]),
      world.s1.reshape([16384, 71]),
    )
    learner.policy.update_normalizers(
      policy.history.reshape([40960, 99]),
      goals,
    )
  }
  for step in 0..<2 {
    hotspot_gate_memory(backend, "before-update")
    let wa = a.fit_world_batch(world)
    hotspot_gate_memory(backend, "world-baseline")
    let wb = b.fit_world_batch(candidate_world)
    hotspot_gate_memory(backend, "world-candidate")
    assert_true(wa.wm_loss > 0.0 && wb.wm_loss > 0.0)
    hotspot_near(
      [wb.wm_loss, wb.wm_error_last],
      [wa.wm_loss, wa.wm_error_last],
      mode + " world",
    )
    // Actor update intentionally clears world gradients. Compare them here,
    // while they still exist, rather than reading an undefined gradient later.
    let world_a = a.world.net.parameters()
    let world_b = b.world.net.parameters()
    let mut world_nonzero = false
    for i in 0..<world_a.length() {
      let ga = world_a[i].gradient_values()
      world_nonzero = world_nonzero || ga.any(v => v != 0.0)
      hotspot_near(world_b[i].gradient_values(), ga, mode + " world gradient")
    }
    assert_true(world_nonzero)
    let pa = a.update_policy(policy)
    hotspot_gate_memory(backend, "actor-baseline")
    let pb = b.update_policy(candidate_policy)
    hotspot_gate_memory(backend, "actor-candidate")
    assert_eq(pa.imagined_steps, 131072)
    assert_eq(pb.imagined_steps, pa.imagined_steps)
    assert_eq(pa.critic_updates, 20)
    assert_eq(pb.critic_updates, 20)
    hotspot_near(
      [pb.policy_loss, pb.critic_loss, pb.imagined_reward, pb.imagined_survival],
      [pa.policy_loss, pa.critic_loss, pa.imagined_reward, pa.imagined_survival],
      mode + " metrics",
    )
    for
      (parameters_a, parameters_b, optimizer_a, optimizer_b, check_gradient) in [
        (
          a.world.net.parameters(),
          b.world.net.parameters(),
          a.opt_world,
          b.opt_world,
          false,
        ),
        (
          a.policy.parameters(),
          b.policy.parameters(),
          a.opt_policy,
          b.opt_policy,
          true,
        ),
        (
          a.critic.net.parameters(),
          b.critic.net.parameters(),
          a.opt_critic,
          b.opt_critic,
          true,
        ),
      ] {
      assert_eq(optimizer_a.audit_metadata(), optimizer_b.audit_metadata())
      let mut nonzero_gradient = false
      for i in 0..<parameters_a.length() {
        if check_gradient {
          let gradient_a = parameters_a[i].gradient_values()
          let gradient_b = parameters_b[i].gradient_values()
          nonzero_gradient = nonzero_gradient || gradient_a.any(v => v != 0.0)
          hotspot_near(gradient_b, gradient_a, mode + " gradient")
        }
        for kind in 0..<3 {
          hotspot_tensor_near(
            optimizer_b.audit_tensor(i, kind~),
            optimizer_a.audit_tensor(i, kind~),
            mode + " Adam \{kind}",
          )
        }
      }
      assert_true(!check_gradient || nonzero_gradient)
    }
    let na = a.checkpoint_metadata().normalizers
    let nb = b.checkpoint_metadata().normalizers
    for i in 0..<na.length() {
      assert_eq(na[i].count, nb[i].count)
      hotspot_near(nb[i].mean, na[i].mean, mode + " norm mean")
      hotspot_near(nb[i].variance, na[i].variance, mode + " norm variance")
    }
    println(
      "HOTSPOT_GATE_PASS mode=\{mode} update=\{step + 1} batch=4096 micro=512 H=32 actual-G1 paper-width-network world2048x8 smc99",
    )
  }
}
