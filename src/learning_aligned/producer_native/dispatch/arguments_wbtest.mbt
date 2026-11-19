///|
// Pending pure transport contract cases. No plugin is opened by these tests.
test "CUDA bool has one byte while int32 keeps its signed bit pattern" {
  let yes = Argument::boolean(true)
  let no = Argument::boolean(false)
  assert_true(yes is Value(b"\x01", 1U, []))
  assert_true(no is Value(b"\x00", 1U, []))
  assert_true(Argument::int32(-2) is Value(b"\xfe\xff\xff\xff", 4U, []))
}

///|
test "IEEE payload and wide unsigned integer retain all bits" {
  assert_true(Argument::float32(1.0) is Value(b"\x00\x00\x80\x3f", 4U, []))
  assert_true(
    Argument::float64(1.0) is Value(b"\x00\x00\x00\x00\x00\x00\xf0\x3f", 8U, []),
  )
  assert_true(
    Argument::uint64(0xfedcba9876543210UL)
    is Value(b"\x10\x32\x54\x76\x98\xba\xdc\xfe", 8U, []),
  )
}

///|
test "scalar transport contains no implicit pointer relocations" {
  let out = []
  let buffers = []
  append_argument(out, buffers, Argument::boolean(true))
  assert_eq(buffers.length(), 0)
  assert_eq(
    Bytes::from_array(out),
    b"\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00",
  )
}

///|
test "invalid opaque alignment is rejected before FFI" {
  let failed = try {
    append_argument([], [], Argument::value_blob(b"\x00", 3U))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
