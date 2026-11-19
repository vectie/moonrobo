///|
fn[A] noise_test_result(run : () -> A raise) -> Result[A, Error] {
  Ok(run()) catch {
    error => Err(error)
  }
}

///|
test "noise staging checks one-step arrays block copy and cap before RNG" {
  let usage = noise_staging_usage(4096, 99)
  assert_eq(usage.logical_values, 405504L)
  assert_eq(usage.host_array_payload_bytes, 3244032L)
  assert_eq(usage.generation_block_values, 25344L)
  assert_eq(usage.extra_reserve_bytes, 13244416L)
  assert_eq(usage.upload_calls_per_step, 1)
  assert_eq(usage.device_concat_calls_per_step, 0)
  for
    (batch, dim, cap) in [
      (0, 99, 16777216L),
      (1, 0, 16777216L),
      (2147483647, 2147483647, 9223372036854775807L),
      (4096, 99, 13244415L),
      (1, 1, 0L),
    ] {
    assert_true(
      noise_test_result(() => noise_staging_usage(batch, dim, max_bytes=cap))
      is Err(_),
    )
  }
  let draws = [0]
  let draw = () => {
    draws[0] += 1
    0.25
  }
  assert_true(
    noise_test_result(() => {
      stage_noise_values(4096, [1.0], draw, BatchLimits::default(), 1L)
    })
    is Err(_),
  )
  assert_eq(draws[0], 0)
  assert_true(
    noise_test_result(() => {
      stage_noise_values(
        257,
        [1.0],
        draw,
        { max_reference_frames: 1, max_tensor_values: 256L, },
        16777216L,
      )
    })
    is Err(_),
  )
  assert_eq(draws[0], 0)
  assert_true(
    noise_test_result(() => {
      check_noise_staging(1, 1, Int64, BatchLimits::default(), 16777216L)
    })
    is Err(_),
  )
}

///|
// Independent copy of the preserved per-256-sample upload/concat noise oracle.
fn legacy_noise_step(
  backend : @tensor.Backend,
  batch : Int32,
  widths : Array[Double],
  draw : () -> Double,
  device : Int32,
  dtype : @tensor.DType,
) -> @tensor.Tensor raise {
  let dim = widths.length()
  let parts : Array[@tensor.Tensor] = []
  for begin = 0; begin < batch; {
    let count = (batch - begin).min(256)
    let values = Array::makei(count * dim, i => {
      (draw() * 2.0 - 1.0) * widths[i % dim]
    })
    parts.push(upload(backend, values, [count, dim], device, dtype))
    continue begin + count
  }
  finish_tensor_blocks(backend, parts)
}

///|
test "noise staging preserves finite rejection boundary and subsequent RNG draws" {
  guard staging_test_backend() is Some((backend, device)) else { return }
  let widths = [0.2, 0.0, -0.0]
  for dtype in [@tensor.Float32, @tensor.Float64] {
    for bad in [-1, 0, 256 * 3 - 1, 256 * 3, 513 * 3 - 1] {
      let old_rng = @numeric.Rng::new(91U)
      let new_rng = @numeric.Rng::new(91U)
      let old_draws = [0]
      let new_draws = [0]
      let legacy = noise_test_result(() => {
        legacy_noise_step(
          backend,
          513,
          widths,
          () => {
            let index = old_draws[0]
            old_draws[0] += 1
            let value = old_rng.uniform()
            if index == bad {
              0.0 / 0.0
            } else {
              value
            }
          },
          device,
          dtype,
        )
      })
      let candidate = noise_test_result(() => {
        staged_step_noise(
          backend,
          513,
          widths,
          () => {
            let index = new_draws[0]
            new_draws[0] += 1
            let value = new_rng.uniform()
            if index == bad {
              0.0 / 0.0
            } else {
              value
            }
          },
          device,
          dtype,
          BatchLimits::default(),
          16777216L,
        )
      })
      match (legacy, candidate) {
        (Ok(a), Ok(b)) => {
          assert_eq(bad, -1)
          same_tensor(a, b)
        }
        (Err(_), Err(_)) => assert_true(bad >= 0)
        _ => fail("noise staging changed finite rejection")
      }
      let expected = if bad < 0 {
        513 * 3
      } else {
        ((bad / (256 * 3) + 1) * 256 * 3).min(513 * 3)
      }
      assert_eq(old_draws[0], expected)
      assert_eq(new_draws[0], expected)
      assert_eq(new_rng.state(), old_rng.state())
      for _ in 0..<16 {
        bit_equal([new_rng.uniform()], [old_rng.uniform()])
      }
    }
  }
  // Exercise the actual proposed B4096/H32/Smc99 noise dimensions without
  // retaining 32 host arrays or relying on the small fixture's clip horizon.
  let old_rng = @numeric.Rng::new(97U)
  let new_rng = @numeric.Rng::new(97U)
  let widths = @aligned.observation_noise(Smc)
  for _ in 0..<32 {
    let old = legacy_noise_step(
      backend,
      4096,
      widths,
      () => old_rng.uniform(),
      device,
      Float32,
    )
    let new = staged_step_noise(
      backend,
      4096,
      widths,
      () => new_rng.uniform(),
      device,
      Float32,
      BatchLimits::default(),
      16777216L,
    )
    same_tensor(old, new)
    assert_eq(old_rng.state(), new_rng.state())
  }
  for _ in 0..<16 {
    bit_equal([new_rng.uniform()], [old_rng.uniform()])
  }
}

///|
test "noise staging preserves complete policy tensors permutations and RNG with resident composition" {
  guard staging_test_backend() is Some((backend, device)) else { return }
  let (motion, replay, base) = block_fixture()
  let cases : Array[
    (Int32, @aligned.ObservationMode, @tensor.DType, Bool, Bool),
  ] = [
    (1, Paper, Float64, false, false),
    (256, Smc, Float32, true, false),
    (257, Observable, Float64, true, false),
    (4096, Smc, Float32, true, true),
  ]
  for (batch, mode, dtype, noise, resident_enabled) in cases {
    let config = { ..base, policy_batch: batch, observation_noise: noise, }
    let resident = if resident_enabled {
      Some(
        ResidentReferences::new(
          backend,
          motion,
          config.goal_frames,
          cuda_device=device,
          dtype~,
          max_bytes=1048576L,
        ),
      )
    } else {
      None
    }
    let old_rng = @numeric.Rng::new(53U)
    let new_rng = @numeric.Rng::new(53U)
    for _ in 0..<2 {
      let a = sample_policy_batch(
        backend,
        replay,
        motion,
        config,
        mode,
        old_rng,
        cuda_device=device,
        dtype~,
        resident_references=resident,
      )
      let b = sample_policy_batch(
        backend,
        replay,
        motion,
        config,
        mode,
        new_rng,
        cuda_device=device,
        dtype~,
        resident_references=resident,
        noise_staging_max_bytes=Some(16777216L),
      )
      same_policy(a, b)
      assert_eq(new_rng.state(), old_rng.state())
    }
    let before = new_rng.state()
    assert_true(
      noise_test_result(() => {
        sample_policy_batch(
          backend,
          replay,
          motion,
          config,
          mode,
          new_rng,
          cuda_device=device,
          dtype~,
          noise_staging_max_bytes=Some(1L),
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
test "noise staging preserves full and eight-microbatch learner updates" {
  guard staging_test_backend() is Some((backend, device)) else { return }
  let (kin, _, _) = fixture()
  let (motion, replay, base) = block_fixture()
  for (batch, micro) in [(257, 0), (4096, 512)] {
    let config = { ..base, policy_batch: batch, observation_noise: true, }
    let old = @gpu.Learner::new(
      backend,
      @geometry.Context::new(backend, kin, device),
      config~,
      cuda_device=device,
      mode=Smc,
      seed=57U,
      actor_microbatch=micro,
    )
    let new = @gpu.Learner::new(
      backend,
      @geometry.Context::new(backend, kin, device),
      config~,
      cuda_device=device,
      mode=Smc,
      seed=57U,
      actor_microbatch=micro,
    )
    let old_rng = @numeric.Rng::new(59U)
    let new_rng = @numeric.Rng::new(59U)
    for _ in 0..<2 {
      let a = sample_policy_batch(
        backend,
        replay,
        motion,
        config,
        Smc,
        old_rng,
        cuda_device=device,
      )
      let b = sample_policy_batch(
        backend,
        replay,
        motion,
        config,
        Smc,
        new_rng,
        cuda_device=device,
        noise_staging_max_bytes=Some(16777216L),
      )
      same_policy(a, b)
      old.policy.update_normalizers(a.history, backend.concat(a.goals))
      new.policy.update_normalizers(b.history, backend.concat(b.goals))
      let old_metrics = old.update_policy(a)
      let new_metrics = new.update_policy(b)
      bit_equal(
        [
          old_metrics.policy_loss,
          old_metrics.critic_loss,
          old_metrics.imagined_reward,
          old_metrics.imagined_survival,
        ],
        [
          new_metrics.policy_loss,
          new_metrics.critic_loss,
          new_metrics.imagined_reward,
          new_metrics.imagined_survival,
        ],
      )
      assert_eq(old_metrics.imagined_steps, new_metrics.imagined_steps)
      assert_eq(old_metrics.critic_updates, new_metrics.critic_updates)
      assert_eq(
        old.shared_state_digest().sha256,
        new.shared_state_digest().sha256,
      )
      assert_eq(old_rng.state(), new_rng.state())
    }
  }
}
