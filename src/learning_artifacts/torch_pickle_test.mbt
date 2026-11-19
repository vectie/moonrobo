// Hand-authored wire fixtures; no Python/pickle producer or execution is involved.

///|
fn torch_test_add(out : Array[Byte], bytes : Bytes) -> Unit {
  for b in bytes {
    out.push(b)
  }
}

///|
fn torch_test_le(out : Array[Byte], value : Int64, width : Int32) -> Unit {
  for i in 0..<width {
    out.push(((value >> (i * 8)).to_int() & 255).to_byte())
  }
}

///|
fn torch_test_crc(bytes : Bytes) -> UInt32 {
  let mut crc = 0xffffffffU
  for b in bytes {
    crc = crc ^ b.to_int().reinterpret_as_uint()
    for _ in 0..<8 {
      crc = if (crc & 1U) == 1U { (crc >> 1) ^ 0xedb88320U } else { crc >> 1 }
    }
  }
  crc ^ 0xffffffffU
}

///|
fn torch_test_archive(
  pickle : Bytes,
  data? : Bytes,
  byteorder~ : String = "little",
) -> Bytes {
  let members : Array[(String, Bytes)] = [
    ("archive/data.pkl", pickle),
    ("archive/byteorder", @utf8.encode(byteorder)),
  ]
  if data is Some(bytes) {
    members.push(("archive/data/0", bytes))
  }
  let out : Array[Byte] = []
  let central : Array[Byte] = []
  for (name, bytes) in members {
    let name = @utf8.encode(name)
    let offset = out.length().to_int64()
    let crc = torch_test_crc(bytes).to_int64()
    torch_test_le(out, 0x04034b50L, 4)
    torch_test_le(out, 20L, 2)
    torch_test_le(out, 0L, 2)
    torch_test_le(out, 0L, 2)
    torch_test_le(out, 0L, 2)
    torch_test_le(out, 0L, 2)
    torch_test_le(out, crc, 4)
    torch_test_le(out, bytes.length().to_int64(), 4)
    torch_test_le(out, bytes.length().to_int64(), 4)
    torch_test_le(out, name.length().to_int64(), 2)
    torch_test_le(out, 0L, 2)
    torch_test_add(out, name)
    torch_test_add(out, bytes)
    torch_test_le(central, 0x02014b50L, 4)
    torch_test_le(central, 20L, 2)
    torch_test_le(central, 20L, 2)
    torch_test_le(central, 0L, 2)
    torch_test_le(central, 0L, 2)
    torch_test_le(central, 0L, 2)
    torch_test_le(central, 0L, 2)
    torch_test_le(central, crc, 4)
    torch_test_le(central, bytes.length().to_int64(), 4)
    torch_test_le(central, bytes.length().to_int64(), 4)
    torch_test_le(central, name.length().to_int64(), 2)
    torch_test_le(central, 0L, 2)
    torch_test_le(central, 0L, 2)
    torch_test_le(central, 0L, 2)
    torch_test_le(central, 0L, 2)
    torch_test_le(central, 0L, 4)
    torch_test_le(central, offset, 4)
    torch_test_add(central, name)
  }
  let offset = out.length().to_int64()
  torch_test_add(out, Bytes::from_array(central))
  torch_test_le(out, 0x06054b50L, 4)
  torch_test_le(out, 0L, 2)
  torch_test_le(out, 0L, 2)
  torch_test_le(out, members.length().to_int64(), 2)
  torch_test_le(out, members.length().to_int64(), 2)
  torch_test_le(out, central.length().to_int64(), 4)
  torch_test_le(out, offset, 4)
  torch_test_le(out, 0L, 2)
  Bytes::from_array(out)
}

///|
fn torch_test_string(out : Array[Byte], value : String) -> Unit {
  out.push(88)
  let bytes = @utf8.encode(value)
  torch_test_le(out, bytes.length().to_int64(), 4)
  torch_test_add(out, bytes)
}

///|
fn torch_test_global(out : Array[Byte], module : String, name : String) -> Unit {
  out.push(99)
  torch_test_add(out, @utf8.encode(module + "\n" + name + "\n"))
}

///|
fn torch_test_int(out : Array[Byte], n : Int32) -> Unit {
  out.push(74)
  torch_test_le(out, n.to_int64(), 4)
}

///|
fn torch_test_tuple(out : Array[Byte], values : Array[Int32]) -> Unit {
  out.push(40)
  for n in values {
    torch_test_int(out, n)
  }
  out.push(116)
}

///|
fn torch_test_tensor(
  dtype : String,
  storage_count : Int32,
  offset : Int32,
  shape : Array[Int32],
  strides : Array[Int32],
  v2~ : Bool = true,
) -> Bytes {
  let out : Array[Byte] = []
  torch_test_global(
    out,
    "torch._utils",
    if v2 {
      "_rebuild_tensor_v2"
    } else {
      "_rebuild_tensor"
    },
  )
  out.push(40)
  out.push(40)
  torch_test_string(out, "storage")
  torch_test_global(out, "torch", dtype)
  torch_test_string(out, "0")
  torch_test_string(out, "cpu")
  torch_test_int(out, storage_count)
  out.push(116)
  out.push(81)
  torch_test_int(out, offset)
  torch_test_tuple(out, shape)
  torch_test_tuple(out, strides)
  if v2 {
    out.push(137)
    torch_test_global(out, "collections", "OrderedDict")
    out.push(41)
    out.push(82)
  }
  out.push(116)
  out.push(82)
  Bytes::from_array(out)
}

///|
fn torch_test_wrapped(body : Bytes, protocol~ : Int32 = 2) -> Bytes {
  let out : Array[Byte] = [128, protocol.to_byte()]
  if protocol == 4 {
    out.push(149)
    torch_test_le(out, (body.length() + 1).to_int64(), 8)
  }
  torch_test_add(out, body)
  out.push(46)
  Bytes::from_array(out)
}

///|
fn torch_test_float_bytes(values : Array[Double]) -> Bytes {
  let out : Array[Byte] = []
  for value in values {
    torch_test_le(out, value.reinterpret_as_int64(), 8)
  }
  Bytes::from_array(out)
}

///|
test "Torch protocol 2 primitive containers, long signed integers and big-endian float" {
  let body : Array[Byte] = [125, 40]
  torch_test_string(body, "values")
  torch_test_add(
    body, b"](N\x88\x89J\xff\xff\xff\xff\x8a\x01\xffG\x3f\xf8\x00\x00\x00\x00\x00\x00e",
  )
  body.push(117)
  let value = @learning_artifacts.decode_torch_checkpoint(
    torch_test_archive(torch_test_wrapped(Bytes::from_array(body))),
  )
  json_inspect(value.plain_json(), content={
    "values": [null, true, false, -1, -1, 1.5],
  })
}

///|
test "Torch Float32 transpose view uses true strides rather than raw storage order" {
  let data = b"\x00\x00\x80\x3f\x00\x00\x00\x40\x00\x00\x40\x40\x00\x00\x80\x40\x00\x00\xa0\x40\x00\x00\xc0\x40"
  let pickle = torch_test_wrapped(
    torch_test_tensor("FloatStorage", 6, 0, [3, 2], [1, 3]),
  )
  let tensor = @learning_artifacts.decode_torch_checkpoint(
    torch_test_archive(pickle, data~),
  ).tensor()
  assert_eq(tensor.shape, [3, 2])
  assert_eq(tensor.dtype, "<f4")
  assert_eq(tensor.values, [1.0, 4.0, 2.0, 5.0, 3.0, 6.0])
}

///|
test "Torch Double storage offset, zero stride, scalar and empty views" {
  let data = torch_test_float_bytes([10.0, 20.0, 30.0, 40.0])
  for
    (offset, shape, stride, expected) in [
      (1, [2], [2], [20.0, 40.0]),
      (2, [3], [0], [30.0, 30.0, 30.0]),
      (3, [], [], [40.0]),
      (4, [0], [1], []),
    ] {
    let pickle = torch_test_wrapped(
      torch_test_tensor("DoubleStorage", 4, offset, shape, stride),
    )
    let tensor = @learning_artifacts.decode_torch_checkpoint(
      torch_test_archive(pickle, data~),
    ).tensor()
    assert_eq(tensor.shape, shape)
    assert_eq(tensor.values, expected)
  }
}

///|
test "Torch protocol 4 FRAME STACK_GLOBAL MEMOIZE and OrderedDict metadata BUILD" {
  let body : Array[Byte] = [140, 11]
  torch_test_add(body, b"collections")
  body.push(140)
  body.push(11)
  torch_test_add(body, b"OrderedDict")
  torch_test_add(body, b"\x93)R\x94")
  torch_test_string(body, "weight")
  torch_test_add(body, torch_test_tensor("DoubleStorage", 1, 0, [1], [1]))
  body.push(115)
  body.push(125)
  torch_test_string(body, "_metadata")
  body.push(125)
  body.push(115)
  body.push(98)
  let pickle = torch_test_wrapped(Bytes::from_array(body), protocol=4)
  let value = @learning_artifacts.decode_torch_checkpoint(
    torch_test_archive(pickle, data=torch_test_float_bytes([7.0])),
  )
  assert_eq(value.field("weight").tensor().values, [7.0])
}

///|
test "Torch memo aliases preserve mutable container entries" {
  let body : Array[Byte] = [125, 40]
  torch_test_string(body, "a")
  torch_test_add(body, b"]q\x00K\x07a")
  torch_test_string(body, "b")
  torch_test_add(body, b"h\x00u")
  let value = @learning_artifacts.decode_torch_checkpoint(
    torch_test_archive(torch_test_wrapped(Bytes::from_array(body))),
  )
  json_inspect(value.plain_json(), content={ "a": [7], "b": [7] })
}

///|
test "Torch nonfinite bounds remain raw and cannot silently enter JSON" {
  let pickle = torch_test_wrapped(
    torch_test_tensor("DoubleStorage", 2, 0, [2], [1]),
  )
  let value = @learning_artifacts.decode_torch_checkpoint(
    torch_test_archive(
      pickle,
      data=torch_test_float_bytes([-1.0 / 0.0, 1.0 / 0.0]),
    ),
  )
  assert_true(value.tensor().values[0].is_inf())
  assert_true(value.tensor().values[1].is_inf())
  assert_true((try? value.plain_json()) is Err(_))
}

///|
test "Torch dangerous globals, unsupported opcodes and malformed framing are rejected" {
  for
    pickle in [
      b"\x80\x02cos\nsystem\n.", b"\x80\x02ctorch\ndevice\n.", b"\x80\x02\x81.",
      b"\x80\x05N.", b"\x80\x04\x95\x01\x00\x00\x00\x00\x00\x00\x00X\x05\x00\x00\x00hello.",
      b"\x80\x02N.trailing",
    ] {
    assert_true(
      (try? @learning_artifacts.decode_torch_checkpoint(
        torch_test_archive(pickle),
      ))
      is Err(_),
    )
  }
  assert_true(
    (try? @learning_artifacts.decode_torch_checkpoint(b"\x80\x02N.")) is Err(_),
  )
  assert_true(
    (try? @learning_artifacts.decode_torch_checkpoint(
      torch_test_archive(b"\x80\x02N.", byteorder="big"),
    ))
    is Err(_),
  )
}

///|
test "Torch missing storage, bounds, negative strides and precision loss are rejected" {
  let data = torch_test_float_bytes([1.0])
  for
    (offset, shape, stride) in [
      (1, [1], [1]),
      (0, [2], [1]),
      (0, [1], [-1]),
      (0, [2147483647, 2], [1, 1]),
    ] {
    let pickle = torch_test_wrapped(
      torch_test_tensor("DoubleStorage", 1, offset, shape, stride),
    )
    assert_true(
      (try? @learning_artifacts.decode_torch_checkpoint(
        torch_test_archive(pickle, data~),
      ))
      is Err(_),
    )
  }
  let pickle = torch_test_wrapped(
    torch_test_tensor("DoubleStorage", 1, 0, [1], [1]),
  )
  assert_true(
    (try? @learning_artifacts.decode_torch_checkpoint(
      torch_test_archive(pickle),
    ))
    is Err(_),
  )
  let integer : Array[Byte] = []
  torch_test_le(integer, 9007199254740993L, 8)
  let pickle = torch_test_wrapped(
    torch_test_tensor("LongStorage", 1, 0, [1], [1]),
  )
  assert_true(
    (try? @learning_artifacts.decode_torch_checkpoint(
      torch_test_archive(pickle, data=Bytes::from_array(integer)),
    ))
    is Err(_),
  )
}

///|
test "Torch integer versus string dictionary key collisions and memo cycles are rejected" {
  let body : Array[Byte] = [125, 40, 75, 1, 75, 2]
  torch_test_string(body, "1")
  torch_test_add(body, b"K\x03u")
  assert_true(
    (try? @learning_artifacts.decode_torch_checkpoint(
      torch_test_archive(torch_test_wrapped(Bytes::from_array(body))),
    ))
    is Err(_),
  )
  assert_true(
    (try? @learning_artifacts.decode_torch_checkpoint(
      torch_test_archive(b"\x80\x02]q\x00h\x00a."),
    ))
    is Err(_),
  )
  assert_true(
    (try? @learning_artifacts.decode_torch_checkpoint(
      torch_test_archive(b"\x80\x02}q\x00}b."),
    ))
    is Err(_),
  )
}

///|
test "Torch Int Long Byte Bool storages and legacy tensor rebuild are numeric only" {
  for
    (dtype, data, expected) in [
      ("IntStorage", b"\xfe\xff\xff\xff", [-2.0]),
      ("LongStorage", b"\x01\x00\x00\x00\x00\x00\x00\x00", [1.0]),
      ("ByteStorage", b"\xff", [255.0]),
      ("BoolStorage", b"\x01", [1.0]),
    ] {
    let pickle = torch_test_wrapped(
      torch_test_tensor(dtype, 1, 0, [], [], v2=false),
    )
    assert_eq(
      @learning_artifacts.decode_torch_checkpoint(
        torch_test_archive(pickle, data~),
      ).tensor().values,
      expected,
    )
  }
  let pickle = torch_test_wrapped(
    torch_test_tensor("BoolStorage", 1, 0, [1], [1]),
  )
  assert_true(
    (try? @learning_artifacts.decode_torch_checkpoint(
      torch_test_archive(pickle, data=b"\x02"),
    ))
    is Err(_),
  )
}

///|
test "Torch parameter unwrap accepts only tensor plus boolean and empty hooks" {
  let body : Array[Byte] = []
  torch_test_global(body, "torch._utils", "_rebuild_parameter")
  body.push(40)
  torch_test_add(body, torch_test_tensor("DoubleStorage", 1, 0, [1], [1]))
  body.push(136)
  body.push(125)
  body.push(116)
  body.push(82)
  let pickle = torch_test_wrapped(Bytes::from_array(body))
  assert_eq(
    @learning_artifacts.decode_torch_checkpoint(
      torch_test_archive(pickle, data=torch_test_float_bytes([9.0])),
    ).tensor().values,
    [9.0],
  )
}

///|
test "Torch Int64 scalars preserve raw precision but reject lossy JSON" {
  let body : Array[Byte] = [138, 8]
  torch_test_le(body, 9007199254740993L, 8)
  let value = @learning_artifacts.decode_torch_checkpoint(
    torch_test_archive(torch_test_wrapped(Bytes::from_array(body))),
  )
  assert_true(value is @learning_artifacts.TorchInt(9007199254740993L))
  assert_true((try? value.plain_json()) is Err(_))
}

///|
fn numpy_test_bytes(out : Array[Byte], data : Bytes, protocol : Int32) -> Unit {
  if protocol == 2 {
    torch_test_global(out, "_codecs", "encode")
    torch_test_string(
      out,
      String::from_array(data.iter().map(b => b.to_char()).collect()),
    )
    torch_test_string(out, "latin1")
    out.push(134)
    out.push(82)
  } else {
    out.push(66)
    torch_test_le(out, data.length().to_int64(), 4)
    torch_test_add(out, data)
  }
}

///|
fn numpy_test_array(
  data : Bytes,
  code~ : String = "f8",
  order~ : String = "<",
  shape~ : Array[Int32] = [2],
  fortran~ : Bool = false,
  protocol~ : Int32 = 2,
  module~ : String = "numpy.core.multiarray",
) -> Bytes {
  let out : Array[Byte] = []
  torch_test_global(out, module, "_reconstruct")
  out.push(40)
  torch_test_global(out, "numpy", "ndarray")
  torch_test_tuple(out, [0])
  numpy_test_bytes(out, b"b", protocol)
  out.push(116)
  out.push(82)
  out.push(113)
  out.push(0)
  out.push(40)
  torch_test_int(out, 1)
  torch_test_tuple(out, shape)
  torch_test_global(out, "numpy", "dtype")
  torch_test_string(out, code)
  out.push(137)
  out.push(136)
  out.push(135)
  out.push(82)
  out.push(40)
  torch_test_int(out, 3)
  torch_test_string(out, order)
  torch_test_add(out, b"NNN")
  torch_test_int(out, -1)
  torch_test_int(out, -1)
  torch_test_int(out, 0)
  out.push(116)
  out.push(98)
  out.push(if fortran { 136 } else { 137 })
  numpy_test_bytes(out, data, protocol)
  out.push(116)
  out.push(98)
  torch_test_wrapped(Bytes::from_array(out), protocol~)
}

///|
test "Torch ZIP numeric NumPy ndarray BUILD supports protocol2 latin1 and protocol3 bytes" {
  let data = torch_test_float_bytes([1.5, -2.25])
  for protocol in [2, 3, 4] {
    for module in ["numpy.core.multiarray", "numpy._core.multiarray"] {
      let pickle = numpy_test_array(data, protocol~, module~)
      let tensor = @learning_artifacts.decode_torch_checkpoint(
        torch_test_archive(pickle),
      ).tensor()
      assert_eq(tensor.dtype, "<f8")
      assert_eq(tensor.shape, [2])
      assert_eq(tensor.values, [1.5, -2.25])
    }
  }
}

///|
test "Torch ZIP NumPy primitive arrays reject unsupported object endian order shape and raw byte count" {
  for
    pickle in [
      numpy_test_array(b"", code="O8"),
      numpy_test_array(torch_test_float_bytes([1.0, 2.0]), order=">"),
      numpy_test_array(torch_test_float_bytes([1.0, 2.0]), fortran=true),
      numpy_test_array(torch_test_float_bytes([1.0])),
      numpy_test_array(b"", shape=[16777217]),
    ] {
    assert_true(
      (try? @learning_artifacts.decode_torch_checkpoint(
        torch_test_archive(pickle),
      ))
      is Err(_),
    )
  }
  let tensor = @learning_artifacts.decode_torch_checkpoint(
    torch_test_archive(numpy_test_array(b"", shape=[0])),
  ).tensor()
  assert_eq(tensor.values, [])
}
