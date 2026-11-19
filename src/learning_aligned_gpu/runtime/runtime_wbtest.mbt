///|
fn fixture() -> (
  @aligned.Kinematics,
  @aligned.MotionLibrary,
  @aligned.LearnerConfig,
) raise {
  let bodies : Array[@aligned.BodySpec] = [
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
  ]
  for i in 0..<14 {
    bodies.push({
      name: "link\{i}",
      parent: 0,
      joint: i,
      axis: [0.0, 1.0, 0.0],
      offset_p: [i.to_double() * 0.01, 0.0, -0.02],
      offset_rotation: @aligned.identity(),
      pivot: [0.0, 0.0, 0.0],
      qref: 0.0,
    })
  }
  let kin : @aligned.Kinematics = {
    bodies,
    tracked: Array::makei(14, i => i + 1),
    q_lo: Array::make(29, -3.0),
    q_hi: Array::make(29, 3.0),
  }
  let rows = Array::makei(16, i => {
    let row = [i.to_double() * 0.001, 0.0, 0.8, 0.0, 0.0, 0.0, 1.0]
    row.append(@aligned.default_joint_positions())
    row
  })
  let motion = @aligned.MotionLibrary::new(
    [{ name: "fixture", sha256: "fixture-hash", rows, }],
    kin,
    source_fps=50.0,
  )
  let config : @aligned.LearnerConfig = {
    ..@aligned.LearnerConfig::default(),
    wm_hidden: [4],
    policy_hidden: [4],
    critic_hidden: [4],
    hist: 2,
    goal_frames: 2,
    horizon: 2,
    wm_window: 2,
    wm_batches: 1,
    wm_batch: 2,
    policy_batch: 2,
    critic_epochs: 1,
    critic_minibatches: 1,
    observation_noise: false,
  }
  (kin, motion, config)
}

///|
fn transition(
  motion : @aligned.MotionLibrary,
  frame : Int32,
  step : Int32,
  done~ : Bool = false,
) -> @aligned.Transition {
  {
    s: @aligned.flatten_state(motion.states[frame]),
    s1: @aligned.flatten_state(motion.states[frame + 1]),
    a: Array::make(29, 0.02),
    a_prev: Array::make(29, 0.01),
    xi: Array::makei(33, i => if i == 0 { 0.8 } else { 0.0 }),
    r: 0.1,
    frame,
    ep_step: step,
    terminated: done,
    truncated: false,
  }
}

///|
test "batch memory arithmetic rejects overflow without allocating" {
  let config : @aligned.LearnerConfig = {
    ..@aligned.LearnerConfig::default(),
    horizon: 2147483647,
    goal_frames: 2147483647,
    policy_batch: 2147483647,
  }
  let failed = try {
    check_policy_limits(config, config.policy_batch, 93, BatchLimits::default())
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_eq(bounded_product([4L, 8L, 205L], 6560L), 6560L)
  let excessive = try {
    ignore(bounded_product([4L, 8L, 205L], 6559L))
    false
  } catch {
    _ => true
  }
  assert_true(excessive)
}

///|
test "bounded replay tensors preserve WXYZ masks goals histories and permutations" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP runtime tensor parity: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let b = @tensor.Backend::open(path)
  let (_, motion, c) = fixture()
  let first = transition(motion, 0, 0, done=true)
  let second = transition(motion, 4, 0)
  let replay = @aligned.ReplayBuffer::new(4, 1)
  replay.add([first])
  replay.add([second])
  let windows = replay.sample_windows(2, 2, _ => 0)
  let batch = world_batch_from_windows(b, windows, dtype=Float64)
  assert_eq(batch.s.shape(), [2, 2, 71])
  assert_eq(batch.mask.values(), [1.0, 0.0, 1.0, 0.0])
  assert_eq(batch.s.values()[3], 1.0) // replay quaternion WXYZ, source was XYZW
  assert_eq(batch.s.values()[4], 0.0)
  assert_eq(batch.actions.values()[0], 0.02)
  let starts = replay.sample_starts(
    2,
    c.hist,
    _ => 1,
    clip_end=f => motion.clip_end[motion.clip_id[f]],
    horizon=c.horizon,
  )
  let policy = policy_batch_from_starts(
    b,
    starts,
    motion,
    c,
    Paper,
    @numeric.Rng::new(123U),
    dtype=Float64,
  )
  assert_eq(policy.history.shape(), [2, 2, 93])
  assert_eq(policy.references.length(), 3)
  assert_eq(policy.step_noise.length(), 0)
  for t in 0..<3 {
    assert_eq(
      policy.references[t].flatten71(b).values()[0:71].to_owned(),
      @aligned.flatten_state(motion.states[4 + t]),
    )
    assert_eq(policy.goals[t].values()[0:146].to_owned(), motion.goal(4 + t, 2))
  }
  let expected = @aligned.observation(
    @aligned.unflatten_state(second.s),
    second.a_prev,
    second.xi,
    @aligned.default_joint_positions(),
    motion.states[4],
    Paper,
  )
  assert_eq(policy.history.values()[0:93].to_owned(), expected)
  assert_eq(policy.history.values()[93:186].to_owned(), expected)
  let permutation = policy.critic_orders[0].values()
  assert_eq(permutation.length(), 4)
  for i in 0..<4 {
    assert_true(permutation.contains(i.to_double()))
  }
  let noise_config = { ..c, observation_noise: true, }
  let noisy = policy_batch_from_starts(
    b,
    starts,
    motion,
    noise_config,
    Paper,
    @numeric.Rng::new(123U),
    dtype=Float64,
  )
  assert_eq(noisy.step_noise.length(), 2)
  let widths = @aligned.observation_noise(Paper)
  for step in noisy.step_noise {
    for i, value in step.values() {
      assert_true(value.abs() <= widths[i % 93])
    }
  }
}

///|
test "GPU runner tiny CPU collection learner update and resume warmup" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP runtime learner integration: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let b = @tensor.Backend::open(path)
  let (kin, motion, c) = fixture()
  let context = @geometry.Context::new(b, kin, -1)
  let learner = @gpu.Learner::new(b, context, config=c)
  let runner = TrainingRunner::new(learner, motion, 8, 1, seed=7U)
  let position = [0]
  let inspect_env : () -> Array[@aligned.CollectorFrame] raise = () => {
    let f = position[0]
    [
      {
        state: motion.states[f],
        previous: Array::make(29, 0.01),
        xi: Array::makei(33, i => if i == 0 { 0.8 } else { 0.0 }),
        frame: f,
        episode_step: f,
      },
    ]
  }
  // Test-only deterministic transitions, not a deployed physical adapter.
  let step_env : (Array[Array[Double]]) -> Array[@aligned.Transition] raise = actions => {
    let f = position[0]
    position[0] += 1
    [{ ..transition(motion, f, f), a: actions[0].copy(), }]
  }
  let options : @aligned.TrainingOptions = {
    iterations: 1,
    warmup_steps: 2,
    world_only_iterations: 0,
    update_to_data: 1.0,
    learning_rate_decay_iterations: 10,
    action_noise: 0.0,
  }
  let phases : Array[(String, Int32)] = []
  runner.run(
    options,
    inspect_env,
    step_env,
    metrics => {
      assert_eq(metrics.iteration, 1)
      assert_true(@numeric.finite(metrics.world.wm_loss))
      guard metrics.policy is Some(p) else { fail("policy update missing") }
      assert_true(
        @numeric.finite(p.policy_loss) && @numeric.finite(p.critic_loss),
      )
    },
    on_phase=Some((phase, iteration) => phases.push((phase, iteration))),
  )
  assert_eq(phases, [
    ("warmup_complete", 0),
    ("collection_complete", 1),
    ("world_updates_complete", 1),
    ("actor_critic_complete", 1),
  ])
  assert_eq(runner.counters.physical_transitions, 3L)
  assert_eq(runner.counters.imagined_transitions, 4L)
  assert_eq(runner.counters.model_updates, 1L)
  assert_eq(runner.counters.actor_updates, 1L)
  assert_eq(runner.replay.size(), 3)
  assert_eq(learner.policy.obs_norm.count, 3.0)
  let saved = runner.snapshot()
  let decoded : RuntimeSnapshot = @json.from_json(saved.to_json())
  assert_eq(decoded.counters.imagined_transitions, 4L)
  assert_true(decoded.distributed is None)
  let legacy = saved.to_json()
  if legacy is Object(fields) {
    ignore(fields.remove("distributed"))
  }
  let legacy_decoded : RuntimeSnapshot = @json.from_json(legacy)
  assert_true(legacy_decoded.distributed is None)
  assert_eq(runner.global_counters().imagined_transitions, 4L)
  let distributed_saved = {
    ..decoded,
    distributed: Some({
      rank: 0,
      world_size: 2,
      collection_seed: 7U,
      exact_distributed_resume_supported: false,
    }),
  }
  let unsupported = try {
    runner.restore(distributed_saved, false)
    false
  } catch {
    _ => true
  }
  assert_true(unsupported)
  let rejected = try {
    runner.restore({ ..decoded, rng: 0U, }, true)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  runner.restore(decoded, true)
  assert_eq(runner.replay.size(), 3)
  assert_eq(runner.histories[0].length(), 2)
  runner.restore(decoded, false)
  assert_eq(runner.replay.size(), 0)
  assert_true(runner.histories[0].is_empty())
  runner.run(options, inspect_env, step_env, _ => ())
  assert_eq(runner.counters.physical_transitions, 3L)
  assert_eq(runner.replay.size(), 0)
  runner.run(
    { ..options, iterations: 2, world_only_iterations: 99, },
    inspect_env,
    step_env,
    _ => (),
  )
  assert_eq(runner.counters.physical_transitions, 6L)
  assert_eq(runner.replay.size(), 3)
  assert_eq(runner.counters.actor_updates, 1L)
  let model_updates = runner.counters.model_updates
  try
    runner.run(
      { ..options, iterations: 3, world_only_iterations: 99, },
      inspect_env,
      step_env,
      _ => (),
      on_phase=Some((phase, _) => {
        if phase == "collection_complete" {
          fail("diagnostic fixture failure")
        }
      }),
    )
  catch {
    Failure(message) =>
      assert_true(message.contains("diagnostic fixture failure"))
    error => raise error
  } noraise {
    _ => fail("phase callback failure must stop training")
  }
  assert_eq(runner.iteration, 2)
  assert_eq(runner.counters.physical_transitions, 7L)
  assert_eq(runner.counters.model_updates, model_updates)
  assert_eq(runner.counters.actor_updates, 1L)
}

///|
test "distributed manifest accepts only immutable local generation names" {
  assert_true(valid_generation("generation-3-123456", 3))
  assert_false(valid_generation("generation-2-123456", 3))
  assert_false(valid_generation("generation-3-../../current", 3))
  assert_false(valid_generation("current.json", 3))
  assert_true(
    valid_sha256(
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    ),
  )
  assert_false(
    valid_sha256(
      "g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    ),
  )
}
