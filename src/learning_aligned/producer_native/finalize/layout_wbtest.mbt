///|
test "typed ABI packs exact int32 and scalar-vector byte layout" {
  let ints = integers([-1, 0x01020304], [2])
  assert_eq(ints.bytes, b"\xff\xff\xff\xff\x04\x03\x02\x01")
  assert_eq(ints.strides(), [4])
  let single = floating([1.0, -2.0], [2], "f32")
  assert_eq(single.bytes, b"\x00\x00\x80\x3f\x00\x00\x00\xc0")
  let double = floating([1.0], [1], "f64")
  assert_eq(double.bytes, b"\x00\x00\x00\x00\x00\x00\xf0\x3f")
  let transforms = floating(Array::make(14, 0.0), [2], "f32", components=7)
  assert_eq(transforms.bytes.length(), 56)
  assert_eq(transforms.strides(), [28])
  assert_eq(transforms.components, 7)
}

///|
test "real world starts include global-tail total sentinel and reject interleaving" {
  assert_eq(world_starts([0, 0, 1, 1, 1], 2), [0, 2, 5, 5])
  try world_starts([0, 1, 0], 2) catch {
    _ => ()
  } noraise {
    _ => fail("interleaved worlds must fail")
  }
}

///|
test "coord targets preserve free quaternion and legacy projection differs from state pose" {
  let types = [4, 1, 3]
  let qstarts = [0, 7, 8, 8]
  let qdstarts = [0, 6, 7, 7]
  let q = [10.0, 20.0, 30.0, 0.0, 0.0, 0.6, 0.8, 0.25]
  assert_eq(targets(types, qstarts, qdstarts, q, "coord"), [
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.25,
  ])
  assert_eq(targets(types, qstarts, qdstarts, q, "dof"), [
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.25,
  ])
}

///|
test "nonfinite unrepresentable data and malformed strides cannot enter device upload" {
  try floating([1.0e300], [1], "f32") catch {
    _ => ()
  } noraise {
    _ => fail("float32 overflow must fail")
  }
  try floating([1.0e-300], [1], "f32") catch {
    _ => ()
  } noraise {
    _ => fail("float32 underflow must fail")
  }
  let broken : HostArray = {
    scalar_type: "f32",
    shape: [2],
    components: 3,
    bytes: b"\x00\x00\x00\x00",
  }
  try broken.validate() catch {
    _ => ()
  } noraise {
    _ => fail("shape byte mismatch must fail")
  }
}
