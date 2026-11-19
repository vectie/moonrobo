///|
test "CUDA memory snapshot preserves exact Int64 counters through JSON" {
  let snapshot : @learning_tensor.CudaMemoryStats = {
    device: 3,
    synchronized: false,
    allocated_current_bytes: 9007199254740993L,
    allocated_peak_bytes: 9007199254740994L,
    reserved_current_bytes: 9007199254740995L,
    reserved_peak_bytes: 9007199254740996L,
    cuda_free_bytes: 9007199254740997L,
    cuda_total_bytes: 9007199254740998L,
  }
  let restored : @learning_tensor.CudaMemoryStats = @json.from_json(
    @json.parse(snapshot.to_json().stringify()),
  )
  assert_eq(restored, snapshot)
}

///|
test "new telemetry CPU plugin rejects unsupported queries and resets" {
  guard @env.get_env_var("MOONROBO_TENSOR_TELEMETRY_LIBRARY") is Some(path) else {
    println(
      "SKIP telemetry CPU integration: set MOONROBO_TENSOR_TELEMETRY_LIBRARY",
    )
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_true(backend.has_cuda_memory_telemetry())
  assert_eq(backend.cuda_device_count(), 0)
  try backend.cuda_memory_stats(0) catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("CPU build or no accessible CUDA device"))
  } noraise {
    _ => fail("CPU telemetry must not fabricate zero counters")
  }
  try backend.reset_cuda_memory_peaks(0) catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(message.contains("CPU build or no accessible CUDA device"))
  } noraise {
    _ => fail("CPU peak reset must be an explicit error")
  }
  assert_eq(
    backend
    .from_values([1], [2.0], cuda_device=-1, requires_grad=false)
    .square()
    .values(),
    [4.0],
  )
}

///|
test "legacy ABI 2 plugin loads but does not silently supply CUDA counters" {
  guard @env.get_env_var("MOONROBO_TENSOR_LEGACY_LIBRARY") is Some(path) else {
    println(
      "SKIP telemetry backward compatibility: set MOONROBO_TENSOR_LEGACY_LIBRARY",
    )
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  assert_false(backend.has_cuda_memory_telemetry())
  try backend.cuda_memory_stats(0) catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(
        message.contains("lacks optional CUDA allocator telemetry extension"),
      )
  } noraise {
    _ => fail("legacy plugin must reject telemetry")
  }
  try backend.reset_cuda_memory_peaks(0) catch {
    @learning_tensor.TensorError::Native(message) =>
      assert_true(
        message.contains("lacks optional CUDA allocator telemetry extension"),
      )
  } noraise {
    _ => fail("legacy plugin must reject reset")
  }
  assert_eq(
    backend
    .from_values([1], [3.0], cuda_device=-1, requires_grad=false)
    .square()
    .values(),
    [9.0],
  )
}
