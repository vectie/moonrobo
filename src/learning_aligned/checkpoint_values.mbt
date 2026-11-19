///|
/// Business schemas must bind both names and dimensions, not just file hashes.
pub fn checkpoint_blob(
  value : @checkpoint_stream.BlobDescriptor,
  file : String,
  dtype : String,
  shape : Array[Int32],
) -> Unit raise {
  @checkpoint_stream.validate_descriptor(value)
  guard value.file == file && value.dtype == dtype && value.shape == shape else {
    fail("checkpoint sidecar name/dtype/shape differs: " + file)
  }
}

///|
/// Only for already-sized resident metadata arrays, never the replay values.
pub async fn checkpoint_read_f64(
  root : String,
  blob : @checkpoint_stream.BlobDescriptor,
  expected_count : Int32,
) -> Array[Double] {
  guard expected_count >= 0 && blob.count == expected_count.to_int64() else {
    fail("checkpoint numeric count differs")
  }
  let result = Array::make(expected_count, 0.0)
  @checkpoint_stream.read_f64le(root, blob, (offset, values) => {
    for i, value in values {
      guard @numeric.finite(value) else { fail("nonfinite checkpoint value") }
      result[offset.to_int() + i] = value
    }
  })
  result
}

///|
pub async fn checkpoint_read_i32(
  root : String,
  blob : @checkpoint_stream.BlobDescriptor,
  expected_count : Int32,
) -> Array[Int32] {
  guard expected_count >= 0 && blob.count == expected_count.to_int64() else {
    fail("checkpoint index count differs")
  }
  let result = Array::make(expected_count, 0)
  @checkpoint_stream.read_i32le(root, blob, (offset, values) => {
    for i, value in values {
      result[offset.to_int() + i] = value
    }
  })
  result
}

///|
pub async fn checkpoint_read_u8(
  root : String,
  blob : @checkpoint_stream.BlobDescriptor,
  expected_count : Int32,
) -> Array[Byte] {
  guard expected_count >= 0 && blob.count == expected_count.to_int64() else {
    fail("checkpoint flag count differs")
  }
  let result = Array::make(expected_count, b'\x00')
  @checkpoint_stream.read_u8(root, blob, (offset, values) => {
    for i, value in values {
      result[offset.to_int() + i] = value
    }
  })
  result
}
