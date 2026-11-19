///|
test "resident reference admission bounds complete table and construction before allocation" {
  let usage = resident_reference_usage(441000, 10, max_bytes=2147483648L)
  assert_eq(usage.resident_bytes, 1412964000L)
  assert_eq(usage.device_build_peak_bytes, 2825928000L)
  assert_eq(usage.build_block_rows, 256)
  assert_eq(usage.host_build_reserve_bytes, 24059904L)
  for
    (frames, preview, budget) in [
      (441000, 10, 1073741824L),
      (0, 10, 1073741824L),
      (1, 0, 1073741824L),
      (2147483647, 2147483647, 9223372036854775807L),
      (1, 1, 0L),
    ] {
    try resident_reference_usage(frames, preview, max_bytes=budget) catch {
      _ => ()
    } noraise {
      _ => fail("invalid resident reference memory request accepted")
    }
  }
}

///|
test "resident reference FK preserves lookup order and repeated frame rows" {
  guard @env.get_env_var("MOONROBO_HOTSPOT_GATE") == Some("reference_fk") else {
    return
  }
  let backend = @tensor.Backend::open(
    @env.get_env_var("MOONROBO_TENSOR_LIBRARY").unwrap(),
  )
  let (kin, motion, config) = fixture()
  let context = @geometry.Context::new(backend, kin, 0)
  let cache = ResidentReferences::new(
    backend,
    motion,
    config.goal_frames,
    cuda_device=0,
    max_bytes=16777216L,
    reference_context=Some(context),
  )
  guard cache.reference_fk is Some(table) else { fail("FK table absent") }
  let index = backend.from_values(
    [5],
    [3.0, 0.0, 3.0, 1.0, 2.0],
    cuda_device=0,
    requires_grad=false,
    dtype=Int64,
  )
  let actual = table.index_select(index)
  let expected = context.pack_reference_bodies(
    @geometry.State::from_flat71(backend, cache.flat71.index_select(index)),
  )
  assert_eq(actual.values(), expected.values())
  assert_eq(actual.shape(), [5, context.reference_body_width()])
  println("REFERENCE_FK_GATHER_GATE_PASS repeated-and-nonmonotone-indices")
}

///|
test "resident runner preserves collection updates complete state and resume cache" {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("MOONROBO_OPTIMIZATION_TEST_DEVICE must be cpu or cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail(
        "explicit CUDA resident runner test requires MOONROBO_TENSOR_LIBRARY",
      )
    }
    println("SKIP resident runner state parity: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  if device >= 0 {
    guard backend.cuda_device_count() > 0 &&
      backend.cuda_free_bytes(device) > 1073741824L else {
      fail("resident runner CUDA parity requires more than 1 GiB free")
    }
  }
  let (kin, motion, base) = fixture()
  let config = { ..base, observation_noise: true, }
  let final_states : Array[String] = []
  let snapshots : Array[Json] = []
  let metrics : Array[Array[Json]] = []
  let actions : Array[Array[Double]] = []
  for enabled in [false, true] {
    let learner = @gpu.Learner::new(
      backend,
      @geometry.Context::new(backend, kin, device),
      config~,
      cuda_device=device,
      seed=71U,
    )
    let runner = TrainingRunner::new(
      learner,
      motion,
      8,
      1,
      seed=37U,
      resident_reference_max_bytes=if enabled { Some(1048576L) } else { None },
    )
    let cache = runner.resident_references
    assert_eq(cache is Some(_), enabled)
    let position = [0]
    let observed_actions : Array[Double] = []
    let observed_metrics : Array[Json] = []
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
    let step_env : (Array[Array[Double]]) -> Array[@aligned.Transition] raise = values => {
      let f = position[0]
      position[0] += 1
      observed_actions.append(values[0])
      [{ ..transition(motion, f, f), a: values[0].copy(), }]
    }
    let options : @aligned.TrainingOptions = {
      iterations: 2,
      warmup_steps: 2,
      world_only_iterations: 0,
      update_to_data: 1.0,
      learning_rate_decay_iterations: 10,
      action_noise: 0.1,
    }
    runner.run(options, inspect_env, step_env, m => {
      observed_metrics.push(m.to_json())
    })
    let saved = runner.snapshot()
    runner.restore(saved, true)
    if cache is Some(before) {
      guard runner.resident_references is Some(after) else {
        fail("resident reference cache disappeared after restore")
      }
      assert_true(physical_equal(before, after))
    }
    runner.run({ ..options, iterations: 3, }, inspect_env, step_env, m => {
      observed_metrics.push(m.to_json())
    })
    final_states.push(learner.shared_state_digest().sha256)
    snapshots.push(runner.snapshot().to_json())
    metrics.push(observed_metrics)
    actions.push(observed_actions)
  }
  assert_eq(final_states[0], final_states[1])
  assert_eq(snapshots[0], snapshots[1])
  assert_eq(metrics[0], metrics[1])
  bit_equal(actions[0], actions[1])
}

///|
test "resident reference batches preserve all tensor bits RNG tail padding and collection goals" {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("MOONROBO_OPTIMIZATION_TEST_DEVICE must be cpu or cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail(
        "explicit CUDA resident reference test requires MOONROBO_TENSOR_LIBRARY",
      )
    }
    println(
      "SKIP resident reference tensor parity: set MOONROBO_TENSOR_LIBRARY",
    )
    return
  }
  let backend = @tensor.Backend::open(path)
  if device >= 0 {
    guard backend.cuda_device_count() > 0 &&
      backend.cuda_free_bytes(device) > 1073741824L else {
      fail("resident reference CUDA parity requires more than 1 GiB free")
    }
  }
  let (motion, replay, base) = block_fixture()
  let cases : Array[(Int32, @aligned.ObservationMode, @tensor.DType, Bool)] = [
    (1, Paper, Float64, false),
    (256, Paper, Float32, true),
    (257, Observable, Float64, true),
    (4096, Paper, Float32, true),
  ]
  for (batch, mode, dtype, noise) in cases {
    let config = {
      ..base,
      policy_batch: batch,
      observation_noise: noise,
      hist: if batch == 4096 {
        2
      } else {
        10
      },
      horizon: if batch == 4096 {
        2
      } else {
        base.horizon
      },
      goal_frames: if batch == 4096 {
        1
      } else {
        base.goal_frames
      },
      critic_epochs: 2,
    }
    let cache = ResidentReferences::new(
      backend,
      motion,
      config.goal_frames,
      cuda_device=device,
      dtype~,
    )
    let old_rng = @numeric.Rng::new(0x12345678U)
    let new_rng = @numeric.Rng::new(0x12345678U)
    // Repeated updates use one immutable cache; no cross-update RNG or values
    // are cached. Both routes independently execute the full noise/permutation
    // generation to check the exact training input and draw sequence.
    for _ in 0..<2 {
      let expected = sample_policy_batch(
        backend,
        replay,
        motion,
        config,
        mode,
        old_rng,
        cuda_device=device,
        dtype~,
      )
      let actual = sample_policy_batch(
        backend,
        replay,
        motion,
        config,
        mode,
        new_rng,
        cuda_device=device,
        dtype~,
        resident_references=Some(cache),
      )
      same_policy(actual, expected)
      assert_eq(new_rng.state(), old_rng.state())
    }
    for _ in 0..<16 {
      bit_equal([new_rng.uniform()], [old_rng.uniform()])
    }
    let frames = [31, 0, 15, 16, 31, 12]
    let expected : Array[Double] = []
    for frame in frames {
      expected.append(legacy_goal(motion, frame, config.goal_frames))
    }
    same_tensor(
      cache.goals_for_frames(frames),
      upload(
        backend,
        expected,
        [frames.length(), 73 * config.goal_frames],
        device,
        dtype,
      ),
    )
    let before = new_rng.state()
    try
      sample_policy_batch(
        backend,
        replay,
        motion,
        { ..config, goal_frames: config.goal_frames + 1, },
        mode,
        new_rng,
        cuda_device=device,
        dtype~,
        resident_references=Some(cache),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("resident reference preview mismatch accepted")
    }
    assert_eq(new_rng.state(), before)
    let different_source = {
      ..motion,
      states: @aligned.FrameStore::eager(
        Array::makei(motion.states.length(), i => motion.states[i]),
      ),
    }
    try
      sample_policy_batch(
        backend,
        replay,
        different_source,
        config,
        mode,
        new_rng,
        cuda_device=device,
        dtype~,
        resident_references=Some(cache),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("resident reference cache accepted a different state store")
    }
    assert_eq(new_rng.state(), before)
    try cache.goals_for_frames([motion.states.length()]) catch {
      _ => ()
    } noraise {
      _ => fail("resident reference out-of-range frame accepted")
    }
  }
}
