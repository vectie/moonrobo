///|
test "SMC MLP keeps native Linear and LayerNorm when frozen" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    println(
      "SKIP SMC MLP frozen execution contract: set MOONROBO_TENSOR_LIBRARY",
    )
    return
  }
  let backend = @tensor.Backend::open(path)
  let net = @learning_aligned_gpu.Network::new(
    backend,
    [3, 8, 2],
    @numeric.Rng::new(7U),
    activation=Silu,
    layer_norm=true,
    layer_norm_mode=Native,
    linear_mode=NativeLinear,
  )
  let frozen = net.frozen()
  assert_eq(frozen.linear_mode, @learning_aligned_gpu.NativeLinear)
  assert_eq(frozen.layer_norm_mode, @learning_aligned_gpu.Native)
  let x = backend.from_values(
    [2, 3],
    [0.1, -0.2, 0.3, 0.4, -0.5, 0.6],
    cuda_device=-1,
    requires_grad=true,
    dtype=Float32,
  )
  frozen.forward(x).square().mean().backward()
  assert_true(x.gradient_values().any(v => v.abs() > 1.0e-8))
  for p in net.parameters() {
    try p.gradient_values() catch {
      @tensor.TensorError::Native(_) => ()
    } noraise {
      _ => fail("frozen SMC MLP accumulated parameter gradients")
    }
  }
}

///|
test "native LayerNorm network preserves initialization and frozen input gradients" {
  let device = match @env.get_env_var("MOONROBO_OPTIMIZATION_TEST_DEVICE") {
    None => -1
    Some("cuda:0") => 0
    Some(_) => fail("MOONROBO_OPTIMIZATION_TEST_DEVICE must be cuda:0 when set")
  }
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    guard device < 0 else {
      fail("explicit CUDA LayerNorm test requires MOONROBO_TENSOR_LIBRARY")
    }
    println(
      "SKIP native LayerNorm network integration: set MOONROBO_TENSOR_LIBRARY",
    )
    return
  }
  let backend = @tensor.Backend::open(path)
  guard device < 0 || backend.cuda_device_count() > device else {
    fail("explicit CUDA LayerNorm test requires an available CUDA device")
  }
  guard backend.has_layer_norm() else {
    fail("native LayerNorm extension required")
  }
  let baseline = @learning_aligned_gpu.Network::new(
    backend,
    [3, 8, 4, 2],
    @numeric.Rng::new(7U),
    cuda_device=device,
    activation=Silu,
    layer_norm=true,
  )
  let candidate = @learning_aligned_gpu.Network::new(
    backend,
    [3, 8, 4, 2],
    @numeric.Rng::new(7U),
    cuda_device=device,
    activation=Silu,
    layer_norm=true,
    layer_norm_mode=Native,
  )
  assert_eq(baseline.layer_norm_mode, @learning_aligned_gpu.Expanded)
  assert_eq(candidate.layer_norm_mode, @learning_aligned_gpu.Native)
  let bp = baseline.parameters()
  let cp = candidate.parameters()
  assert_eq(bp.length(), cp.length())
  for i in 0..<bp.length() {
    assert_eq(bp[i].values(), cp[i].values())
  }
  let frozen = candidate.frozen()
  assert_eq(frozen.layer_norm_mode, @learning_aligned_gpu.Native)
  let input = backend.from_values(
    [2, 3],
    [0.1, -0.2, 0.3, 0.4, -0.5, 0.6],
    cuda_device=device,
    requires_grad=true,
    dtype=Float32,
  )
  let reference_input = backend.from_values(
    [2, 3],
    [0.1, -0.2, 0.3, 0.4, -0.5, 0.6],
    cuda_device=device,
    requires_grad=true,
    dtype=Float32,
  )
  let output = frozen.forward(input)
  let reference = baseline.frozen().forward(reference_input)
  layer_norm_network_near(
    output.values(),
    reference.values(),
    "device=\{device} frozen-forward",
  )
  output.square().mean().backward()
  reference.square().mean().backward()
  layer_norm_network_near(
    input.gradient_values(),
    reference_input.gradient_values(),
    "device=\{device} frozen-input-gradient",
  )
  assert_true(input.gradient_values().any(v => v.abs() > 1.0e-8))
  for parameter in cp {
    try parameter.gradient_values() catch {
      @tensor.TensorError::Native(_) => ()
    } noraise {
      _ =>
        fail("frozen native LayerNorm must not accumulate parameter gradients")
    }
  }
}

///|
// Preserve this network test's existing absolute gate. Labels only identify
// which comparison failed; the tensor-level combined gate remains separate.
fn layer_norm_network_near(
  actual : Array[Double],
  expected : Array[Double],
  label : String,
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    guard (actual[i] - expected[i]).abs() <= 2.0e-6 else {
      fail(
        "LayerNorm network parity [\{label}] at \{i}: \{actual[i]} vs \{expected[i]}, limit 0.000002",
      )
    }
  }
}
