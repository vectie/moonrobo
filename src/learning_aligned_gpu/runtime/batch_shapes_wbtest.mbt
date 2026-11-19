///|
test "paper input shape accounting is explicit bounded arithmetic with unchanged default" {
  let config = @aligned.LearnerConfig::default()
  let paper = BatchLimits::paper_scale()
  assert_eq(BatchLimits::default().max_reference_frames, 131072)
  assert_eq(BatchLimits::default().max_tensor_values, 16777216L)
  assert_eq(paper.max_reference_frames, 135168)
  assert_eq(paper.max_tensor_values, 127016960L)
  let cases : Array[(@aligned.ObservationMode, Int64)] = [
    (Paper, 125468672L),
    (Smc, 126500864L),
    (Observable, 127016960L),
  ]
  for (mode, count) in cases {
    let usage = policy_batch_shape_usage(config, 4096, mode, limits=paper)
    assert_eq(usage.logical_tensor_values, count)
    assert_eq(usage.reference_frames, 135168L)
    assert_eq(usage.sample_block_size, 256)
    assert_eq(usage.tensor_index_values, 655360L)
    assert_eq(usage.tensor_float_values, count - 655360L)
    assert_eq(usage.reference_rotation_values, 1216512L)
    assert_eq(
      usage.device_f32_payload_bytes,
      (count - 655360L + 1216512L) * 4L + 655360L * 8L,
    )
    assert_eq(usage.logical_source_f64_bytes, count * 8L)
    assert_eq(usage.sampled_transition_values, 10543104L)
    assert_eq(usage.sampled_mask_values, 0L)
    assert_eq(usage.reference_union_frames_per_block, 13568L)
    assert_eq(usage.reference_state_values_per_block, 1031168L)
    assert_eq(usage.critic_permutation_values, 131072L)
    assert_eq(usage.noise_values_per_block, 256L * mode.dim().to_int64())
    assert_eq(
      usage.assembled_values_per_block,
      256L * (934L + 10L * mode.dim().to_int64()),
    )
    for
      limits in [
        BatchLimits::default(),
        { max_reference_frames: 135167, max_tensor_values: count, },
        { max_reference_frames: 135168, max_tensor_values: count - 1L, },
      ] {
      try ignore(policy_batch_shape_usage(config, 4096, mode, limits~)) catch {
        _ => ()
      } noraise {
        _ => fail("insufficient paper dimensions accepted")
      }
    }
  }
  let world = world_batch_shape_usage(2048, 8, limits=paper)
  assert_eq(world.logical_tensor_values, 3358720L)
  assert_eq(world.device_f32_payload_bytes, 13434880L)
  assert_eq(world.assembled_values_per_block, 419840L)
  assert_eq(world.sampled_transition_values, 479232L)
  assert_eq(world.sampled_mask_values, 2048L)
  assert_eq(world.largest_device_concat_values, 1163264L)
  let small = policy_batch_shape_usage(
    { ..config, observation_noise: false, },
    1,
    Paper,
  )
  assert_eq(small.sample_block_size, 1)
  assert_eq(small.noise_values_per_block, 0L)
  assert_eq(small.largest_device_concat_values, 0L)
}

///|
test "batch shape overflow and invalid dimensions fail before any allocation" {
  assert_eq(
    bounded_sum([0L, 9223372036854775806L, 1L], BatchArithmeticLimit),
    BatchArithmeticLimit,
  )
  for values in [[9223372036854775807L, 1L], [-1L, 1L]] {
    try ignore(bounded_sum(values, BatchArithmeticLimit)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid checked sum accepted")
    }
  }
  try
    ignore(bounded_product([9223372036854775807L, 2L], BatchArithmeticLimit))
  catch {
    _ => ()
  } noraise {
    _ => fail("overflowing product accepted")
  }
  for (batch, width) in [(0, 8), (2048, 0), (-1, 8), (2147483647, 2147483647)] {
    try
      ignore(
        world_batch_shape_usage(batch, width, limits=BatchLimits::paper_scale()),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid world shape accepted")
    }
  }
  let config = @aligned.LearnerConfig::default()
  for
    bad in [
      { ..config, hist: 2147483647, },
      { ..config, goal_frames: 2147483647, },
      { ..config, horizon: 2147483647, },
      { ..config, critic_epochs: 2147483647, },
      { ..config, hist: 0, },
    ] {
    try
      ignore(
        policy_batch_shape_usage(bad, 4096, Observable, limits={
          max_reference_frames: 2147483647,
          max_tensor_values: BatchArithmeticLimit,
        }),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid policy shape accepted")
    }
  }
}
