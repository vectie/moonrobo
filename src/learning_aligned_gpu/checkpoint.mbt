///|
pub(all) struct CheckpointMetadata {
  schema : Int32
  config : @aligned.LearnerConfig
  observation_mode : String
  precision : String
  // Absent in existing schema-1 checkpoints: interpret as FP32 compute.
  mlp_precision : MlpPrecision?
  // Missing fields preserve legacy arithmetic. Execution choices affect
  // floating point trajectories even when the mathematical objective agrees.
  world_linear_mode : LinearMode?
  world_layer_norm_mode : LayerNormMode?
  policy_linear_mode : LinearMode?
  critic_linear_mode : LinearMode?
  rotation_error_mode : @geometry.RotationErrorMode?
  heading_mode : @geometry.HeadingMode?
  smc_world_rotation : Bool?
  smc_xi_normalization : Bool?
  smc_actor_return : Bool?
  normalizers : Array[@aligned.NormSnapshot]
} derive(ToJson, FromJson)

///|
fn Learner::normalizers(self : Learner) -> Array[RunningNorm] {
  [
    self.world.input_norm,
    self.world.output_norm,
    self.policy.obs_norm,
    self.policy.goal_norm,
    self.critic.norm,
  ]
}

///|
fn Learner::mode_name(self : Learner) -> String {
  match self.mode {
    Paper => "paper"
    Smc => "smc"
    Observable => "observable"
  }
}

///|
pub fn Learner::checkpoint_metadata(self : Learner) -> CheckpointMetadata raise {
  {
    schema: 1,
    config: self.config,
    observation_mode: self.mode_name(),
    precision: "float32",
    mlp_precision: Some(self.optimizations.mlp_precision),
    world_linear_mode: Some(self.optimizations.world_linear_mode),
    world_layer_norm_mode: Some(self.optimizations.layer_norm_mode),
    policy_linear_mode: Some(self.optimizations.policy_linear_mode),
    critic_linear_mode: Some(self.optimizations.critic_linear_mode),
    rotation_error_mode: Some(self.optimizations.rotation_error_mode),
    heading_mode: Some(self.optimizations.heading_mode),
    smc_world_rotation: Some(self.optimizations.smc_world_rotation),
    smc_xi_normalization: Some(self.optimizations.smc_xi_normalization),
    smc_actor_return: Some(self.optimizations.smc_actor_return),
    normalizers: self
    .normalizers()
    .map(norm => {
      mean: norm.mean.values(),
      variance: norm.variance.values(),
      count: norm.count,
    }),
  }
}

///|
/// Restores only after validating all metadata and normalization values.
pub fn Learner::restore_metadata(
  self : Learner,
  saved : CheckpointMetadata,
) -> Unit raise {
  guard self.collective is None else {
    fail(
      "native distributed resume requires synchronized optimizer and rank-local physics/replay manifest verification; currently unsupported",
    )
  }
  guard saved.schema == 1 &&
    saved.config.to_json() == self.config.to_json() &&
    saved.observation_mode == self.mode_name() &&
    saved.precision == "float32" &&
    saved.mlp_precision.unwrap_or(Fp32) == self.optimizations.mlp_precision &&
    saved.world_linear_mode.unwrap_or(MatmulBias) ==
    self.optimizations.world_linear_mode &&
    saved.world_layer_norm_mode.unwrap_or(Expanded) ==
    self.optimizations.layer_norm_mode &&
    saved.policy_linear_mode.unwrap_or(MatmulBias) ==
    self.optimizations.policy_linear_mode &&
    saved.critic_linear_mode.unwrap_or(MatmulBias) ==
    self.optimizations.critic_linear_mode &&
    saved.rotation_error_mode.unwrap_or(@geometry.QuaternionLog) ==
    self.optimizations.rotation_error_mode &&
    saved.heading_mode.unwrap_or(@geometry.StableFallback) ==
    self.optimizations.heading_mode &&
    saved.smc_world_rotation.unwrap_or(false) ==
    self.optimizations.smc_world_rotation &&
    saved.smc_xi_normalization.unwrap_or(false) ==
    self.optimizations.smc_xi_normalization &&
    saved.smc_actor_return.unwrap_or(false) ==
    self.optimizations.smc_actor_return else {
    fail("GPU learner checkpoint metadata/configuration differs")
  }
  let norms = self.normalizers()
  guard saved.normalizers.length() == norms.length() else {
    fail("GPU learner checkpoint normalizer count differs")
  }
  let tensors = []
  for i, norm in norms {
    let n = saved.normalizers[i]
    guard n.mean.length() == norm.dim &&
      n.variance.length() == norm.dim &&
      n.count >= 0.0 &&
      n.count < 1.0e300 &&
      n.mean.all(x => x == x && x.abs() < 1.0e300) &&
      n.variance.all(x => x >= 0.0 && x < 1.0e300) else {
      fail("invalid normalization checkpoint")
    }
    tensors.push(
      (
        self.backend.from_values(
          [norm.dim],
          n.mean,
          cuda_device=self.cuda_device,
          requires_grad=false,
          dtype=Float32,
        ),
        self.backend.from_values(
          [norm.dim],
          n.variance,
          cuda_device=self.cuda_device,
          requires_grad=false,
          dtype=Float32,
        ),
      ),
    )
  }
  for i, norm in norms {
    let (mean, variance) = tensors[i]
    norm.mean = mean
    norm.variance = variance
    norm.count = saved.normalizers[i].count
  }
}

///|
/// Caller creates and publishes an immutable generation directory atomically,
/// alongside metadata/RNG/replay/environment and artifact identity.
pub fn Learner::save_optimizers(
  self : Learner,
  directory : String,
) -> Unit raise {
  self.opt_world.save(directory + "/world.pt")
  self.opt_policy.save(directory + "/policy.pt")
  self.opt_critic.save(directory + "/critic.pt")
}

///|
/// Restore into a fresh learner; discard it if any file fails verification/load.
/// The outer checkpoint must verify all three files before calling this method.
pub fn Learner::load_optimizers(
  self : Learner,
  directory : String,
) -> Unit raise {
  guard self.collective is None else {
    fail("native distributed optimizer resume is currently unsupported")
  }
  self.opt_world.load(directory + "/world.pt")
  self.opt_policy.load(directory + "/policy.pt")
  self.opt_critic.load(directory + "/critic.pt")
}
