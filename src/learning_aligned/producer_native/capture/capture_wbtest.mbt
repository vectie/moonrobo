///|
/// Pending metadata-only regression cases; no native handles are opened.
fn rejects(work : () -> Unit raise) -> Bool {
  try {
    work()
    false
  } catch {
    _ => true
  }
}

///|
test "typed capture array span checks full strided last element before launch" {
  let view : ArrayInput = {
    buffer: "owned",
    shape: [2, 3],
    byte_strides: [32, 8],
    offset_bytes: 4UL,
  }
  validate_array(view, 2, 4, 4, 56)
  assert_true(rejects(fn() raise { validate_array(view, 2, 4, 4, 55) }))
  for
    bad in [
      { ..view, shape: [2], },
      { ..view, shape: [0, 3], },
      { ..view, byte_strides: [32, -4], },
      { ..view, offset_bytes: 1UL, },
      { ..view, byte_strides: [2147483644, 8], },
    ] {
    assert_true(rejects(fn() raise { validate_array(bad, 2, 4, 4, 56) }))
  }
}

///|
test "raw gather indices are signed bounded values in real strided input bytes" {
  let indices : ArrayInput = {
    buffer: "indices",
    shape: [2],
    byte_strides: [4],
    offset_bytes: 0UL,
  }
  validate_index_data(indices, b"\x01\x00\x00\x00\x00\x00\x00\x00", 2)
  assert_true(
    rejects(fn() raise {
      validate_index_data(indices, b"\x00\x00\x00\x00\x00\x00\x00\x00", 2)
    }),
  )
  assert_true(
    rejects(fn() raise {
      validate_index_data(indices, b"\x01\x00\x00\x00\x02\x00\x00\x00", 2)
    }),
  )
  assert_true(
    rejects(fn() raise {
      validate_index_data(indices, b"\xff\xff\xff\xff\x00\x00\x00\x00", 2)
    }),
  )
}

///|
test "writable compound vector elements require disjoint storage" {
  let packed : ArrayInput = {
    buffer: "pose",
    shape: [2],
    byte_strides: [28],
    offset_bytes: 0UL,
  }
  validate_writable(packed, 28)
  assert_true(
    rejects(fn() raise {
      validate_writable({ ..packed, byte_strides: [4], }, 28)
    }),
  )
  assert_true(
    rejects(fn() raise {
      validate_writable({ ..packed, byte_strides: [4], }, 24)
    }),
  )
}
