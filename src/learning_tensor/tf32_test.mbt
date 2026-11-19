///|
test "CPU TF32 extension refuses queries and settings without breaking tensors" {
  guard @env.get_env_var("MOONROBO_TENSOR_TF32_LIBRARY") is Some(path) else {
    println("SKIP TF32 CPU integration: set MOONROBO_TENSOR_TF32_LIBRARY")
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_true(backend.has_cuda_fp32_control())
  assert_eq(backend.cuda_device_count(), 0)
  try backend.cuda_fp32_settings() catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(
        message.contains("CPU/non-CUDA build or no accessible CUDA device"),
      )
  } noraise {
    _ => fail("CPU must not fabricate CUDA precision state")
  }
  try
    backend.configure_cuda_tf32(
      matmul=true,
      cudnn_conv=false,
      cudnn_rnn=false,
      before_first_tensor=true,
    )
  catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(
        message.contains("CPU/non-CUDA build or no accessible CUDA device"),
      )
  } noraise {
    _ => fail("CPU must not report configured CUDA precision")
  }
  try
    backend.configure_cuda_tf32(
      matmul=false,
      cudnn_conv=false,
      cudnn_rnn=false,
      before_first_tensor=false,
    )
  catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("before_first_tensor=true"))
  } noraise {
    _ => fail("startup acknowledgement must be explicit")
  }
  assert_eq(
    backend
    .from_values([1], [3.0], cuda_device=-1, requires_grad=false)
    .square()
    .values(),
    [9.0],
  )
}

///|
test "old ABI2 plugin loads and explicitly rejects missing TF32 extension" {
  guard @env.get_env_var("MOONROBO_TENSOR_LEGACY_LIBRARY") is Some(path) else {
    println("SKIP TF32 legacy integration: set MOONROBO_TENSOR_LEGACY_LIBRARY")
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_false(backend.has_cuda_fp32_control())
  try backend.cuda_fp32_settings() catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(
        message.contains("lacks optional CUDA FP32 precision extension"),
      )
  } noraise {
    _ => fail("missing readback is not success")
  }
  try
    backend.configure_cuda_tf32(
      matmul=false,
      cudnn_conv=false,
      cudnn_rnn=false,
      before_first_tensor=true,
    )
  catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(
        message.contains("lacks optional CUDA FP32 precision extension"),
      )
  } noraise {
    _ => fail("missing configuration is not success")
  }
  assert_eq(
    backend
    .from_values([1], [2.0], cuda_device=-1, requires_grad=false)
    .square()
    .values(),
    [4.0],
  )
}
