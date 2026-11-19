///|
test "SMC world arithmetic checkpoint fields preserve explicit and legacy modes" {
  let legacy_json : Json = {
    "schema": 1,
    "config": Json(@aligned.LearnerConfig::default()),
    "observation_mode": "smc",
    "precision": "float32",
    "normalizers": [],
  }
  let old : @gpu.CheckpointMetadata = @json.from_json(legacy_json)
  assert_eq(old.world_linear_mode, None)
  assert_eq(old.world_layer_norm_mode, None)
  assert_eq(old.rotation_error_mode, None)
  assert_eq(old.heading_mode, None)
  assert_eq(old.smc_world_rotation, None)
  assert_eq(old.smc_xi_normalization, None)
  assert_eq(old.smc_actor_return, None)
  assert_eq(old.policy_linear_mode, None)
  assert_eq(old.critic_linear_mode, None)
  let saved : @gpu.CheckpointMetadata = {
    ..old,
    world_linear_mode: Some(@gpu.NativeLinear),
    world_layer_norm_mode: Some(@gpu.Native),
    policy_linear_mode: Some(@gpu.NativeLinear),
    critic_linear_mode: Some(@gpu.NativeLinear),
    rotation_error_mode: Some(@geometry.TraceAcos),
    heading_mode: Some(@geometry.SmcProjected),
    smc_world_rotation: Some(true),
    smc_xi_normalization: Some(true),
    smc_actor_return: Some(true),
  }
  let restored : @gpu.CheckpointMetadata = @json.from_json(saved.to_json())
  assert_eq(restored.world_linear_mode, Some(@gpu.NativeLinear))
  assert_eq(restored.world_layer_norm_mode, Some(@gpu.Native))
  assert_eq(restored.policy_linear_mode, Some(@gpu.NativeLinear))
  assert_eq(restored.critic_linear_mode, Some(@gpu.NativeLinear))
  assert_eq(restored.rotation_error_mode, Some(@geometry.TraceAcos))
  assert_eq(restored.heading_mode, Some(@geometry.SmcProjected))
  assert_eq(restored.smc_world_rotation, Some(true))
  assert_eq(restored.smc_xi_normalization, Some(true))
  assert_eq(restored.smc_actor_return, Some(true))
}

///|
test "execution candidates are strict opt-in and baseline uses zero extra storage" {
  assert_eq(execution_optimizations({}), @gpu.ExecutionOptimizations::default())
  assert_false(execution_optimizations({}).smc_source_order)
  assert_true(
    execution_optimizations({ "smc_source_order": true }).smc_source_order,
  )
  assert_false(execution_optimizations({}).fused_axis_rotation)
  assert_false(execution_optimizations({}).fused_skew)
  assert_false(execution_optimizations({}).fused_cross_vjp)
  assert_false(execution_optimizations({}).fused_so3_coefficients)
  assert_false(execution_optimizations({}).fused_so3_coefficients_forward)
  assert_false(execution_optimizations({}).split_so3_coefficients)
  assert_false(execution_optimizations({}).fused_so3_coefficients_full)
  assert_true(
    execution_optimizations({ "fused_so3_coefficients_full": true }).fused_so3_coefficients_full,
  )
  assert_false(execution_optimizations({}).split_actor_return)
  assert_false(execution_optimizations({}).batch_actor_encoder)
  assert_true(
    execution_optimizations({ "batch_actor_encoder": true }).batch_actor_encoder,
  )
  assert_true(
    execution_optimizations({ "split_actor_return": true }).split_actor_return,
  )
  assert_true(
    execution_optimizations({ "fused_so3_coefficients_forward": true }).fused_so3_coefficients_forward,
  )
  assert_true(
    execution_optimizations({ "split_so3_coefficients": true }).split_so3_coefficients,
  )
  assert_true(
    execution_optimizations({ "fused_cross_vjp": true }).fused_cross_vjp,
  )
  assert_true(
    execution_optimizations({ "fused_so3_coefficients": true }).fused_so3_coefficients,
  )
  assert_false(execution_optimizations({}).fused_so3_tail)
  assert_false(execution_optimizations({}).fused_cross_forward)
  assert_true(
    execution_optimizations({ "fused_so3_tail": true }).fused_so3_tail,
  )
  assert_true(
    execution_optimizations({ "fused_cross_forward": true }).fused_cross_forward,
  )
  assert_true(
    execution_optimizations({ "fused_axis_rotation": true }).fused_axis_rotation,
  )
  assert_true(execution_optimizations({ "fused_skew": true }).fused_skew)
  try execution_optimizations({ "fused_skew": "true" }) catch {
    _ => ()
  } noraise {
    _ => fail("fused skew must be a strict boolean")
  }
  assert_eq(
    execution_optimizations({ "heading_mode": "smc_projected" }).heading_mode,
    @geometry.SmcProjected,
  )
  assert_eq(
    execution_optimizations({ "world_linear_mode": "native" }).world_linear_mode,
    @gpu.NativeLinear,
  )
  assert_eq(execution_optimizations({}).world_linear_mode, @gpu.MatmulBias)
  assert_eq(
    execution_optimizations({ "layer_norm_mode": "submitted" }).layer_norm_mode,
    @gpu.Submitted,
  )
  assert_true(
    execution_optimizations({ "reuse_geometry": true }).reuse_geometry,
  )
  assert_true(!execution_optimizations({}).tail_reference_fk_cache)
  assert_true(
    execution_optimizations({ "tail_reference_fk_cache": true }).tail_reference_fk_cache,
  )
  assert_eq(
    execution_optimizations({ "layer_norm_mode": "native" }).layer_norm_mode,
    @gpu.Native,
  )
  assert_true(
    execution_optimizations({ "body_orientation_batched": true }).body_orientation_batched,
  )
  let invalid_configs : Array[Json] = [
    { "tail_reference_fk_cache": "true" },
    { "fused_so3_tail": "true" },
    { "fused_cross_vjp": "true" },
    { "fused_so3_coefficients": "true" },
    { "fused_so3_coefficients_forward": "true" },
    { "split_so3_coefficients": "true" },
    { "fused_so3_coefficients_full": "true" },
    { "split_actor_return": "true" },
    { "batch_actor_encoder": "true" },
    { "fused_cross_forward": "true" },
    { "split_world_delta": "true" },
    { "compact_heading": "true" },
    { "body_errors_batched": "true" },
    { "body_errors_batched": true },
    { "compact_axis_rotation": "true" },
    { "compact_skew": "true" },
    { "static_fk_pruning": "true" },
    { "native_cross": "true" },
    { "native_cross_preserve_forward": "true" },
    { "world_norm_snapshot": "true" },
    { "detached_rotation_constants": "true" },
    { "reuse_geometry": "true" },
    { "reuse_critic_normalization": 1 },
    { "layer_norm_mode": "auto" },
    { "world_linear_mode": "auto" },
    { "policy_linear_mode": "auto" },
    { "critic_linear_mode": "auto" },
    { "rotation_error_mode": "auto" },
    { "heading_mode": "auto" },
    { "body_orientation_batched": "true" },
    { "world_error_batched": "true" },
    { "sparse_joint_axis": "true" },
    { "zero_joint_pivot": "true" },
    { "smc_world_rotation": "true" },
    { "smc_source_order": "true" },
    { "smc_xi_normalization": "true" },
    { "smc_actor_return": "true" },
  ]
  for invalid in invalid_configs {
    assert_true(
      (Some(execution_optimizations(invalid)) catch { _ => None }) is None,
    )
  }
}

///|
test "compact rotations are opt in and retain all old memory reserves" {
  let a = optimization_memory_extra(settings({}, []))
  let s = settings(
    {
      "compact_axis_rotation": true,
      "compact_skew": true,
      "static_fk_pruning": true,
    },
    [],
  )
  assert_true(
    s.optimizations.compact_axis_rotation &&
    s.optimizations.compact_skew &&
    s.optimizations.static_fk_pruning,
  )
  let b = optimization_memory_extra(s)
  assert_eq(b["execution_compact_rotations"], 33554432L)
  let wide = {
    ..s,
    learner: { ..s.learner, policy_batch: 8192, },
    batch_execution: { ..s.batch_execution, actor_microbatch: 0, },
  }
  assert_eq(
    optimization_memory_extra(wide)["execution_compact_rotations"],
    8L * 29L * s.learner.horizon.to_int64() * 8192L + 1048576L,
  )
  for key, value in a {
    assert_eq(b[key], value)
  }
}

///|
test "heading and split keep independent opt-ins and conservative storage" {
  let baseline = optimization_memory_extra(settings({}, []))
  let config : Json = { "compact_heading": true, "split_world_delta": true }
  let opts = execution_optimizations(config)
  assert_true(opts.compact_heading && opts.split_world_delta)
  assert_true(!@gpu.ExecutionOptimizations::default().compact_heading)
  assert_true(!@gpu.ExecutionOptimizations::default().split_world_delta)
  let extra = optimization_memory_extra(settings(config, []))
  for key, value in baseline {
    assert_eq(extra.get(key), Some(value))
  }
  assert_true(extra.get("execution_compact_heading").unwrap() >= 67108864L)
  assert_true(extra.get("execution_split_world_delta").unwrap() == 33554432L)
}

///|
test "native cross and world norm snapshot are explicit execution options" {
  assert_true(execution_optimizations({ "native_cross": true }).native_cross)
  assert_true(
    execution_optimizations({ "world_norm_snapshot": true }).world_norm_snapshot,
  )
  let a = optimization_memory_extra(settings({}, []))
  let b = optimization_memory_extra(
    settings({ "world_norm_snapshot": true }, []),
  )
  assert_eq(b["execution_world_norm_snapshot"], 1048576L)
  for key, value in a {
    assert_eq(b[key], value)
  }
}

///|
test "batched world error adds reserve without discounting other memory" {
  let baseline = settings({ "layer_norm_mode": "native" }, [])
  let candidate = settings(
    { "layer_norm_mode": "native", "world_error_batched": true },
    [],
  )
  assert_true(candidate.optimizations.world_error_batched)
  let a = optimization_memory_extra(baseline)
  let b = optimization_memory_extra(candidate)
  assert_eq(b["execution_world_error_batched"], 134217728L)
  for key, value in a {
    assert_eq(b[key], value)
  }
}

///|
test "reference FK cache adds its full reserve without reducing baseline budgets" {
  let baseline = settings(
    { "resident_reference_cache": true, "reuse_geometry": true },
    [],
  )
  let candidate = settings(
    {
      "resident_reference_cache": true,
      "reuse_geometry": true,
      "reference_fk_cache": true,
    },
    [],
  )
  let a = optimization_memory_extra(baseline)
  let b = optimization_memory_extra(candidate)
  assert_eq(b["execution_reference_fk_cache"], 2147483648L)
  for key, value in a {
    assert_eq(b[key], value)
  }
  assert_true(
    (Some(settings({ "reference_fk_cache": true }, [])) catch { _ => None })
    is None,
  )
}

///|
test "resident reference config is strict opt-in with explicit bounded admission" {
  assert_true(resident_reference_request({}) is None)
  assert_eq(
    resident_reference_request({ "resident_reference_cache": true }),
    Some(1073741824L),
  )
  assert_eq(
    resident_reference_request({
      "resident_reference_cache": true,
      "resident_reference_max_mib": 2048,
    }),
    Some(2147483648L),
  )
  let invalid_configs : Array[Json] = [
    { "resident_reference_cache": "true" },
    { "resident_reference_cache": 1 },
    { "resident_reference_max_mib": 0 },
    { "resident_reference_max_mib": 65537 },
    { "resident_reference_max_mib": 1.5 },
    { "resident_reference_max_mib": "2048" },
  ]
  for invalid in invalid_configs {
    try resident_reference_request(invalid) catch {
      _ => ()
    } noraise {
      _ => fail("invalid resident reference request accepted")
    }
  }
  let baseline = settings({}, [])
  assert_true(optimization_memory_extra(baseline).is_empty())
  let candidate = settings(
    { "resident_reference_cache": true, "resident_reference_max_mib": 2048 },
    [],
  )
  let extra = optimization_memory_extra(candidate)
  assert_eq(extra.length(), 1)
  assert_eq(extra["execution_resident_reference_cache"], 4319202304L)
  let baseline_plan = estimate_memory(
    baseline,
    1099511627776L,
    Some(1099511627776L),
  )
  let candidate_plan = estimate_memory(
    candidate,
    1099511627776L,
    Some(1099511627776L),
  )
  assert_eq(
    candidate_plan.peak_bytes - baseline_plan.peak_bytes,
    extra["execution_resident_reference_cache"],
  )
}

///|
test "batched body orientation reserve follows active actor chunk without discounting baseline" {
  let baseline = settings({}, [])
  let candidate = settings({ "body_orientation_batched": true }, [])
  let extra = optimization_memory_extra(candidate)
  assert_eq(extra.length(), 1)
  let expected = 67108864L +
    128L *
    4L *
    64L *
    candidate.learner.horizon.to_int64() *
    candidate.learner.policy_batch.to_int64()
  assert_eq(extra["execution_batched_body_orientation"], expected)
  let smaller = {
    ..candidate,
    batch_execution: { ..candidate.batch_execution, actor_microbatch: 2, },
  }
  assert_eq(
    optimization_memory_extra(smaller)["execution_batched_body_orientation"],
    67108864L + 128L * 4L * 64L * candidate.learner.horizon.to_int64() * 2L,
  )
  let before = estimate_memory(baseline, 1099511627776L, Some(1099511627776L))
  let after = estimate_memory(candidate, 1099511627776L, Some(1099511627776L))
  assert_eq(after.peak_bytes - before.peak_bytes, expected)
}

///|
test "corrected geometry modes are explicit and preserve legacy defaults" {
  let chosen = execution_optimizations({
    "heading_mode": "orthonormal_atlas",
    "rotation_error_mode": "geodesic_squared",
  })
  assert_eq(chosen.heading_mode, @geometry.OrthonormalAtlas)
  assert_eq(chosen.rotation_error_mode, @geometry.GeodesicSquared)
  let original = execution_optimizations({
    "heading_mode": "smc_projected",
    "rotation_error_mode": "trace_acos",
  })
  assert_eq(original.heading_mode, @geometry.SmcProjected)
  assert_eq(original.rotation_error_mode, @geometry.TraceAcos)
}
