///|
fn[A] staging_test_result(run : () -> A raise) -> Result[A, Error] {
  Ok(run()) catch {
    error => Err(error)
  }
}

///|
test "world logical staging bounds all arrays and copies before allocation" {
  let usage = world_staging_usage(2048, 8)
  assert_eq(usage.logical_values, 3358720L)
  assert_eq(usage.host_array_payload_bytes, 26869760L)
  assert_eq(usage.extra_reserve_bytes, 107544576L)
  assert_eq(usage.decode_block_windows, 256)
  assert_eq(usage.upload_calls, 5)
  assert_eq(usage.device_concat_calls, 0)
  assert_eq(world_staging_usage(257, 8).decode_block_windows, 256)
  assert_true(staging_test_result(() => world_staging_usage(4096, 8)) is Err(_))
  assert_eq(
    world_staging_usage(4096, 8, max_bytes=268435456L).extra_reserve_bytes,
    215023616L,
  )
  for
    (batch, width, cap) in [
      (0, 8, 134217728L),
      (1, 0, 134217728L),
      (2147483647, 2147483647, 9223372036854775807L),
      (2048, 8, 107544575L),
      (1, 1, 0L),
    ] {
    assert_true(
      staging_test_result(() => world_staging_usage(batch, width, max_bytes=cap))
      is Err(_),
    )
  }
  assert_true(
    staging_test_result(() => {
      world_staging_usage(2, 8, limits={
        max_reference_frames: 1,
        max_tensor_values: 3279L,
      })
    })
    is Err(_),
  )
  let (_, motion, _) = fixture()
  let valid : @aligned.ReplayWindow = {
    transitions: [transition(motion, 0, 0)],
    mask: [1.0],
  }
  let staging = WorldStaging::new(1, 1)
  assert_true(staging_test_result(() => staging.append([])) is Err(_))
  assert_true(
    staging_test_result(() => staging.append(Array::make(257, valid))) is Err(_),
  )
  assert_true(
    staging_test_result(() => staging.append([{ ..valid, mask: [0.5], }]))
    is Err(_),
  )
  assert_true(
    staging_test_result(() => staging.append([{ ..valid, transitions: [], }]))
    is Err(_),
  )
  assert_true(
    staging_test_result(() => {
      staging.append([
        {
          ..valid,
          transitions: [{ ..valid.transitions[0], s: Array::make(70, 0.0), }],
        },
      ])
    })
    is Err(_),
  )
  let nonfinite = valid.transitions[0].s.copy()
  nonfinite[0] = 1.0 / 0.0
  assert_true(
    staging_test_result(() => {
      staging.append([
        { ..valid, transitions: [{ ..valid.transitions[0], s: nonfinite, }], },
      ])
    })
    is Err(_),
  )
  staging.append([valid])
  assert_true(staging_test_result(() => staging.append([valid])) is Err(_))
}

///|
fn staging_test_backend() -> (@tensor.Backend, Int32)? raise {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None | Some("cpu") => -1
    Some("cuda:0") => 0
    _ => fail("MOONROBO_OPTIMIZATION_TEST_DEVICE must be cpu or cuda:0")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA staging gate requires MOONROBO_TENSOR_LIBRARY")
    }
    println("SKIP world staging tensor gate: set MOONROBO_TENSOR_LIBRARY")
    return None
  }
  let backend = @tensor.Backend::open(path)
  if device >= 0 {
    guard backend.cuda_device_count() > 0 &&
      backend.cuda_free_bytes(device) > 1073741824L else {
      fail("world staging CUDA gate requires more than 1 GiB free")
    }
  }
  Some((backend, device))
}

///|
test "world staging preserves tensor bits masks wrapped replay and RNG across block boundaries" {
  guard staging_test_backend() is Some((backend, device)) else { return }
  let (motion, _, base) = block_fixture()
  let replay = @aligned.ReplayBuffer::new(12, 2)
  for step in 0..<20 {
    replay.add(
      Array::makei(2, env => {
        let frame = (step + env * 3) % 14
        let tr = transition(motion, frame, frame)
        { ..tr, terminated: step % 5 == env, truncated: step % 7 == env, }
      }),
    )
  }
  for
    (batch, width, dtype) in [
      (1, 2, @tensor.Float64),
      (256, 8, @tensor.Float32),
      (257, 8, @tensor.Float64),
      (2048, 8, @tensor.Float32),
      (4096, 8, @tensor.Float32),
    ] {
    let config = { ..base, wm_batch: batch, wm_window: width, }
    let old_rng = @numeric.Rng::new(0x12345678U)
    let new_rng = @numeric.Rng::new(0x12345678U)
    for _ in 0..<2 {
      let expected = sample_world_batch(
        backend,
        replay,
        config,
        old_rng,
        cuda_device=device,
        dtype~,
      )
      let actual = sample_world_batch(
        backend,
        replay,
        config,
        new_rng,
        cuda_device=device,
        dtype~,
        staging_max_bytes=Some(268435456L),
      )
      for
        (a, e) in [
          (actual.s, expected.s),
          (actual.s1, expected.s1),
          (actual.actions, expected.actions),
          (actual.xi, expected.xi),
          (actual.mask, expected.mask),
        ] {
        same_tensor(a, e)
      }
      assert_eq(new_rng.state(), old_rng.state())
      let packed_rng = @numeric.Rng::new(0x12345678U)
      let staged_rng = @numeric.Rng::new(0x12345678U)
      let packed = sample_world_batch(
        backend,
        replay,
        config,
        packed_rng,
        cuda_device=device,
        dtype~,
        staging_max_bytes=Some(268435456L),
        packed_replay=true,
      )
      let staged = sample_world_batch(
        backend,
        replay,
        config,
        staged_rng,
        cuda_device=device,
        dtype~,
        staging_max_bytes=Some(268435456L),
      )
      for
        (actual, expected) in [
          (packed.s, staged.s),
          (packed.s1, staged.s1),
          (packed.actions, staged.actions),
          (packed.xi, staged.xi),
          (packed.mask, staged.mask),
        ] {
        same_tensor(actual, expected)
      }
      assert_eq(packed_rng.state(), staged_rng.state())
    }
    let before = new_rng.state()
    assert_true(
      staging_test_result(() => {
        sample_world_batch(
          backend,
          replay,
          config,
          new_rng,
          cuda_device=device,
          dtype~,
          staging_max_bytes=Some(1L),
        )
      })
      is Err(_),
    )
    assert_eq(new_rng.state(), before)
    assert_true(
      staging_test_result(() => {
        sample_world_batch(
          backend,
          replay,
          config,
          new_rng,
          cuda_device=device,
          dtype=Int64,
          staging_max_bytes=Some(268435456L),
        )
      })
      is Err(_),
    )
    assert_eq(new_rng.state(), before)
    assert_true(
      staging_test_result(() => {
        sample_world_batch(
          backend,
          replay,
          config,
          new_rng,
          cuda_device=device,
          dtype~,
          staging_max_bytes=Some(268435456L),
          limits={ max_reference_frames: 1, max_tensor_values: 1L, },
        )
      })
      is Err(_),
    )
    assert_eq(new_rng.state(), before)
    for _ in 0..<16 {
      bit_equal([new_rng.uniform()], [old_rng.uniform()])
    }
  }
}

///|
test "world staging runner preserves updates optimizer state metrics and resume" {
  guard staging_test_backend() is Some((backend, device)) else { return }
  let (kin, motion, base) = fixture()
  let config = {
    ..base,
    wm_batch: 257,
    wm_window: 8,
    wm_batches: 2,
    observation_noise: true,
  }
  for micro in [0, 128] {
    let states : Array[String] = []
    let snapshots : Array[Json] = []
    let metrics : Array[Array[Json]] = []
    let actions : Array[Array[Double]] = []
    for variant in [0, 1, 2] {
      let enabled = variant != 0
      let learner = @gpu.Learner::new(
        backend,
        @geometry.Context::new(backend, kin, device),
        config~,
        cuda_device=device,
        seed=71U,
        world_microbatch=micro,
      )
      let runner = TrainingRunner::new(
        learner,
        motion,
        16,
        1,
        seed=37U,
        resident_reference_max_bytes=Some(1048576L),
        world_staging_max_bytes=if enabled { Some(134217728L) } else { None },
        world_packed_replay=variant == 2,
      )
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
        warmup_steps: 8,
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
      assert_eq(runner.world_staging_max_bytes is Some(_), enabled)
      runner.run({ ..options, iterations: 3, }, inspect_env, step_env, m => {
        observed_metrics.push(m.to_json())
      })
      states.push(learner.shared_state_digest().sha256)
      snapshots.push(runner.snapshot().to_json())
      metrics.push(observed_metrics)
      actions.push(observed_actions)
    }
    assert_eq(states[0], states[1])
    assert_eq(snapshots[0], snapshots[1])
    assert_eq(metrics[0], metrics[1])
    bit_equal(actions[0], actions[1])
    assert_eq(states[0], states[2])
    assert_eq(snapshots[0], snapshots[2])
    assert_eq(metrics[0], metrics[2])
    bit_equal(actions[0], actions[2])
  }
  println(
    "WORLD_PACKED_RUNNER_GATE_PASS exact tensors RNG updates optimizer metrics resume",
  )
}
