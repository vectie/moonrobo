///|
// Pending source-only cases: no CUDA library load or GPU operation.
test "component-wise scan span includes final complete element" {
  assert_eq(typed_span(F32, 3, 16, 3), 44UL)
  assert_eq(typed_span(I64, 2, 24, 2), 40UL)
  assert_eq(typed_span(I32, 0, 4, 1), 0UL)
}

///|
test "scan rejects overlapping component layout and invalid byte strides" {
  for
    (kind, count, stride, components) in [
      (F32, 2, 8, 3),
      (I64, 3, 12, 1),
      (I32, -1, 4, 1),
    ] {
    let rejected = try {
      ignore(typed_span(kind, count, stride, components))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "actual immutable partition accepts empty segments and preserves bytes" {
  assert_eq(
    partition_bytes([0, 2, 2, 5], 5),
    b"\x00\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x05\x00\x00\x00",
  )
  assert_eq(partition_bytes([0], 0), b"\x00\x00\x00\x00")
}

///|
test "arbitrary out-of-range, decreasing or mismatched partitions are refused" {
  for boundaries in [[-1, 5], [0, 6], [0, 4, 3, 5], [1, 5], [0, 4], []] {
    let rejected = try {
      ignore(partition_bytes(boundaries, 5))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}
