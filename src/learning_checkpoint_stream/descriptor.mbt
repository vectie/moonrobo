///|
/// A raw, little-endian sidecar in a sealed checkpoint generation.
/// The field owner defines the semantic meaning and finite-value policy.
pub(all) struct BlobDescriptor {
  file : String
  dtype : String
  shape : Array[Int32]
  count : Int64
  byte_length : Int64
  sha256 : String
} derive(ToJson, FromJson)

///|
pub extend BlobDescriptor with ToJson::{to_json}

///|
pub extend BlobDescriptor with @json.FromJson::{from_json}

///|
fn safe_file_name(name : String) -> Bool {
  // The writer appends ".partial" before publication. Limit UTF-8 bytes,
  // not code points, so the staging name also fits common 255-byte limits.
  let bytes = @utf8.encode(name)
  if bytes.length() == 0 || bytes.length() > 247 || name == "." || name == ".." {
    return false
  }
  for byte in bytes {
    let n = byte.to_int()
    if n < 32 || n == 127 || n == 47 || n == 92 {
      return false
    }
  }
  true
}

///|
fn valid_sha256(value : String) -> Bool {
  if value.length() != 64 {
    return false
  }
  for byte in @utf8.encode(value) {
    let n = byte.to_int()
    if !((n >= 48 && n <= 57) || (n >= 97 && n <= 102)) {
      return false
    }
  }
  true
}

///|
fn element_width(dtype : String) -> Int64 raise {
  match dtype {
    "f64le" => 8L
    "i32le" => 4L
    "u8" => 1L
    _ => fail("unsupported checkpoint blob dtype: " + dtype)
  }
}

///|
fn shape_count(shape : Array[Int32], width : Int64) -> (Int64, Int64) raise {
  guard shape.length() >= 1 && shape.length() <= 4 else {
    fail("checkpoint blob shape rank must be 1..4")
  }
  let maximum_bytes = 64L * 1073741824L
  for dimension in shape {
    guard dimension >= 0 else { fail("negative checkpoint blob dimension") }
  }
  if shape.any(dimension => dimension == 0) {
    return (0L, 0L)
  }
  let mut count = 1L
  for dimension in shape {
    let value = dimension.to_int64()
    guard count <= maximum_bytes / width / value else {
      fail("checkpoint blob exceeds 64 GiB or count overflows")
    }
    count *= value
  }
  (count, count * width)
}

///|
pub fn validate_descriptor(descriptor : BlobDescriptor) -> Unit raise {
  guard safe_file_name(descriptor.file) && valid_sha256(descriptor.sha256) else {
    fail("unsafe checkpoint blob filename or SHA256")
  }
  let (count, byte_length) = shape_count(
    descriptor.shape,
    element_width(descriptor.dtype),
  )
  guard descriptor.count == count && descriptor.byte_length == byte_length else {
    fail("checkpoint blob shape/count/byte length mismatch")
  }
}
