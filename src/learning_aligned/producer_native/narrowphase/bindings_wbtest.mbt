///|
test "native contact view extent checks padding and backing capacity" {
  let p = parameter("contact_efc_address_out", "int32", 2, "output")
  let binding : Binding = {
    name: p.name,
    allocation: "owned-buffer-1",
    dtype: "int32",
    shape: [2, 3],
    byte_strides: [12, 4],
    byte_offset: 0L,
    buffer_bytes: 24L,
  }
  assert_eq(extent(binding, p), (0L, 24L))
  for
    invalid in [
      { ..binding, buffer_bytes: 23L, },
      { ..binding, byte_offset: 4L, },
      { ..binding, byte_strides: [0, 4], },
      { ..binding, byte_strides: [4, 4], },
    ] {
    try extent(invalid, p) catch {
      _ => ()
    } noraise {
      _ => fail("invalid owned view accepted")
    }
  }
}

///|
test "readonly broadcast is allowed while writable broadcast is rejected" {
  let binding : Binding = {
    name: "geom_solmix",
    allocation: "owned-buffer-2",
    dtype: "float32",
    shape: [2, 3],
    byte_strides: [0, 4],
    byte_offset: 0L,
    buffer_bytes: 12L,
  }
  assert_eq(
    extent(binding, parameter(binding.name, "float32", 2, "input")),
    (0L, 12L),
  )
  try extent(binding, parameter(binding.name, "float32", 2, "output")) catch {
    _ => ()
  } noraise {
    _ => fail("writable broadcast accepted")
  }
}
