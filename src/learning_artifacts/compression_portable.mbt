///|
pub fn decompress(_input : Bytes, raw~ : Bool = false) -> Bytes raise {
  ignore(raw)
  fail("compressed learning artifacts require native target and zlib")
}

///|
fn crc32(input : Bytes) -> UInt32 {
  let mut crc = 0xffffffffU
  for byte in input {
    crc = crc ^ byte.to_uint()
    for _ in 0..<8 {
      crc = if (crc & 1U) == 1U { (crc >> 1) ^ 0xedb88320U } else { crc >> 1 }
    }
  }
  crc ^ 0xffffffffU
}

///|
pub fn compress_gzip(_input : Bytes) -> Bytes raise {
  fail("gzip output requires the native target and zlib")
}
