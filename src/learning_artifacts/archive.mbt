///|
fn append_le(output : Array[Byte], value : UInt32, count : Int32) -> Unit {
  for i in 0..<count {
    output.push(((value >> (8 * i)) & 255U).to_byte())
  }
}

///|
fn append_bytes(output : Array[Byte], bytes : Bytes) -> Unit {
  for byte in bytes {
    output.push(byte)
  }
}

///|
/// NumPy-compatible uncompressed numeric NPZ; deterministic member order and
/// timestamps. Compression is an independent storage choice, not tensor data.
pub fn encode_npz(arrays : Map[String, NumericArray]) -> Bytes raise {
  let output : Array[Byte] = []
  let central : Array[Byte] = []
  let names = arrays.keys().collect()
  names.sort()
  guard names.length() < 65535 else { fail("ZIP64 NPZ output is unsupported") }
  for key in names {
    guard key != "" else { fail("empty NPZ tensor name") }
    let name = @utf8.encode(key + ".npy")
    guard name.length() <= 65535 else { fail("NPZ name too long") }
    let tensor = arrays.get(key).unwrap()
    let data = encode_npy(tensor.shape, tensor.values, dtype=tensor.dtype)
    guard output.length() <= 2147483647 - data.length() - name.length() - 30 else {
      fail("NPZ exceeds size limit")
    }
    let offset = output.length().to_uint()
    let crc = crc32(data)
    append_le(output, 0x04034b50U, 4)
    append_le(output, 20U, 2)
    append_le(output, 0x800U, 2)
    append_le(output, 0U, 2)
    append_le(output, 0U, 2)
    append_le(output, 0x21U, 2)
    append_le(output, crc, 4)
    append_le(output, data.length().to_uint(), 4)
    append_le(output, data.length().to_uint(), 4)
    append_le(output, name.length().to_uint(), 2)
    append_le(output, 0U, 2)
    append_bytes(output, name)
    append_bytes(output, data)
    append_le(central, 0x02014b50U, 4)
    append_le(central, 20U, 2)
    append_le(central, 20U, 2)
    append_le(central, 0x800U, 2)
    append_le(central, 0U, 2)
    append_le(central, 0U, 2)
    append_le(central, 0x21U, 2)
    append_le(central, crc, 4)
    append_le(central, data.length().to_uint(), 4)
    append_le(central, data.length().to_uint(), 4)
    append_le(central, name.length().to_uint(), 2)
    append_le(central, 0U, 2)
    append_le(central, 0U, 2)
    append_le(central, 0U, 2)
    append_le(central, 0U, 2)
    append_le(central, 0U, 4)
    append_le(central, offset, 4)
    append_bytes(central, name)
  }
  let offset = output.length()
  guard offset <= 2147483647 - central.length() - 22 else {
    fail("NPZ exceeds size limit")
  }
  output.append(central)
  append_le(output, 0x06054b50U, 4)
  append_le(output, 0U, 2)
  append_le(output, 0U, 2)
  append_le(output, names.length().to_uint(), 2)
  append_le(output, names.length().to_uint(), 2)
  append_le(output, central.length().to_uint(), 4)
  append_le(output, offset.to_uint(), 4)
  append_le(output, 0U, 2)
  Bytes::from_array(output)
}

///|
pub async fn load_npz(
  path : String,
  expected_sha256? : String,
) -> Map[String, NumericArray] {
  let bytes = @fs.read_file(path).binary()
  if expected_sha256 is Some(expected) {
    guard sha256(bytes) == expected else { fail("NPZ SHA256 differs") }
  }
  decode_npz(bytes)
}

///|
pub async fn save_npz(
  path : String,
  arrays : Map[String, NumericArray],
) -> String {
  let bytes = encode_npz(arrays)
  @fs.write_file(path, bytes, create_mode=CreateOrTruncate)
  sha256(bytes)
}
