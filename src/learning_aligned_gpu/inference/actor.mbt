///|
pub(all) struct ActorSpec {
  format : String
  observation_mode : String
  hist : Int32
  goal_frames : Int32
  hidden : Array[Int32]
  // Existing actor artifacts omit this field and keep FP32 compute.
  mlp_precision : @gpu.MlpPrecision?
  policy_linear_mode : @gpu.LinearMode?
  obs_norm : @aligned.NormSnapshot
  goal_norm : @aligned.NormSnapshot
} derive(ToJson, FromJson)

///|
pub fn ActorSpec::from_checkpoint(
  saved : @gpu.CheckpointMetadata,
) -> ActorSpec raise {
  guard saved.schema == 1 &&
    saved.precision == "float32" &&
    saved.normalizers.length() == 5 else {
    fail(
      "actor requires a Float32 native tensor checkpoint with five normalizers",
    )
  }
  let spec : ActorSpec = {
    format: "moonrobo.native-tensor-actor-spec.v1",
    observation_mode: saved.observation_mode,
    hist: saved.config.hist,
    goal_frames: saved.config.goal_frames,
    hidden: saved.config.policy_hidden,
    mlp_precision: saved.mlp_precision,
    policy_linear_mode: saved.policy_linear_mode,
    obs_norm: saved.normalizers[2],
    goal_norm: saved.normalizers[3],
  }
  spec.validate()
  spec
}

///|
pub fn ActorSpec::mode(self : ActorSpec) -> @aligned.ObservationMode raise {
  match self.observation_mode {
    "paper" => @aligned.Paper
    "smc" => @aligned.Smc
    "observable" => @aligned.Observable
    _ => fail("unsupported actor observation mode")
  }
}

///|
pub fn ActorSpec::validate(self : ActorSpec) -> Unit raise {
  let dim = self.mode().dim()
  guard self.format == "moonrobo.native-tensor-actor-spec.v1" &&
    self.hist > 0 &&
    self.hist <= 10 &&
    self.goal_frames > 0 &&
    self.goal_frames <= 10 &&
    self.hidden.length() <= 4 &&
    self.hidden.all(x => x > 0 && x <= 2048) else {
    fail("actor dimensions exceed bounded native inference profile")
  }
  for
    (norm, width) in [
      (self.obs_norm, dim),
      (self.goal_norm, self.goal_frames * 73),
    ] {
    guard norm.mean.length() == width &&
      norm.variance.length() == width &&
      norm.mean.all(@numeric.finite) &&
      norm.variance.all(x => @numeric.finite(x) && x >= 0.0) &&
      @numeric.finite(norm.count) &&
      norm.count >= 0.0 else {
      fail("invalid actor normalization checkpoint")
    }
  }
}

///|
/// Frozen actor only: no world model, critic, replay, optimizer or gradient tape
/// remains held after loading. Caller verifies archive bytes before this call.
pub struct Actor {
  policy : @gpu.Policy
  spec : ActorSpec
  device : Int32
  archive_parameters : Array[@tensor.Tensor]
}

///|
pub fn Actor::load_archive(
  backend : @tensor.Backend,
  path : String,
  spec : ActorSpec,
  cuda_device~ : Int32 = -1,
) -> Actor raise {
  spec.validate()
  let p = @gpu.Policy::new(
    backend,
    spec.mode().dim(),
    spec.goal_frames * 73,
    @numeric.Rng::new(1U),
    hist=spec.hist,
    hidden=spec.hidden,
    mlp_precision=spec.mlp_precision.unwrap_or(Fp32),
    linear_mode=spec.policy_linear_mode.unwrap_or(MatmulBias),
    cuda_device~,
  )
  // The native archive stores parameters with Adam. This temporary loader also
  // consumes any saved moments, then releases them when the function returns.
  let loader = backend.adam(p.parameters(), beta2=0.95)
  loader.load(path)
  for
    (norm, saved) in [
      (p.obs_norm, spec.obs_norm),
      (p.goal_norm, spec.goal_norm),
    ] {
    norm.mean = backend.from_values(
      [norm.dim],
      saved.mean,
      cuda_device~,
      requires_grad=false,
      dtype=Float32,
    )
    norm.variance = backend.from_values(
      [norm.dim],
      saved.variance,
      cuda_device~,
      requires_grad=false,
      dtype=Float32,
    )
    norm.count = saved.count
  }
  let frozen : @gpu.Policy = {
    ..p,
    encoder: p.encoder.frozen(),
    decoder: p.decoder.frozen(),
  }
  // Hashing visits bounded chunks and rejects nonfinite values before inference.
  for parameter in frozen.parameters() {
    ignore(@gpu.tensor_state_digest(parameter))
  }
  // Keep the original leaf aliases only for archive serialization. They share
  // storage with frozen parameters; forward never reads gradient-enabled leaves.
  {
    policy: frozen,
    spec,
    device: cuda_device,
    archive_parameters: p.parameters(),
  }
}

///|
/// Export the exact actor parameters using a fresh native archive with empty
/// optimizer state. This is a LibTorch/MoonBit artifact, not TorchScript or ONNX.
pub fn Actor::save_archive(self : Actor, path : String) -> Unit raise {
  self.policy.backend.adam(self.archive_parameters, beta2=0.95).save(path)
}

///|
pub fn Actor::parameter_digests(
  self : Actor,
) -> Array[@gpu.TensorStateDigest] raise {
  self.policy.parameters().map(@gpu.tensor_state_digest)
}

///|
/// Frozen actor parameter count in archive order: encoder layers, then decoder
/// layers, with row-major [out,in] weights followed by bias for each layer.
pub fn Actor::parameter_count(self : Actor) -> Int32 {
  self.archive_parameters.length()
}

///|
/// One explicit host transfer for offline portable export. This is not a
/// control-loop interface and never exposes optimizer state.
pub fn Actor::parameter_values(
  self : Actor,
  index : Int32,
) -> Array[Double] raise {
  guard self.archive_parameters.get(index) is Some(parameter) else {
    fail("actor parameter index out of range")
  }
  parameter.values()
}

///|
/// Input is oldest-to-newest history of raw, unnormalized aligned
/// observations, plus the unnormalized 73D-per-frame reference preview. Returns
/// raw policy action, matching the preserved Python/scalar full-clip evaluator.
pub fn Actor::forward(
  self : Actor,
  history : Array[Array[Double]],
  goal : Array[Double],
) -> Array[Double] raise {
  let dim = self.spec.mode().dim()
  guard history.length() == self.spec.hist &&
    history.all(row => row.length() == dim && row.all(@numeric.finite)) &&
    goal.length() == self.spec.goal_frames * 73 &&
    goal.all(@numeric.finite) else {
    fail("actor history/preview shape or finite-value mismatch")
  }
  let flat = []
  for row in history {
    flat.append(row)
  }
  let b = self.policy.backend
  let result = self.policy
    .forward(
      b.from_values(
        [1, self.spec.hist, dim],
        flat,
        cuda_device=self.device,
        requires_grad=false,
        dtype=Float32,
      ),
      b.from_values(
        [1, self.spec.goal_frames * 73],
        goal,
        cuda_device=self.device,
        requires_grad=false,
        dtype=Float32,
      ),
    )
    .values()
  guard result.length() == 29 && result.all(@numeric.finite) else {
    fail("actor returned invalid actions")
  }
  result
}

///|
pub fn ActorSpec::contract(self : ActorSpec) -> Json raise {
  self.validate()
  let contract : Json = {
    "precision": "float32",
    "control_hz": 50,
    "history_order": "oldest-to-newest; repeat first observation after reset",
    "observations": "learning_aligned.observation; already feature-scaled; saved normalization applied by actor",
    "observation_mode": Json(self.observation_mode),
    "observation_dim": Json(self.mode().dim()),
    "history_frames": Json(self.hist),
    "preview_frames": Json(self.goal_frames),
    "preview": "MotionLibrary.goal(frame, goal_frames); 73 values per frame; clip-end clamped",
    "state_quaternion_order": "wxyz",
    "joints": Json(@aligned.joint_names()),
    "default_q": Json(@aligned.default_joint_positions()),
    "action_scales": Json(
      @aligned.joint_names().map(n => @aligned.motor_of(n).action_scale()),
    ),
    "action_to_setpoint": "default_q + scale * raw_action; zero calibration; evaluation has no exploration or collection clamp",
    "encoder": "ELU hidden layers; tanh 32-dimensional latent",
    "decoder": "ELU hidden layers; linear 29-dimensional output",
    "normalization": "(input - mean) / sqrt(variance + 0.01^2)",
    "deployment": "G1 simulation; Noetix E1 retargeting and hardware validation not included",
  }
  // Preserve the exact legacy FP32 contract, which is integrity-checked when
  // loading existing exported actor manifests. BF16 compute is explicit even
  // though parameters, normalizers, inputs and returned actions remain FP32.
  if self.mlp_precision.unwrap_or(Fp32) == @gpu.Bf16 {
    guard contract is Object(fields) else { fail("actor contract object") }
    fields["mlp_precision"] = "bf16"
  }
  if self.policy_linear_mode.unwrap_or(MatmulBias) == @gpu.NativeLinear {
    guard contract is Object(fields) else {
      fail("actor contract must be object")
    }
    fields["policy_linear_mode"] = "native"
  }
  contract
}
