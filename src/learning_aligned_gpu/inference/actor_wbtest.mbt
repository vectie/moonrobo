///|
fn fixture_spec() -> ActorSpec {
  {
    format: "moonrobo.native-tensor-actor-spec.v1",
    policy_linear_mode: None,
    observation_mode: "paper",
    hist: 2,
    goal_frames: 2,
    hidden: [8],
    mlp_precision: None,
    obs_norm: {
      mean: Array::make(93, 0.25),
      variance: Array::make(93, 0.5),
      count: 32.0,
    },
    goal_norm: {
      mean: Array::make(146, -0.5),
      variance: Array::make(146, 2.0),
      count: 16.0,
    },
  }
}

///|
fn fixture_policy(b : @tensor.Backend, spec : ActorSpec) -> @gpu.Policy raise {
  let p = @gpu.Policy::new(
    b,
    spec.mode().dim(),
    spec.goal_frames * 73,
    @numeric.Rng::new(123U),
    hist=spec.hist,
    hidden=spec.hidden,
    mlp_precision=spec.mlp_precision.unwrap_or(Fp32),
    linear_mode=spec.policy_linear_mode.unwrap_or(MatmulBias),
  )
  for
    (norm, saved) in [
      (p.obs_norm, spec.obs_norm),
      (p.goal_norm, spec.goal_norm),
    ] {
    norm.mean = b.from_values(
      [norm.dim],
      saved.mean,
      cuda_device=-1,
      requires_grad=false,
      dtype=Float32,
    )
    norm.variance = b.from_values(
      [norm.dim],
      saved.variance,
      cuda_device=-1,
      requires_grad=false,
      dtype=Float32,
    )
    norm.count = saved.count
  }
  p
}

///|
test "actor precision survives checkpoint and contract with legacy FP32 compatibility" {
  let spec = fixture_spec()
  let old_json = Json(spec)
  guard old_json is Object(fields) else { fail("actor spec object") }
  fields.remove("mlp_precision")
  fields.remove("policy_linear_mode")
  let old : ActorSpec = @json.from_json(old_json)
  assert_eq(old.mlp_precision, None)
  assert_eq(old.policy_linear_mode, None)
  assert_eq(old.contract(), spec.contract())
  assert_eq(
    { ..spec, mlp_precision: Some(@gpu.Fp32), }.contract(),
    old.contract(),
  )
  let saved : @gpu.CheckpointMetadata = {
    schema: 1,
    config: {
      ..@aligned.LearnerConfig::default(),
      hist: spec.hist,
      goal_frames: spec.goal_frames,
      policy_hidden: spec.hidden,
    },
    observation_mode: "paper",
    precision: "float32",
    mlp_precision: Some(@gpu.Bf16),
    world_linear_mode: None,
    policy_linear_mode: None,
    critic_linear_mode: None,
    rotation_error_mode: None,
    heading_mode: None,
    smc_world_rotation: None,
    smc_source_order: None,
    smc_xi_normalization: None,
    smc_actor_return: None,
    world_layer_norm_mode: None,
    normalizers: [
      spec.obs_norm,
      spec.obs_norm,
      spec.obs_norm,
      spec.goal_norm,
      spec.obs_norm,
    ],
  }
  let bf16 = ActorSpec::from_checkpoint(saved)
  let native = ActorSpec::from_checkpoint({
    ..saved,
    mlp_precision: None,
    policy_linear_mode: Some(@gpu.NativeLinear),
  })
  assert_eq(native.policy_linear_mode, Some(@gpu.NativeLinear))
  assert_true(native.contract() is { "policy_linear_mode": "native", .. })
  assert_true(native.contract() != old.contract())
  assert_eq(bf16.mlp_precision, Some(@gpu.Bf16))
  let roundtrip : ActorSpec = @json.from_json(Json(bf16))
  assert_eq(Json(roundtrip), Json(bf16))
  assert_true(
    bf16.contract() is { "precision": "float32", "mlp_precision": "bf16", .. },
  )
  assert_true(bf16.contract() != old.contract())
  assert_eq(
    ActorSpec::from_checkpoint({ ..saved, mlp_precision: None, }).contract(),
    old.contract(),
  )
  if @env.get_env_var("MOONROBO_LEGACY_TENSOR_LIBRARY") is Some(path) {
    let legacy = @tensor.Backend::open(path)
    assert_false(legacy.has_bf16_linear())
    // Capability rejection precedes archive access and cannot silently fall
    // back to FP32 for evaluation or for a subsequent export.
    try Actor::load_archive(legacy, "/missing/bf16-policy.pt", bf16) catch {
      Failure(message) =>
        assert_true(
          message.contains(
            "BF16 MLP requested but tensor plugin lacks the optional precision extension",
          ),
        )
      error => raise error
    } noraise {
      _ => fail("legacy plugin silently accepted BF16 actor")
    }
  }
}

///|
async test "BF16 actor archive export preserves compute precision and exact actions" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP BF16 actor CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let b = @tensor.Backend::open(path)
  assert_true(b.has_bf16_linear())
  let spec = { ..fixture_spec(), mlp_precision: Some(@gpu.Bf16), }
  let p = fixture_policy(b, spec)
  let history = Array::makei(2, h => {
    Array::makei(93, j => (h + j).to_double() / 100.0)
  })
  let goal = Array::makei(146, j => j.to_double() / 200.0)
  let flat = history[0].copy()
  flat.append(history[1])
  let ht = b.from_values(
    [1, 2, 93],
    flat,
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let gt = b.from_values(
    [1, 146],
    goal,
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let opt = b.adam(p.parameters(), beta2=0.95)
  p.forward(ht, gt).square().sum().backward()
  opt.step()
  let expected = p.forward(ht, gt).values()
  let directory = "target/native-bf16-actor-test-\{@async.now()}"
  @fs.mkdir(directory, recursive=true)
  opt.save(directory + "/policy.pt")
  let actor = Actor::load_archive(b, directory + "/policy.pt", spec)
  assert_eq(actor.forward(history, goal), expected)
  let spec_roundtrip : ActorSpec = @json.from_json(Json(actor.spec))
  actor.save_archive(directory + "/actor.pt")
  let again = Actor::load_archive(b, directory + "/actor.pt", spec_roundtrip)
  assert_eq(again.forward(history, goal), expected)
  assert_eq(Json(again.parameter_digests()), Json(actor.parameter_digests()))
  assert_eq(again.spec.contract(), spec.contract())
  for network in [again.policy.encoder, again.policy.decoder] {
    assert_eq(network.mlp_precision, @gpu.Bf16)
    assert_true(network.parameters().all(p => p.dtype() == @tensor.Float32))
  }
  assert_eq(again.policy.forward(ht, gt).dtype(), @tensor.Float32)
  assert_true(
    (Some(again.policy.forward(ht, gt).sum().backward()) catch { _ => None })
    is None,
  )
  let empty = b.adam(again.archive_parameters)
  empty.load(directory + "/actor.pt")
  guard @json.parse(empty.audit_metadata()) is { "states": Array(states), .. } else {
    fail("missing optimizer state audit")
  }
  assert_true(states.all(s => s is { "present": false, "step": "0", .. }))
  // The same FP32 master weights under FP32 compute produce different actions
  // on this fixture, so the roundtrip assertions actually detect a lost mode.
  let fp32 = Actor::load_archive(b, directory + "/actor.pt", {
    ..spec,
    mlp_precision: None,
  })
  assert_true(fp32.forward(history, goal) != expected)
}

///|
async test "actor archive restores normalization and exports identical actions without Adam moments" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP actor CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let b = @tensor.Backend::open(path)
  let spec = fixture_spec()
  let p = fixture_policy(b, spec)
  let history = Array::makei(2, h => {
    Array::makei(93, j => (h + j).to_double() / 100.0)
  })
  let goal = Array::makei(146, j => j.to_double() / 200.0)
  let flat = history[0].copy()
  flat.append(history[1])
  let ht = b.from_values(
    [1, 2, 93],
    flat,
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let gt = b.from_values(
    [1, 146],
    goal,
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  // A real update ensures checkpoint contains nonempty Adam moments.
  let opt = b.adam(p.parameters(), beta2=0.95)
  p.forward(ht, gt).square().sum().backward()
  opt.step()
  let expected = p.forward(ht, gt).values()
  let directory = "target/native-actor-test-\{@async.now()}"
  @fs.mkdir(directory, recursive=true)
  opt.save(directory + "/policy.pt")
  let actor = Actor::load_archive(b, directory + "/policy.pt", spec)
  assert_eq(actor.forward(history, goal), expected)
  let norms_before = Json(actor.spec)
  actor.save_archive(directory + "/actor.pt")
  let again = Actor::load_archive(b, directory + "/actor.pt", spec)
  assert_eq(again.forward(history, goal), expected)
  assert_eq(Json(again.parameter_digests()), Json(actor.parameter_digests()))
  assert_eq(Json(actor.spec), norms_before)
  let empty = b.adam(again.archive_parameters)
  empty.load(directory + "/actor.pt")
  guard @json.parse(empty.audit_metadata()) is { "states": Array(states), .. } else {
    fail("missing optimizer state audit")
  }
  assert_true(states.all(s => s is { "present": false, "step": "0", .. }))
  // Detached model weights and non-gradient inputs must not produce autograd.
  let frozen_result = actor.policy.forward(ht, gt).sum()
  assert_true((Some(frozen_result.backward()) catch { _ => None }) is None)
  assert_true(
    (Some(actor.forward([history[0]], goal)) catch { _ => None }) is None,
  )
  assert_true(
    (Some(
      {
        ..spec,
        obs_norm: { ..spec.obs_norm, variance: Array::make(93, -1.0), },
      }.validate(),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
async test "tensor actor evaluation covers full clips and uses full denominator after failure" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP actor CPU integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let b = @tensor.Backend::open(path)
  let spec = fixture_spec()
  let p = fixture_policy(b, spec)
  let directory = "target/native-actor-eval-test-\{@async.now()}"
  @fs.mkdir(directory, recursive=true)
  b.adam(p.parameters()).save(directory + "/policy.pt")
  let actor = Actor::load_archive(b, directory + "/policy.pt", spec)
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
    tracked: [0],
    q_lo: Array::make(29, -2.0),
    q_hi: Array::make(29, 2.0),
  }
  let row = [0.0, 0.0, 0.75, 0.0, 0.0, 0.0, 1.0]
  row.append(@aligned.default_joint_positions())
  let motion = @aligned.MotionLibrary::new(
    [
      {
        name: "complete",
        sha256: "fixture-a",
        rows: Array::makei(5, _ => row.copy()),
      },
      {
        name: "failed",
        sha256: "fixture-b",
        rows: Array::makei(5, _ => row.copy()),
      },
    ],
    kin,
    source_fps=50.0,
  )
  let frame = Ref::new(0)
  let step = Ref::new(0)
  let start = Ref::new(0)
  let resets = []
  let xi = Array::make(33, 0.0)
  xi[0] = 1.0
  let settings : @aligned.EvaluationSettings = {
    eval_mode: true,
    auto_reset: false,
    timeout_disabled: true,
    observation_noise: false,
    domain_randomization: false,
    simulated_replica_count: 2,
  }
  let inspect : () -> @aligned.CollectorFrame raise = () => {
    state: motion.states[frame.val],
    previous: Array::make(29, 0.0),
    xi,
    frame: frame.val,
    episode_step: step.val,
  }
  let advance : (Array[Double]) -> @aligned.Transition raise = action => {
    let failed = start.val == motion.clip_start[1] && step.val == 1
    let tr : @aligned.Transition = {
      s: @aligned.flatten_state(motion.states[frame.val]),
      s1: @aligned.flatten_state(motion.states[frame.val + 1]),
      a: action,
      a_prev: Array::make(29, 0.0),
      xi,
      r: 0.1,
      frame: frame.val,
      ep_step: step.val,
      terminated: failed,
      truncated: frame.val + 1 == motion.clip_end[motion.clip_id[frame.val]],
    }
    frame.val += 1
    step.val += 1
    tr
  }
  let reset : (Int32) -> Unit raise = value => {
    start.val = value
    frame.val = value
    step.val = 0
    resets.push(value)
  }
  let report = actor.evaluate(motion, settings, reset, inspect, advance)
  assert_eq(resets, motion.clip_start)
  assert_eq(report.per_clip[0].expected_steps, 4)
  assert_eq(report.per_clip[0].normalized_return, 1.0)
  assert_eq(report.per_clip[1].executed_steps, 2)
  assert_eq(report.per_clip[1].normalized_return, 0.5)
  assert_eq(report.failed, ["failed"])
  assert_eq(report.norm_return, 0.75)
  assert_true(report.benchmark_complete)
  let reference = @aligned.summarize_evaluations([
    {
      clip_id: "complete",
      expected_steps: 4,
      rewards: [0.1, 0.1, 0.1, 0.1],
      terminated: false,
      strict_rmse: None,
      termination_frame: None,
    },
    {
      clip_id: "failed",
      expected_steps: 4,
      rewards: [0.1, 0.1],
      terminated: true,
      strict_rmse: None,
      termination_frame: Some(2),
    },
  ])
  assert_eq(Json(report), Json(reference))
  guard report.report_json(motion.names, {}, simulated_replica_count=2)
    is Object(fields) else {
    fail("report object required")
  }
  assert_eq(fields["evaluation_physical_steps"], Json(6))
  assert_eq(fields["evaluation_simulated_physical_steps"], Json(12))
  assert_true(
    (Some(
      actor.evaluate(
        motion,
        { ..settings, auto_reset: true, },
        reset,
        inspect,
        advance,
      ),
    ) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(
      actor.evaluate(motion, settings, reset, inspect, advance, clip_indices=[
        0, 0,
      ]),
    ) catch {
      _ => None
    })
    is None,
  )
  assert_eq(Json(actor.spec), Json(spec))
}
