///|
pub(all) struct TensorStateDigest {
  sha256 : String
  dtype : String
  shape : Array[Int32]
  elements : Int64
} derive(ToJson, FromJson)

///|
fn digest_field(hash : @crypto.SHA256, label : String, bytes : Bytes) -> Unit {
  hash.update(
    @utf8.encode("\{label.length()}:" + label + ":\{bytes.length()}:"),
  )
  hash.update(bytes)
}

///|
fn digest_values(hash : @crypto.SHA256, values : Array[Double]) -> Unit raise {
  guard values.length() <= 65536 && values.all(@numeric.finite) else {
    fail(
      "shared-state audit requires finite tensors and at most 65536 values per chunk",
    )
  }
  // Float32 -> Float64 is exact, including signed zero. Hash explicit LE IEEE
  // bits instead of decimal formatting or process-specific archive identities.
  let bytes = Bytes::makei(values.length() * 8, i => {
    (values[i / 8].reinterpret_as_uint64() >> (i % 8 * 8)).to_byte()
  })
  hash.update(bytes)
}

///|
/// Bounded host export, no gradient graph or optimizer mutation. This digest is
/// semantic for finite floating tensors; dtype and logical shape remain part of
/// the identity. Slice before materializing so even noncontiguous views cannot
/// cause a full-tensor host conversion.
pub fn tensor_state_digest(value : @tensor.Tensor) -> TensorStateDigest raise {
  let dtype = match value.dtype() {
    Float32 => "float32"
    Float64 => "float64"
    BFloat16 => "bfloat16"
    _ => fail("shared learner audit accepts floating tensors only")
  }
  let shape = value.shape()
  let mut elements = 1L
  for width in shape {
    guard width >= 0 &&
      (width == 0 || elements <= 2147483647L / width.to_int64()) else {
      fail("audit tensor shape exceeds bounded indexing")
    }
    elements *= width.to_int64()
  }
  let hash = @crypto.SHA256::new()
  digest_field(hash, "schema", @utf8.encode("moonrobo.finite-tensor-state.v1"))
  digest_field(hash, "dtype", @utf8.encode(dtype))
  digest_field(hash, "shape", @utf8.encode(shape.to_json().stringify()))
  digest_tensor_chunks(hash, value.stop_gradient(), shape, 0, elements)
  {
    sha256: @crypto.bytes_to_hex_string(hash.finalize()),
    dtype,
    shape,
    elements,
  }
}

///|
fn digest_tensor_chunks(
  hash : @crypto.SHA256,
  value : @tensor.Tensor,
  shape : Array[Int32],
  axis : Int32,
  elements : Int64,
) -> Unit raise {
  if elements <= 65536L {
    digest_values(hash, value.values())
    return
  }
  guard axis < shape.length() && shape[axis] > 0 else {
    fail("invalid audit slicing dimensions")
  }
  let per_row = elements / shape[axis].to_int64()
  let rows = if per_row > 65536L { 1 } else { (65536L / per_row).to_int() }
  for start = 0; start < shape[axis]; {
    let count = (shape[axis] - start).min(rows)
    let block = value.narrow(axis, start, count)
    digest_tensor_chunks(
      hash,
      block,
      shape,
      axis + 1,
      per_row * count.to_int64(),
    )
    continue start + count
  }
}

///|
fn digest_array(
  hash : @crypto.SHA256,
  label : String,
  values : Array[Double],
) -> Unit raise {
  digest_field(hash, label + "-length", @utf8.encode("\{values.length()}"))
  for start = 0; start < values.length(); {
    let count = (values.length() - start).min(65536)
    digest_values(hash, values[start:start + count].to_owned())
    continue start + count
  }
}

///|
fn normalizer_digest(metadata : CheckpointMetadata) -> String raise {
  guard metadata.schema == 1 &&
    metadata.precision == "float32" &&
    metadata.normalizers.length() == 5 else {
    fail("unsupported learner metadata for shared-state audit")
  }
  let hash = @crypto.SHA256::new()
  digest_field(hash, "schema", @utf8.encode("moonrobo.normalizer-state.v1"))
  for i, norm in metadata.normalizers {
    guard norm.mean.length() == norm.variance.length() &&
      norm.count >= 0.0 &&
      @numeric.finite(norm.count) &&
      norm.variance.all(x => x >= 0.0) else {
      fail("invalid normalizer metadata in checkpoint")
    }
    digest_array(hash, "norm-\{i}-mean", norm.mean)
    digest_array(hash, "norm-\{i}-variance", norm.variance)
    digest_values(hash, [norm.count])
  }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
fn validate_audit_metadata(metadata : CheckpointMetadata) -> Unit raise {
  let c = metadata.config
  let mode = match metadata.observation_mode {
    "paper" => @aligned.Paper
    "smc" => @aligned.Smc
    "observable" => @aligned.Observable
    _ => fail("unsupported checkpoint observation mode")
  }
  guard metadata.schema == 1 &&
    metadata.precision == "float32" &&
    c.hist > 0 &&
    c.hist <= 10 &&
    c.goal_frames > 0 &&
    c.goal_frames <= 10 &&
    c.wm_hidden.length() <= 3 &&
    c.policy_hidden.length() <= 4 &&
    c.critic_hidden.length() <= 4 &&
    c.wm_hidden.all(w => w > 0 && w <= 2048) &&
    c.policy_hidden.all(w => w > 0 && w <= 2048) &&
    c.critic_hidden.all(w => w > 0 && w <= 1024) &&
    @numeric.finite(c.learning_rate) &&
    c.learning_rate > 0.0 else {
    fail("checkpoint model dimensions exceed the bounded native audit profile")
  }
  let dims = [133, 70, mode.dim(), 73 * c.goal_frames, 184 + 73 * c.goal_frames]
  guard metadata.normalizers.length() == dims.length() else {
    fail("checkpoint normalizer count differs")
  }
  for i, norm in metadata.normalizers {
    guard norm.mean.length() == dims[i] && norm.variance.length() == dims[i] else {
      fail("checkpoint normalizer dimensions differ")
    }
  }
  ignore(normalizer_digest(metadata))
}

///|
/// Allocates only CPU parameters and optimizer slots for one generation. This
/// does not construct a simulator, reference library, learner or replay buffer.
fn audit_optimizers(
  backend : @tensor.Backend,
  metadata : CheckpointMetadata,
) -> Array[@tensor.Adam] raise {
  validate_audit_metadata(metadata)
  let c = metadata.config
  let rng = @numeric.Rng::new(1U)
  let dim = match metadata.observation_mode {
    "paper" => 93
    "smc" => 99
    "observable" => 102
    _ => fail("unsupported checkpoint observation mode")
  }
  let world = WorldModel::new(backend, rng, hidden=c.wm_hidden)
  let policy = Policy::new(
    backend,
    dim,
    73 * c.goal_frames,
    rng,
    hist=c.hist,
    hidden=c.policy_hidden,
  )
  let critic = Critic::new(
    backend,
    184 + 73 * c.goal_frames,
    rng,
    hidden=c.critic_hidden,
  )
  [
    backend.adam(world.net.parameters(), learning_rate=c.learning_rate),
    backend.adam(policy.parameters(), learning_rate=c.learning_rate, beta2=0.95),
    backend.adam(critic.net.parameters(), learning_rate=c.learning_rate),
  ]
}

///|
struct AdamAuditState {
  present : Bool
  step : Int64
} derive(ToJson, FromJson)

///|
struct AdamAuditGroup {
  indices : Array[Int32]
  learning_rate : Double
  beta1 : Double
  beta2 : Double
  eps : Double
  weight_decay : Double
  amsgrad : Bool
} derive(ToJson, FromJson)

///|
struct AdamAuditMetadata {
  parameter_count : Int32
  states : Array[AdamAuditState]
  groups : Array[AdamAuditGroup]
} derive(ToJson, FromJson)

///|
pub(all) struct OptimizerStateDigest {
  name : String
  sha256 : String
  parameters_sha256 : String
  moments_sha256 : String
  metadata_sha256 : String
  metadata : Json
  parameter_elements : Int64
  moment_elements : Int64
} derive(ToJson, FromJson)

///|
pub(all) struct SharedStateDigest {
  format : String
  sha256 : String
  learner_config_sha256 : String
  normalizers_sha256 : String
  optimizers : Array[OptimizerStateDigest]
  host_chunk_values : Int32
} derive(ToJson, FromJson)

///|
fn sha_text(text : String) -> String {
  let hash = @crypto.SHA256::new()
  hash.update(@utf8.encode(text))
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
fn optimizer_state_digest(
  name : String,
  optimizer : @tensor.Adam,
) -> OptimizerStateDigest raise {
  let encoded = optimizer.audit_metadata()
  guard encoded.length() <= 1048576 else {
    fail("optimizer audit metadata exceeds bound")
  }
  let metadata : AdamAuditMetadata = @json.from_json(@json.parse(encoded))
  let n = metadata.parameter_count
  guard n > 0 &&
    n <= 4096 &&
    metadata.states.length() == n &&
    !metadata.groups.is_empty() &&
    metadata.groups.length() <= 64 else {
    fail("invalid optimizer audit layout")
  }
  let assigned = Array::make(n, false)
  let amsgrad = Array::make(n, false)
  for group in metadata.groups {
    guard group.indices.length() <= n &&
      group.learning_rate > 0.0 &&
      group.eps > 0.0 &&
      group.beta1 >= 0.0 &&
      group.beta1 < 1.0 &&
      group.beta2 >= 0.0 &&
      group.beta2 < 1.0 &&
      group.weight_decay >= 0.0 &&
      [
        group.learning_rate,
        group.eps,
        group.beta1,
        group.beta2,
        group.weight_decay,
      ].all(@numeric.finite) else {
      fail("invalid optimizer hyperparameters in audit")
    }
    for index in group.indices {
      guard index >= 0 && index < n && !assigned[index] else {
        fail("optimizer audit parameter ordering is invalid")
      }
      assigned[index] = true
      amsgrad[index] = group.amsgrad
    }
  }
  guard assigned.all(x => x) else { fail("optimizer audit omits parameters") }
  let parameters = @crypto.SHA256::new()
  let moments = @crypto.SHA256::new()
  let mut parameter_elements = 0L
  let mut moment_elements = 0L
  for i in 0..<n {
    let state = metadata.states[i]
    guard state.step >= 0L && (state.present || state.step == 0L) else {
      fail("invalid Adam step in audit")
    }
    let parameter = tensor_state_digest(optimizer.audit_tensor(i))
    digest_field(
      parameters,
      "parameter-\{i}",
      @utf8.encode(parameter.to_json().stringify()),
    )
    parameter_elements += parameter.elements
    if state.present {
      for kind in 1..<(if amsgrad[i] { 4 } else { 3 }) {
        let moment = tensor_state_digest(optimizer.audit_tensor(i, kind~))
        guard moment.shape == parameter.shape && moment.dtype == parameter.dtype else {
          fail("Adam moment shape/dtype differs from its parameter")
        }
        digest_field(
          moments,
          "parameter-\{i}-moment-\{kind}",
          @utf8.encode(moment.to_json().stringify()),
        )
        moment_elements += moment.elements
      }
    }
  }
  let parameters_sha256 = @crypto.bytes_to_hex_string(parameters.finalize())
  let moments_sha256 = @crypto.bytes_to_hex_string(moments.finalize())
  let metadata_json = metadata.to_json()
  let metadata_sha256 = sha_text(metadata_json.stringify())
  let total = @crypto.SHA256::new()
  digest_field(total, "schema", @utf8.encode("moonrobo.optimizer-state.v1"))
  for
    (label, value) in [
      ("parameters", parameters_sha256),
      ("moments", moments_sha256),
      ("metadata", metadata_sha256),
    ] {
    digest_field(total, label, @utf8.encode(value))
  }
  {
    name,
    sha256: @crypto.bytes_to_hex_string(total.finalize()),
    parameters_sha256,
    moments_sha256,
    metadata_sha256,
    metadata: metadata_json,
    parameter_elements,
    moment_elements,
  }
}

///|
fn shared_state_digest(
  metadata : CheckpointMetadata,
  optimizers : Array[@tensor.Adam],
) -> SharedStateDigest raise {
  validate_audit_metadata(metadata)
  guard optimizers.length() == 3 else {
    fail("world/policy/critic optimizers required")
  }
  let config : Json = {
    "schema": metadata.schema,
    "precision": metadata.precision,
    "observation_mode": metadata.observation_mode,
    "config": Json(metadata.config),
  }
  // Preserve existing FP32 fingerprints (absent and explicit Fp32 are the
  // same protocol), while BF16 compute cannot attest as an FP32 checkpoint.
  if metadata.mlp_precision.unwrap_or(Fp32) == Bf16 {
    guard config is Object(fields) else { fail("invalid audit config object") }
    fields["mlp_precision"] = Json("bf16")
  }
  if metadata.world_linear_mode.unwrap_or(MatmulBias) != MatmulBias ||
    metadata.world_layer_norm_mode.unwrap_or(Expanded) != Expanded {
    guard config is Object(fields) else { fail("invalid audit config object") }
    fields["world_linear_mode"] = Json(
      metadata.world_linear_mode.unwrap_or(MatmulBias),
    )
    fields["world_layer_norm_mode"] = Json(
      metadata.world_layer_norm_mode.unwrap_or(Expanded),
    )
  }
  if metadata.policy_linear_mode.unwrap_or(MatmulBias) != MatmulBias ||
    metadata.critic_linear_mode.unwrap_or(MatmulBias) != MatmulBias ||
    metadata.rotation_error_mode.unwrap_or(@geometry.QuaternionLog) !=
    @geometry.QuaternionLog {
    guard config is Object(fields) else { fail("invalid audit config object") }
    fields["policy_linear_mode"] = Json(
      metadata.policy_linear_mode.unwrap_or(MatmulBias),
    )
    fields["critic_linear_mode"] = Json(
      metadata.critic_linear_mode.unwrap_or(MatmulBias),
    )
    fields["rotation_error_mode"] = Json(
      metadata.rotation_error_mode.unwrap_or(@geometry.QuaternionLog),
    )
  }
  if metadata.heading_mode.unwrap_or(@geometry.StableFallback) !=
    @geometry.StableFallback {
    guard config is Object(fields) else { fail("invalid audit config object") }
    fields["heading_mode"] = Json(
      metadata.heading_mode.unwrap_or(@geometry.StableFallback),
    )
  }
  for
    (key, enabled) in [
      ("smc_world_rotation", metadata.smc_world_rotation.unwrap_or(false)),
      ("smc_source_order", metadata.smc_source_order.unwrap_or(false)),
      ("smc_xi_normalization", metadata.smc_xi_normalization.unwrap_or(false)),
      ("smc_actor_return", metadata.smc_actor_return.unwrap_or(false)),
    ] {
    if enabled {
      guard config is Object(fields) else { fail("invalid audit config") }
      fields[key] = Json(true)
    }
  }
  let learner_config_sha256 = sha_text(config.stringify())
  let normalizers_sha256 = normalizer_digest(metadata)
  let names = ["world", "policy", "critic"]
  let digests = Array::makei(3, i => {
    optimizer_state_digest(names[i], optimizers[i])
  })
  let hash = @crypto.SHA256::new()
  digest_field(hash, "schema", @utf8.encode("moonrobo.shared-learner-state.v1"))
  digest_field(hash, "config", @utf8.encode(learner_config_sha256))
  digest_field(hash, "normalizers", @utf8.encode(normalizers_sha256))
  for digest in digests {
    digest_field(hash, digest.name, @utf8.encode(digest.sha256))
  }
  {
    format: "moonrobo.shared-learner-state.v1",
    sha256: @crypto.bytes_to_hex_string(hash.finalize()),
    learner_config_sha256,
    normalizers_sha256,
    optimizers: digests,
    host_chunk_values: 65536,
  }
}

///|
/// Read actual held parameters, optimizer state and normalizers. Excludes replay,
/// physics, collection RNG and sampler estimates, which are rank-local by design.
pub fn Learner::shared_state_digest(self : Learner) -> SharedStateDigest raise {
  shared_state_digest(self.checkpoint_metadata(), [
    self.opt_world,
    self.opt_policy,
    self.opt_critic,
  ])
}

///|
/// All ranks call before checkpoint publication. A mismatch aborts this run;
/// this attests learner consistency, not physics equivalence or convergence.
pub fn Learner::attest_shared_state(self : Learner) -> SharedStateDigest raise {
  errdefer self.abort_distributed()
  let digest = self.prepare_collective("shared-state digest", () => {
    self.shared_state_digest()
  })
  self.assert_same_signature("shared learner and Adam state", digest.sha256)
  digest
}

///|
/// Audit trusted, already hash-verified native archives on CPU only. Loads one
/// generation, never restores replay/physics or starts a training update.
pub fn checkpoint_state_digest(
  backend : @tensor.Backend,
  directory : String,
  metadata : CheckpointMetadata,
) -> SharedStateDigest raise {
  let optimizers = audit_optimizers(backend, metadata)
  for i, name in ["world", "policy", "critic"] {
    optimizers[i].load(directory + "/" + name + ".pt")
  }
  shared_state_digest(metadata, optimizers)
}
