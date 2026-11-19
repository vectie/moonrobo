///|
fn fixture(
  capacity : Int32,
  environments : Int32,
) -> @learning_replay_memory.Inputs raise {
  {
    capacity,
    environments,
    storage: @aligned.ReplayBuffer::new(capacity, environments).storage_usage(),
    next_collection_steps: 1,
    restore_rows: capacity,
    learner: {
      ..@aligned.LearnerConfig::default(),
      wm_batch: 2,
      policy_batch: 2,
    },
    observation_mode: "paper",
    sampler_bins: 17,
    catalog_json_bytes: 1024L,
    state_json_bytes: 2048L,
    environment_payload_bytes: environments.to_int64() * 264L,
    optimizer_archive_bytes: Some(1048576L),
    isaac: true,
    distributed: false,
  }
}

///|
test "compact plan projects lazy slabs, final partial slab, and physical row growth" {
  let plan = @learning_replay_memory.diagnose_stream_v2(fixture(5, 300))
  assert_eq(plan.current.allocated_payload_bytes, 0L)
  assert_eq(plan.after_collection.logical_records, 300L)
  assert_eq(plan.after_collection.allocated_records, 1024L)
  assert_eq(plan.capacity.allocated_records, 1500L)
  assert_eq(plan.capacity.slab_count, 2L)
  assert_eq(plan.maximum_slab_payload_bytes, 1927168L)
  assert_eq(plan.next_collection_growth_payload_bytes, 1927168L)
  let small = @learning_replay_memory.diagnose_stream_v2(fixture(2, 2))
  assert_eq(small.after_collection.allocated_records, 4L)
  assert_eq(small.maximum_slab_payload_bytes, 7528L)
  assert_eq(small.capacity.logical_payload_bytes, 7528L)
}

///|
test "diagnostic agrees with actual slab allocations through wrap and partial final slab" {
  let replay = @aligned.ReplayBuffer::new(3, 513)
  let tr : @aligned.Transition = {
    s: Array::make(71, 0.0),
    s1: Array::make(71, 0.0),
    a: Array::make(29, 0.0),
    a_prev: Array::make(29, 0.0),
    xi: Array::make(33, 0.0),
    r: 0.0,
    frame: 0,
    ep_step: 0,
    terminated: false,
    truncated: false,
  }
  let row = Array::make(513, tr)
  for _ in 0..<4 {
    replay.add(row)
    let input = { ..fixture(3, 513), storage: replay.storage_usage(), }
    let plan = @learning_replay_memory.diagnose_stream_v2(input)
    assert_eq(
      plan.current.allocated_payload_bytes,
      input.storage.allocated_payload_bytes,
    )
    assert_eq(plan.current.logical_records, input.storage.logical_records)
    assert_eq(plan.current.slab_count, input.storage.slab_count.to_int64())
  }
  let full = @learning_replay_memory.diagnose_stream_v2({
    ..fixture(3, 513),
    storage: replay.storage_usage(),
  })
  assert_eq(full.current.allocated_records, 1539L)
  assert_eq(full.current.slab_count, 2L)
  assert_eq(full.next_collection_growth_payload_bytes, 0L)
}

///|
test "paper-size diagnostic allocates no capacity payload and preserves all safety labels" {
  let input = fixture(1000, 4096)
  let plan = @learning_replay_memory.diagnose_stream_v2(input)
  assert_eq(input.storage.allocated_payload_bytes, 0L)
  assert_eq(plan.format, "moonrobo.compact-replay-memory-plan.v2")
  assert_true(plan.diagnostic_only)
  assert_true(!plan.admission_eligible)
  assert_eq(plan.capacity.allocated_payload_bytes, 7708672000L)
  assert_eq(plan.legacy_replay_json_envelope_bytes, 536870912000L)
  assert_eq(
    plan.exact_counts["capacity_actor_candidate_i32_payload_bytes"],
    16384000L,
  )
  let restore = plan.restore_at_capacity.components
  assert_eq(restore["live_replay_primitive_payload"], 7708672000L)
  assert_eq(restore["isolated_replay_primitive_payload"], 7708672000L)
  assert_eq(restore["physics_scene_reserve_retained"], 25769803776L)
  assert_true(!plan.capacity_sidecars.fits_retained_total_limit)
  assert_eq(plan.capacity_sidecars.retained_total_limit_bytes, 536870912L)
  assert_true(plan.capacity_sidecars.total_bytes > 7708672000L)
}

///|
test "restore includes isolated histories sampler validation and opaque archive allowance" {
  let input = fixture(64, 2)
  let plan = @learning_replay_memory.diagnose_stream_v2(input)
  let extra = plan.restore_into_current.components
  assert_eq(extra["live_replay_primitive_payload"], 0L)
  assert_eq(extra["isolated_replay_primitive_payload"], 64L * 2L * 1882L)
  assert_eq(
    extra["isolated_histories_payload_and_lengths"],
    plan.exact_counts["history_payload_bytes"] + 8L,
  )
  assert_eq(extra["isolated_sampler_payload_and_validation_vectors"], 17L * 52L)
  assert_eq(extra["isolated_environment_numeric_payload"], 528L)
  assert_eq(extra["catalog_and_state_json_legacy_16x_allowance"], 3072L * 16L)
  assert_eq(
    extra["libtorch_archive_legacy_6x_plus_1g_allowance"],
    plan.archive_envelope_basis_bytes * 6L + 1073741824L,
  )
  assert_eq(
    plan.saved_sidecars.total_bytes,
    64L * 2L * 1882L +
    plan.exact_counts["history_payload_bytes"] +
    8L +
    17L * 20L +
    528L +
    3072L,
  )
  assert_true(plan.saved_sidecars.fits_retained_total_limit)
  assert_true(!plan.uncalibrated.is_empty())
}

///|
test "larger archive and optional distributed reserve cannot reduce the phase envelope" {
  let input = fixture(64, 2)
  let base = @learning_replay_memory.diagnose_stream_v2(input)
  let large = @learning_replay_memory.diagnose_stream_v2({
    ..input,
    optimizer_archive_bytes: Some(base.archive_envelope_basis_bytes + 1000L),
    distributed: true,
  })
  assert_eq(
    large.save_at_capacity.envelope_bytes - base.save_at_capacity.envelope_bytes,
    1073741824L + 6000L,
  )
  let unknown = @learning_replay_memory.diagnose_stream_v2({
    ..input,
    optimizer_archive_bytes: None,
  })
  assert_true(unknown.archive_basis_source.has_prefix("unmeasured:"))
  assert_true(!unknown.admission_eligible)
  assert_eq(
    large.train_at_capacity.components["sampled_transition_objects_legacy_allowance"],
    22L * 131072L,
  )
}

///|
test "compact diagnostic refuses foreign storage metadata bounds and checked overflow" {
  let input = fixture(64, 2)
  let invalid = [
    { ..input, storage: { ..input.storage, format: "old-object-replay", }, },
    { ..input, storage: { ..input.storage, allocated_records: 1L, }, },
    { ..input, storage: { ..input.storage, capacity_payload_bytes: 0L, }, },
    { ..input, next_collection_steps: -1, },
    { ..input, sampler_bins: 0, },
    { ..input, restore_rows: 65, },
    { ..input, catalog_json_bytes: 67108865L, },
    { ..input, state_json_bytes: 4194305L, },
    { ..input, environment_payload_bytes: -1L, },
    { ..input, optimizer_archive_bytes: Some(0L), },
    { ..input, optimizer_archive_bytes: Some(9223372036854775807L), },
    { ..input, observation_mode: "unknown", },
    { ..input, learner: { ..input.learner, horizon: 0, }, },
    {
      ..input,
      learner: {
        ..input.learner,
        policy_hidden: [2147483647, 2147483647, 2147483647],
      },
    },
  ]
  for bad in invalid {
    try @learning_replay_memory.diagnose_stream_v2(bad) catch {
      _ => ()
    } noraise {
      _ => fail("invalid or overflowing memory input must fail closed")
    }
  }
}
