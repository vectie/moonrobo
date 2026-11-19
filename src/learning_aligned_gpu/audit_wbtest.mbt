///|
test "semantic tensor digest slices large strided views and preserves signed zero" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println("SKIP shared-state audit: set MOONROBO_TENSOR_LIBRARY")
    return
  }
  let backend = @tensor.Backend::open(path)
  let input = backend.from_values(
    [65537, 2],
    Array::makei(131074, i => i.to_double()),
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let strided = input.transpose()
  let expected = backend.from_values(
    [2, 65537],
    Array::makei(131074, i => {
      if i < 65537 {
        (i * 2).to_double()
      } else {
        ((i - 65537) * 2 + 1).to_double()
      }
    }),
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let first = tensor_state_digest(strided)
  let second = tensor_state_digest(expected)
  assert_eq(first.sha256, second.sha256)
  assert_eq(first.elements, 131074L)
  let positive = backend.from_values(
    [1],
    [0.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  let negative = backend.from_values(
    [1],
    [-0.0],
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  assert_true(
    tensor_state_digest(positive).sha256 != tensor_state_digest(negative).sha256,
  )
}

///|
test "semantic optimizer audit includes moments steps and options after roundtrip" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    return
  }
  let backend = @tensor.Backend::open(path)
  let w = backend.from_values(
    [2],
    [1.0, -2.0],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  let optimizer = backend.adam([w], learning_rate=0.01, beta2=0.95)
  w.square().mean().backward()
  optimizer.step()
  let saved = optimizer_state_digest("test", optimizer)
  optimizer.save("target/learning-tensor/test-semantic-audit.pt")
  optimizer.set_learning_rate(0.003)
  let changed = optimizer_state_digest("test", optimizer)
  assert_true(saved.sha256 != changed.sha256)
  assert_eq(saved.parameters_sha256, changed.parameters_sha256)
  assert_eq(saved.moments_sha256, changed.moments_sha256)
  optimizer.zero_grad()
  w.square().mean().backward()
  optimizer.step()
  assert_true(
    saved.moments_sha256 !=
    optimizer_state_digest("test", optimizer).moments_sha256,
  )
  optimizer.load("target/learning-tensor/test-semantic-audit.pt")
  assert_eq(saved.sha256, optimizer_state_digest("test", optimizer).sha256)
  // Independent handles/archive identities still have equal semantic state.
  let other = backend.from_values(
    [2],
    [0.0, 0.0],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  let restored = backend.adam([other], learning_rate=0.1)
  restored.load("target/learning-tensor/test-semantic-audit.pt")
  assert_eq(saved.sha256, optimizer_state_digest("test", restored).sha256)
}

///|
test "semantic normalizer audit includes each mean variance and count" {
  let norms : Array[@aligned.NormSnapshot] = Array::makei(5, _ => {
    mean: [0.0],
    variance: [1.0],
    count: 4.0,
  })
  let metadata : CheckpointMetadata = {
    schema: 1,
    config: @aligned.LearnerConfig::default(),
    observation_mode: "paper",
    precision: "float32",
    mlp_precision: None,
    world_linear_mode: None,
    policy_linear_mode: None,
    critic_linear_mode: None,
    rotation_error_mode: None,
    heading_mode: None,
    smc_world_rotation: None,
    smc_xi_normalization: None,
    smc_actor_return: None,
    world_layer_norm_mode: None,
    normalizers: norms,
  }
  let original = normalizer_digest(metadata)
  norms[4] = { mean: [0.0], variance: [1.0], count: 5.0, }
  assert_true(original != normalizer_digest(metadata))
  norms[4] = { mean: [0.0], variance: [1.0], count: 4.0, }
  assert_eq(original, normalizer_digest(metadata))
  norms[2] = { mean: [0.5], variance: [1.0], count: 4.0, }
  assert_true(original != normalizer_digest(metadata))
  norms[2] = { mean: [0.0], variance: [0.5], count: 4.0, }
  assert_true(original != normalizer_digest(metadata))
}

///|
async test "semantic three-network checkpoint readback matches held CPU state" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    return
  }
  let backend = @tensor.Backend::open(path)
  let config = {
    ..@aligned.LearnerConfig::default(),
    wm_hidden: [4],
    policy_hidden: [4],
    critic_hidden: [4],
    hist: 1,
    goal_frames: 1,
  }
  let metadata : CheckpointMetadata = {
    schema: 1,
    config,
    observation_mode: "paper",
    precision: "float32",
    mlp_precision: None,
    world_linear_mode: None,
    policy_linear_mode: None,
    critic_linear_mode: None,
    rotation_error_mode: None,
    heading_mode: None,
    smc_world_rotation: None,
    smc_xi_normalization: None,
    smc_actor_return: None,
    world_layer_norm_mode: None,
    normalizers: [133, 70, 93, 73, 257].map(dim => {
      mean: Array::make(dim, 0.0),
      variance: Array::make(dim, 1.0),
      count: 1.0,
    }),
  }
  let optimizers = audit_optimizers(backend, metadata)
  let directory = "target/learning-tensor/semantic-generation-test-\{@env.now()}"
  @fs.mkdir(directory, recursive=true)
  for i, name in ["world", "policy", "critic"] {
    optimizers[i].save(directory + "/" + name + ".pt")
  }
  let held = shared_state_digest(metadata, optimizers)
  let readback = checkpoint_state_digest(backend, directory, metadata)
  assert_eq(held.sha256, readback.sha256)
  assert_eq(held.normalizers_sha256, readback.normalizers_sha256)
  assert_eq(readback.optimizers.length(), 3)
}
