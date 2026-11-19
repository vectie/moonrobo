///|
test "SMC actor arithmetic is wired and cannot silently resume legacy gradients" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println(
      "SKIP actor arithmetic checkpoint gate: set MOONROBO_TENSOR_LIBRARY",
    )
    return
  }
  let backend = @tensor.Backend::open(path)
  let metrics = CriticLossMetrics::new(backend)
  assert_eq(metrics.finish(), 0.0)
  assert_eq(metrics.last, 0.0)
  for value in [1.0, 2.0, 8.0] {
    metrics.append(
      backend.from_values(
        [],
        [value],
        cuda_device=-1,
        requires_grad=false,
        dtype=Float32,
      ),
    )
  }
  assert_eq(metrics.finish(), 11.0)
  assert_eq(metrics.last, 8.0)
  let old = Learner::new(backend, micro_context(backend), config=micro_config())
  let saved = old.checkpoint_metadata()
  for
    options in [
      { ..ExecutionOptimizations::default(), smc_world_rotation: true, },
      { ..ExecutionOptimizations::default(), smc_xi_normalization: true, },
      { ..ExecutionOptimizations::default(), smc_actor_return: true, },
      { ..ExecutionOptimizations::default(), policy_linear_mode: NativeLinear, },
      { ..ExecutionOptimizations::default(), critic_linear_mode: NativeLinear, },
      {
        ..ExecutionOptimizations::default(),
        rotation_error_mode: @geometry.TraceAcos,
      },
      {
        ..ExecutionOptimizations::default(),
        heading_mode: @geometry.SmcProjected,
      },
    ] {
    let candidate = Learner::new(
      backend,
      micro_context(backend),
      config=micro_config(),
      optimizations=options,
    )
    assert_eq(candidate.policy.encoder.linear_mode, options.policy_linear_mode)
    assert_eq(candidate.policy.decoder.linear_mode, options.policy_linear_mode)
    assert_eq(candidate.critic.net.linear_mode, options.critic_linear_mode)
    let before = candidate.shared_state_digest()
    assert_true(
      before.learner_config_sha256 !=
      old.shared_state_digest().learner_config_sha256,
    )
    try candidate.restore_metadata(saved) catch {
      _ => ()
    } noraise {
      _ => fail("silent arithmetic switch")
    }
    assert_eq(before.sha256, candidate.shared_state_digest().sha256)
    candidate.restore_metadata(candidate.checkpoint_metadata())
  }
}

///|
fn precision_test_backend() -> (@tensor.Backend, Int32)? raise {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("precision test device must be cpu or cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else { fail("explicit CUDA precision test needs plugin") }
    println("SKIP BF16 network integration: set MOONROBO_TENSOR_LIBRARY")
    return None
  }
  let backend = @tensor.Backend::open(path)
  assert_true(backend.has_bf16_linear())
  Some((backend, device))
}

///|
test "BF16 network preserves FP32 masters outputs and frozen 32-step input gradients" {
  guard precision_test_backend() is Some((backend, device)) else { return }
  for norm in [false, true] {
    let baseline = Network::new(
      backend,
      [3, 8, 3],
      @numeric.Rng::new(73U),
      cuda_device=device,
      layer_norm=norm,
      activation=Silu,
    )
    let candidate = Network::new(
      backend,
      [3, 8, 3],
      @numeric.Rng::new(73U),
      cuda_device=device,
      layer_norm=norm,
      activation=Silu,
      mlp_precision=Bf16,
    )
    let detached = Network::new(
      backend,
      [3, 8, 3],
      @numeric.Rng::new(73U),
      cuda_device=device,
      layer_norm=norm,
      activation=Silu,
      mlp_precision=Bf16,
    )
    assert_eq(baseline.mlp_precision, Fp32)
    assert_eq(candidate.layer_norm_mode, Expanded)
    let frozen = detached.frozen()
    assert_eq(frozen.mlp_precision, Bf16)
    assert_eq(frozen.layer_norm_mode, Expanded)
    for i, parameter in candidate.parameters() {
      assert_eq(parameter.dtype(), @tensor.Float32)
      assert_eq(parameter.values(), baseline.parameters()[i].values())
      assert_eq(parameter.values(), detached.parameters()[i].values())
    }
    let make_input = () => {
      backend.from_values(
        [2, 3],
        [0.11, -0.27, 0.39, -0.43, 0.58, 0.67],
        cuda_device=device,
        requires_grad=true,
        dtype=Float32,
      )
    }
    let x = make_input()
    let xf = make_input()
    let first = candidate.forward(x)
    assert_eq(first.dtype(), @tensor.Float32)
    assert_true(first.values() != baseline.forward(x).values())
    let mut y = x
    let mut yf = xf
    for _ in 0..<32 {
      let delta = candidate.forward(y)
      let detached_delta = frozen.forward(yf)
      assert_eq(delta.dtype(), @tensor.Float32)
      assert_eq(detached_delta.dtype(), @tensor.Float32)
      y = y.add(delta.affine(0.01))
      yf = yf.add(detached_delta.affine(0.01))
    }
    micro_near(y.values(), yf.values(), "BF16 frozen recurrent output")
    y.square().mean().backward()
    yf.square().mean().backward()
    micro_near(
      x.gradient_values(),
      xf.gradient_values(),
      "BF16 frozen 32-step input gradient",
    )
    assert_true(xf.gradient_values().any(v => v.abs() > 1.0e-8))
    for parameter in candidate.parameters() {
      assert_eq(parameter.gradient().dtype(), @tensor.Float32)
      assert_true(parameter.gradient_values().all(@numeric.finite))
    }
    for parameter in detached.parameters() {
      try parameter.gradient() catch {
        @tensor.TensorError::Native(message) =>
          assert_eq(message, "gradient is undefined")
        error => raise error
      } noraise {
        _ => fail("frozen BF16 path populated master gradients")
      }
    }
  }
  let world = WorldModel::new(
    backend,
    @numeric.Rng::new(1U),
    cuda_device=device,
    hidden=[8],
    mlp_precision=Bf16,
  )
  let policy = Policy::new(
    backend,
    93,
    720,
    @numeric.Rng::new(2U),
    cuda_device=device,
    hidden=[8],
    mlp_precision=Bf16,
  )
  let critic = Critic::new(
    backend,
    914,
    @numeric.Rng::new(3U),
    cuda_device=device,
    hidden=[8],
    mlp_precision=Bf16,
  )
  for network in [world.net, policy.encoder, policy.decoder, critic.net] {
    assert_eq(network.mlp_precision, Bf16)
    assert_true(network.parameters().all(p => p.dtype() == @tensor.Float32))
  }
  for
    norm in [
      world.input_norm,
      world.output_norm,
      policy.obs_norm,
      policy.goal_norm,
      critic.norm,
    ] {
    assert_eq(norm.mean.dtype(), @tensor.Float32)
    assert_eq(norm.variance.dtype(), @tensor.Float32)
  }
}

///|
async test "BF16 learner runs eight-step world thirty-two-step imagination and exact same-precision resume" {
  guard precision_test_backend() is Some((backend, device)) else { return }
  let config = {
    ..micro_config(),
    wm_batch: 4,
    policy_batch: 4,
    critic_epochs: 5,
    critic_minibatches: 4,
  }
  let (world, policy) = gate_batches(backend, device, 5)
  for size in [0, 2] {
    let make = precision => {
      Learner::new(
        backend,
        micro_context(backend, cuda_device=device),
        config~,
        cuda_device=device,
        seed=1U,
        world_microbatch=size,
        actor_microbatch=size,
        optimizations={
          ..ExecutionOptimizations::default(),
          mlp_precision: precision,
        },
      )
    }
    let learner = make(Bf16)
    let fp32 = make(Fp32)
    // Precision participates in audit identity, although the initialized FP32
    // master parameters and empty optimizer states are otherwise identical.
    let initial = learner.shared_state_digest()
    let baseline = fp32.shared_state_digest()
    assert_true(initial.learner_config_sha256 != baseline.learner_config_sha256)
    for i, optimizer in initial.optimizers {
      assert_eq(optimizer.sha256, baseline.optimizers[i].sha256)
    }
    let legacy_json = fp32.checkpoint_metadata().to_json()
    guard legacy_json is Object(fields) else {
      fail("metadata object expected")
    }
    fields.remove("mlp_precision")
    fields.remove("world_linear_mode")
    fields.remove("world_layer_norm_mode")
    let legacy : CheckpointMetadata = @json.from_json(legacy_json)
    assert_eq(legacy.mlp_precision, None)
    assert_eq(legacy.world_linear_mode, None)
    assert_eq(legacy.world_layer_norm_mode, None)
    fp32.restore_metadata(legacy)
    assert_eq(baseline.sha256, fp32.shared_state_digest().sha256)
    let before = learner.shared_state_digest().sha256
    try learner.restore_metadata(legacy) catch {
      _ => ()
    } noraise {
      _ => fail("legacy FP32 metadata silently accepted by BF16 learner")
    }
    assert_eq(before, learner.shared_state_digest().sha256)
    trace_test_prepare(learner, world, policy)
    let master_before = learner.world.net.parameters().map(p => p.values())
    let first = learner.update_policy(policy)
    assert_eq(first.imagined_steps, 128)
    assert_eq(first.critic_updates, 20)
    assert_true(
      [
        first.policy_loss,
        first.critic_loss,
        first.imagined_reward,
        first.imagined_survival,
      ].all(@numeric.finite),
    )
    assert_eq(
      master_before,
      learner.world.net.parameters().map(p => p.values()),
    )
    assert_eq(learner.critic.norm.count, 132.0)
    let saved = learner.checkpoint_metadata()
    assert_eq(saved.precision, "float32")
    assert_eq(saved.mlp_precision, Some(Bf16))
    try fp32.restore_metadata(saved) catch {
      _ => ()
    } noraise {
      _ => fail("BF16 metadata silently accepted by FP32 learner")
    }
    let directory = "target/learning-tensor/bf16-resume-\{@env.now()}-\{size}"
    guard !@fs.exists(directory) else {
      fail("fresh precision checkpoint directory required")
    }
    @fs.mkdir(directory, recursive=true)
    learner.save_optimizers(directory)
    assert_eq(
      checkpoint_state_digest(backend, directory, saved).sha256,
      learner.shared_state_digest().sha256,
    )
    let resumed = make(Bf16)
    resumed.restore_metadata(@json.from_json(saved.to_json()))
    resumed.load_optimizers(directory)
    assert_eq(
      resumed.shared_state_digest().sha256,
      learner.shared_state_digest().sha256,
    )
    for
      network in [
        resumed.world.net,
        resumed.policy.encoder,
        resumed.policy.decoder,
        resumed.critic.net,
      ] {
      assert_eq(network.mlp_precision, Bf16)
    }
    let a = learner.update_policy(policy)
    let b = resumed.update_policy(policy)
    assert_eq(a.critic_updates, 20)
    assert_eq(b.critic_updates, 20)
    assert_eq(
      [a.policy_loss, a.critic_loss, a.imagined_reward, a.imagined_survival],
      [b.policy_loss, b.critic_loss, b.imagined_reward, b.imagined_survival],
    )
    assert_eq(
      learner.shared_state_digest().sha256,
      resumed.shared_state_digest().sha256,
    )
    for
      parameters in [
        learner.policy.parameters(),
        learner.critic.net.parameters(),
      ] {
      for parameter in parameters {
        assert_eq(parameter.dtype(), @tensor.Float32)
        assert_eq(parameter.gradient().dtype(), @tensor.Float32)
        assert_true(parameter.gradient_values().all(@numeric.finite))
      }
    }
    for norm in learner.normalizers() {
      assert_eq(norm.mean.dtype(), @tensor.Float32)
      assert_eq(norm.variance.dtype(), @tensor.Float32)
      assert_true(norm.mean.values().all(@numeric.finite))
      assert_true(norm.variance.values().all(@numeric.finite))
    }
    let adam : AdamAuditMetadata = @json.from_json(
      @json.parse(learner.opt_critic.audit_metadata()),
    )
    assert_true(adam.states.all(s => s.present && s.step == 40L))
  }
}
