///|
test "negative probe only accepts the intended failure cause" {
  assert_true(
    refusal_matches(
      "CUDA allocator telemetry unsupported: allocator is unavailable or uninitialized",
      uncached=false,
    ),
  )
  assert_true(
    refusal_matches(
      "CUDA allocator telemetry unsupported: selected device has no initialized primary context",
      uncached=false,
    ),
  )
  assert_true(
    refusal_matches(
      "CUDA allocator telemetry unsupported: uncached allocations bypass tracked statistics",
      uncached=true,
    ),
  )
  for
    message in [
      "CPU build or no accessible CUDA device", "plugin lacks optional CUDA allocator telemetry extension",
      "CUDA driver error",
    ] {
    assert_false(refusal_matches(message, uncached=false))
    assert_false(refusal_matches(message, uncached=true))
  }
  assert_false(
    refusal_matches("allocator is unavailable or uninitialized", uncached=true),
  )
  assert_false(
    refusal_matches(
      "uncached allocations bypass tracked statistics",
      uncached=false,
    ),
  )
}
