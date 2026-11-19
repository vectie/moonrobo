///|
fn execution_optimizations(config : Json) -> @gpu.ExecutionOptimizations raise {
  guard !setting(config, "body_errors_batched", false) else {
    fail(
      "body_errors_batched rejected by strict parameter-update parity; disabled",
    )
  }
  let gradient_bucket_bytes : Int32 = setting(
    config, "gradient_bucket_bytes", 0,
  )
  guard gradient_bucket_bytes == 0 ||
    (gradient_bucket_bytes >= 1048576 && gradient_bucket_bytes <= 67108864) else {
    fail("gradient_bucket_bytes must be zero or within 1..64 MiB")
  }
  let layer_norm_mode = match setting(config, "layer_norm_mode", "expanded") {
    "expanded" => @gpu.Expanded
    "native" => @gpu.Native
    "submitted" => @gpu.Submitted
    "fused_tail" => @gpu.FusedTail
    _ =>
      fail("layer_norm_mode must be expanded, native, submitted or fused_tail")
  }
  let mlp_precision = match setting(config, "amp", "none") {
    "none" => @gpu.Fp32
    "bf16" => @gpu.Bf16
    _ => fail("amp must be none or bf16")
  }
  {
    reuse_geometry: setting(config, "reuse_geometry", false),
    tail_reference_fk_cache: setting(config, "tail_reference_fk_cache", false),
    reuse_critic_normalization: setting(
      config, "reuse_critic_normalization", false,
    ),
    layer_norm_mode,
    heading_mode: match setting(config, "heading_mode", "stable_fallback") {
      "stable_fallback" => @geometry.StableFallback
      "smc_projected" => @geometry.SmcProjected
      "orthonormal_atlas" => @geometry.OrthonormalAtlas
      _ =>
        fail(
          "heading_mode must be stable_fallback, smc_projected or orthonormal_atlas",
        )
    },
    policy_linear_mode: linear_setting(config, "policy_linear_mode"),
    critic_linear_mode: linear_setting(config, "critic_linear_mode"),
    rotation_error_mode: match
      setting(config, "rotation_error_mode", "quaternion_log") {
      "quaternion_log" => @geometry.QuaternionLog
      "trace_acos" => @geometry.TraceAcos
      "geodesic_squared" => @geometry.GeodesicSquared
      _ =>
        fail(
          "rotation_error_mode must be quaternion_log, trace_acos or geodesic_squared",
        )
    },
    world_linear_mode: match
      setting(config, "world_linear_mode", "matmul_bias") {
      "matmul_bias" => @gpu.MatmulBias
      "native" => @gpu.NativeLinear
      _ => fail("world_linear_mode must be matmul_bias or native")
    },
    critic_cuda_graph: setting(config, "critic_cuda_graph", false),
    gradient_bucket_bytes,
    mlp_precision,
    adam_checked_norm: setting(config, "adam_checked_norm", false),
    defer_scalar_metrics: setting(config, "defer_scalar_metrics", false),
    body_orientation_batched: setting(config, "body_orientation_batched", false),
    actor_norm_snapshot: setting(config, "actor_norm_snapshot", false),
    world_error_batched: setting(config, "world_error_batched", false),
    sparse_joint_axis: setting(config, "sparse_joint_axis", false),
    zero_joint_pivot: setting(config, "zero_joint_pivot", false),
    smc_world_rotation: setting(config, "smc_world_rotation", false),
    smc_xi_normalization: setting(config, "smc_xi_normalization", false),
    smc_actor_return: setting(config, "smc_actor_return", false),
    native_cross: setting(config, "native_cross", false),
    native_cross_preserve_forward: setting(
      config, "native_cross_preserve_forward", false,
    ),
    world_norm_snapshot: setting(config, "world_norm_snapshot", false),
    detached_rotation_constants: setting(
      config, "detached_rotation_constants", false,
    ),
    compact_axis_rotation: setting(config, "compact_axis_rotation", false),
    compact_skew: setting(config, "compact_skew", false),
    fused_axis_rotation: setting(config, "fused_axis_rotation", false),
    fused_skew: setting(config, "fused_skew", false),
    fused_so3_tail: setting(config, "fused_so3_tail", false),
    fused_cross_forward: setting(config, "fused_cross_forward", false),
    fused_cross_vjp: setting(config, "fused_cross_vjp", false),
    fused_so3_coefficients: setting(config, "fused_so3_coefficients", false),
    fused_so3_coefficients_forward: setting(
      config, "fused_so3_coefficients_forward", false,
    ),
    split_so3_coefficients: setting(config, "split_so3_coefficients", false),
    fused_so3_coefficients_full: setting(
      config, "fused_so3_coefficients_full", false,
    ),
    split_actor_return: setting(config, "split_actor_return", false),
    batch_actor_encoder: setting(config, "batch_actor_encoder", false),
    static_fk_pruning: setting(config, "static_fk_pruning", false),
    split_world_delta: setting(config, "split_world_delta", false),
    compact_heading: setting(config, "compact_heading", false),
  }
}

///|
fn linear_setting(config : Json, key : String) -> @gpu.LinearMode raise {
  match setting(config, key, "matmul_bias") {
    "matmul_bias" => @gpu.MatmulBias
    "native" => @gpu.NativeLinear
    _ => fail("\{key} must be matmul_bias or native")
  }
}

///|
fn resident_reference_request(config : Json) -> Int64? raise {
  let enabled : Bool = setting(config, "resident_reference_cache", false)
  guard config is Object(fields) else {
    fail("training config must be a JSON object")
  }
  let mib = match fields.get("resident_reference_max_mib") {
    None => 1024
    Some(Number(value, ..)) if value >= 1.0 &&
      value <= 65536.0 &&
      value.to_int().to_double() == value => value.to_int()
    _ =>
      fail("resident_reference_max_mib must be a JSON integer within 1..65536")
  }
  if enabled {
    Some(mib.to_int64() * 1048576L)
  } else {
    None
  }
}

///|
/// Additional simultaneously live candidate storage; never discounts baseline.
fn optimization_memory_extra(s : Settings) -> Map[String, Int64] {
  let c = s.learner
  let actor_rows = if s.batch_execution.actor_microbatch > 0 {
    s.batch_execution.actor_microbatch.min(c.policy_batch)
  } else {
    c.policy_batch
  }
  let values : Map[String, Int64] = {}
  if s.optimizations.compact_axis_rotation || s.optimizations.compact_skew {
    // Retain every old activation reserve and cover custom-node saved tensors.
    values["execution_compact_rotations"] = 33554432L.max(
      8L * 29L * c.horizon.to_int64() * actor_rows.to_int64() + 1048576L,
    )
  }
  if s.optimizations.fused_axis_rotation || s.optimizations.fused_skew {
    values["execution_fused_rotations"] = 33554432L.max(
      8L * 29L * c.horizon.to_int64() * actor_rows.to_int64() + 1048576L,
    )
  }
  if s.optimizations.fused_so3_tail || s.optimizations.fused_cross_forward {
    values["execution_geometry_tail"] = 33554432L.max(
      4L * 4L * 9L * c.horizon.to_int64() * actor_rows.to_int64() + 1048576L,
    )
  }
  if s.optimizations.fused_cross_vjp || s.optimizations.fused_so3_coefficients {
    values["execution_geometry_vjp"] = 33554432L.max(
      4L * 6L * c.horizon.to_int64() * actor_rows.to_int64() + 1048576L,
    )
  }
  if s.optimizations.fused_so3_coefficients_forward ||
    s.optimizations.split_so3_coefficients {
    values["execution_coefficient_assembly"] = 33554432L
  }
  if s.optimizations.fused_so3_coefficients_full {
    values["execution_coefficient_full"] = 33554432L
  }
  if s.optimizations.split_actor_return {
    values["execution_split_actor_return"] = 33554432L
  }
  if s.optimizations.batch_actor_encoder {
    // Additional staging and activation allowance; do not discount the base.
    values["execution_batch_actor_encoder"] = 1073741824L
  }
  if s.optimizations.split_world_delta {
    values["execution_split_world_delta"] = 33554432L
  }
  if s.optimizations.compact_heading {
    values["execution_compact_heading"] = 67108864L.max(
      128L * (c.horizon.to_int64() + 1L) * actor_rows.to_int64(),
    )
  }
  if s.optimizations.world_norm_snapshot {
    // Only immutable input/output normalization vectors. Do not discount the
    // previous activation allowance or change any memory protection threshold.
    values["execution_world_norm_snapshot"] = 1048576L
  }
  if s.optimizations.smc_world_rotation {
    values["execution_smc_world_rotation"] = 268435456L
  }
  if s.optimizations.smc_actor_return {
    values["execution_smc_actor_return"] = 67108864L
  }
  if s.optimizations.smc_xi_normalization {
    values["execution_smc_xi_normalization"] = 67108864L
  }
  if s.optimizations.world_error_batched {
    // Additional packed predictions/targets and graph workspace. The learner
    // bounds the logical window to 131072 rows before constructing a graph.
    // Preserve every original activation/cache allowance and safety threshold.
    values["execution_world_error_batched"] = 134217728L
  }
  if s.operator_diagnostics {
    // Independent instrumentation allowance, never discounts executed training
    // phases. Nsight buffers, bounded structural report, watchdog and teardown
    // remain covered after the selected capture. This is not a measured peak.
    values["execution_operator_diagnostics"] = 4294967296L
  }
  if s.noise_staging_max_bytes is Some(_) {
    // Same checked dimensions and cap as noise_staging_usage. Preserve all
    // original noise tensors, concat and allocator envelopes in every phase.
    let b = c.policy_batch.to_int64()
    let d = s.mode.dim().to_int64()
    values["execution_noise_logical_staging"] = 32L * b * d +
      8L * c.policy_batch.min(256).to_int64() * d +
      65536L
  }
  if s.optimizations.actor_norm_snapshot {
    // Four small std vectors plus handles/allocator rounding. Means are
    // retained references; no baseline activation reserve is discounted.
    values["execution_actor_norm_snapshot"] = 65536L
  }
  if s.world_staging_max_bytes is Some(_) {
    // Settings and runner both enforce the explicit reserve cap using
    // world_staging_usage. All dimensions are bounded before admission.
    // Keep the entire original host/device/cache envelope in every phase.
    values["execution_world_logical_staging"] = 32L *
      205L *
      c.wm_batch.to_int64() *
      c.wm_window.to_int64() +
      65536L
  }
  if s.optimizations.gradient_bucket_bytes > 0 {
    values["execution_gradient_bucket"] = s.optimizations.gradient_bucket_bytes.to_int64() +
      1048576L
  }
  if s.optimizations.critic_cuda_graph {
    let rows = (
        c.horizon.to_int64() * c.policy_batch.to_int64() +
        c.critic_minibatches.to_int64() -
        1L
      ) /
      c.critic_minibatches.to_int64()
    values["execution_critic_cuda_graph"] = 1073741824L +
      mlp_parameters(184 + 73 * c.goal_frames, c.critic_hidden, 1, false) * 4L +
      2L * rows * (185L + 73L * c.goal_frames.to_int64()) * 4L
  }
  if s.profile_max_spans > 0 {
    // Bounded event handles, labels and report materialization allowance.
    values["execution_profile_events_and_report"] = 67108864L +
      s.profile_max_spans.to_int64() * 4096L
  }
  if s.optimizations.reuse_geometry {
    // G1 tracked bodies are bounded by 64 here (current tracked set is 14).
    // Two FK bundles, 18 Float32 values/body, retained across H actor steps.
    values["execution_geometry_reuse"] = 2L *
      64L *
      18L *
      4L *
      c.horizon.to_int64() *
      actor_rows.to_int64()
  }
  if s.optimizations.body_orientation_batched {
    // Packed robot/reference rotations, broadcast alignment, relative matrices
    // and their backward buffers persist through actor BPTT. Bound 64 bodies
    // and reserve 128 Float32 elements/body/step plus workspace. Do not subtract
    // the preserved original geometry envelope; retain in every phase.
    values["execution_batched_body_orientation"] = 67108864L +
      128L * 4L * 64L * c.horizon.to_int64() * actor_rows.to_int64()
  }
  if s.optimizations.reuse_critic_normalization {
    // Full normalized input plus subtraction temporary, including bootstrap.
    values["execution_critic_normalization_reuse"] = 2L *
      4L *
      (c.horizon.to_int64() + 1L) *
      c.policy_batch.to_int64() *
      (184L + 73L * c.goal_frames.to_int64())
  }
  if s.optimizations.layer_norm_mode == @gpu.Native {
    // Preserve the old network envelope; separately reserve native reduction
    // outputs/workspace. This conservative cushion is not a measured peak.
    values["execution_native_layer_norm_workspace"] = 268435456L
  }
  if s.optimizations.layer_norm_mode == @gpu.FusedTail {
    // Hard kernel cap is16M elements with at most4 temporary gradient fields,
    // plus contiguous incoming gradient and row/affine reductions. Keep every
    // baseline activation reserve and add1GiB in all phases, including startup.
    values["execution_fused_ln_tail_workspace"] = 1073741824L
  }
  if s.resident_reference_max_bytes is Some(cap) {
    if s.reference_fk_cache {
      // 512MiB immutable table, two-table concat construction, FK working
      // tensors and full logical gather. Add2GiB to EVERY existing phase;
      // no reduction of the old memory envelope or safety reserve.
      values["execution_reference_fk_cache"] = 2147483648L
    }
    // Admission precedes loading the full catalog: reserve twice the explicit
    // cap for chunk+concat coexistence, plus the bounded host build working set.
    // Runtime separately rejects an actual table exceeding the cap. Reference
    // tensors always remain FP32 even when the MLP uses BF16.
    let k = c.goal_frames.to_int64()
    let b = c.policy_batch.to_int64()
    values["execution_resident_reference_cache"] = 2L * cap +
      32L * 256L * (71L + 73L * k) +
      65536L * (256L + k + 1L) +
      40L * (c.horizon.to_int64() + 1L) * b +
      8L * b +
      40L * s.environments.to_int64()
  }
  if s.optimizations.defer_scalar_metrics {
    // At most 256 detached scalar tensors and their final stack. Reserve
    // allocator rounding and host handles in addition to the <2 KiB payload.
    values["execution_deferred_scalar_metrics"] = 1048576L
  }
  if s.optimizations.mlp_precision == @gpu.Bf16 {
    let world = mlp_parameters(133, c.wm_hidden, 70, true)
    let policy = mlp_parameters(73 * c.goal_frames, c.policy_hidden, 32, false) +
      mlp_parameters(32 + s.mode.dim() * c.hist, c.policy_hidden, 29, false)
    let critic = mlp_parameters(
      184 + 73 * c.goal_frames,
      c.critic_hidden,
      1,
      false,
    )
    // Per-forward autocast weight tensors can remain live throughout BPTT.
    // Keep all existing FP32 parameter/gradient/Adam and activation reserves;
    // add two-byte casts with a 2x coexistence cushion, retained in every phase
    // for CUDA allocator reuse. Counting LN parameters here is conservative.
    values["execution_bf16_weight_casts"] = 4L *
      (world * c.wm_window.to_int64()).max(
        (world + policy) * c.horizon.to_int64() + critic,
      )
  }
  values
}
