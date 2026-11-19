///|
test "inference compiled package refuses differentiable inputs" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(library) &&
    @env.get_env_var("MOONROBO_CRITIC_FEATURE_PACKAGE") is Some(package_root) else {
    println(
      "SKIP compiled inference guard: set library and critic feature package",
    )
    return
  }
  let backend = @learning_tensor.Backend::open(library)
  let block = backend.load_compiled_block(package_root, cuda_device=0)
  let rotation = backend.from_values(
    [135168, 3, 3],
    Array::make(135168 * 9, 0.0),
    cuda_device=0,
    requires_grad=true,
    dtype=Float32,
  )
  // Input zero has the expected shape/strides. The wrapper must refuse its
  // live gradient before invoking generated inference code or later inputs.
  let rejected = try {
    ignore(block.forward(Array::make(16, rotation)))
    false
  } catch {
    @learning_tensor.TensorError::Native(message) =>
      message.contains("inference-only package refuses differentiable inputs")
  }
  assert_true(rejected)
}
