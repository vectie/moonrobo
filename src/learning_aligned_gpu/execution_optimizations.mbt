///|
/// Optional execution paths; absent configuration retains the reference path.
/// Arithmetic/rotation modes are checkpointed: the SMC rotation clamp changes
/// boundary gradients and must never silently replace a legacy training run.
pub(all) struct ExecutionOptimizations {
  reuse_geometry : Bool
  // Reuse detached reference FK for the differentiable actor tail only.
  // Robot FK and heading/critic derivatives retain the original eager graph.
  tail_reference_fk_cache : Bool
  reuse_critic_normalization : Bool
  layer_norm_mode : LayerNormMode
  world_linear_mode : LinearMode
  policy_linear_mode : LinearMode
  critic_linear_mode : LinearMode
  rotation_error_mode : @geometry.RotationErrorMode
  heading_mode : @geometry.HeadingMode
  critic_cuda_graph : Bool
  gradient_bucket_bytes : Int32
  // Arithmetic mode is a separately measured protocol factor, not a claim of
  // bitwise equivalence with the FP32 reference.
  mlp_precision : MlpPrecision
  adam_checked_norm : Bool
  defer_scalar_metrics : Bool
  body_orientation_batched : Bool
  actor_norm_snapshot : Bool
  world_error_batched : Bool
  sparse_joint_axis : Bool
  zero_joint_pivot : Bool
  smc_world_rotation : Bool
  // Exact upstream ATen graph order, separately admitted and checkpointed.
  smc_source_order : Bool
  smc_xi_normalization : Bool
  smc_actor_return : Bool
  native_cross : Bool
  native_cross_preserve_forward : Bool
  world_norm_snapshot : Bool
  detached_rotation_constants : Bool
  compact_axis_rotation : Bool
  compact_skew : Bool
  static_fk_pruning : Bool
  split_world_delta : Bool
  compact_heading : Bool
  fused_axis_rotation : Bool
  fused_skew : Bool
  fused_so3_tail : Bool
  fused_cross_forward : Bool
  fused_cross_vjp : Bool
  fused_so3_coefficients : Bool
  fused_so3_coefficients_forward : Bool
  // Experimental: numerically identical, but rejected by the 2026-10-28 ABBA.
  fused_so3_coefficients_full : Bool
  split_so3_coefficients : Bool
  split_actor_return : Bool
  // Experimental: the 4096=8x512 full-update numeric gate rejected this route.
  batch_actor_encoder : Bool
} derive(Debug, Eq, ToJson)

///|
pub fn ExecutionOptimizations::default() -> ExecutionOptimizations {
  {
    reuse_geometry: false,
    tail_reference_fk_cache: false,
    reuse_critic_normalization: false,
    layer_norm_mode: Expanded,
    world_linear_mode: MatmulBias,
    policy_linear_mode: MatmulBias,
    critic_linear_mode: MatmulBias,
    rotation_error_mode: @geometry.QuaternionLog,
    heading_mode: @geometry.StableFallback,
    critic_cuda_graph: false,
    gradient_bucket_bytes: 0,
    mlp_precision: Fp32,
    adam_checked_norm: false,
    defer_scalar_metrics: false,
    body_orientation_batched: false,
    actor_norm_snapshot: false,
    world_error_batched: false,
    sparse_joint_axis: false,
    zero_joint_pivot: false,
    smc_world_rotation: false,
    smc_source_order: false,
    smc_xi_normalization: false,
    smc_actor_return: false,
    native_cross: false,
    native_cross_preserve_forward: false,
    world_norm_snapshot: false,
    detached_rotation_constants: false,
    compact_axis_rotation: false,
    compact_skew: false,
    static_fk_pruning: false,
    split_world_delta: false,
    compact_heading: false,
    fused_axis_rotation: false,
    fused_skew: false,
    fused_so3_tail: false,
    fused_cross_forward: false,
    fused_cross_vjp: false,
    fused_so3_coefficients: false,
    fused_so3_coefficients_forward: false,
    fused_so3_coefficients_full: false,
    split_so3_coefficients: false,
    split_actor_return: false,
    batch_actor_encoder: false,
  }
}
