///|
fn blob_path(root : String, name : String) -> String raise {
  guard safe_file_name(name) else { fail("unsafe checkpoint blob filename") }
  root + "/" + name
}

///|
async fn canonical_root(root : String) -> String {
  let canonical = @fs.realpath(root)
  guard @fs.kind(canonical, follow_symlink=false) is Directory else {
    fail("checkpoint blob root must be a real directory")
  }
  canonical
}

///|
async fn write_bytes(
  root : String,
  name : String,
  dtype : String,
  shape : Array[Int32],
  read_chunk : (Int64, Int32) -> Bytes raise,
) -> BlobDescriptor {
  // Freeze the caller-owned mutable shape before any suspension or callback.
  let frozen_shape = shape.copy()
  let width = element_width(dtype)
  let (count, byte_length) = shape_count(frozen_shape, width)
  let path = blob_path(canonical_root(root), name)
  let staging = path + ".partial"
  let file = @fs.open(
    staging,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o600,
  )
  defer file.close()
  let hash = @crypto.SHA256::new()
  let max_elements = 65536 / width.to_int()
  for offset = 0L; offset < count; {
    let n = (count - offset).min(max_elements.to_int64()).to_int()
    let bytes = read_chunk(offset, n)
    guard bytes.length() == n * width.to_int() else {
      fail("checkpoint blob producer returned an incorrect chunk length")
    }
    file.write_at(bytes, position=offset * width)
    hash.update(bytes)
    continue offset + n.to_int64()
  }
  file.sync()
  guard file.size() == byte_length else {
    fail("checkpoint blob write length differs from shape")
  }
  @fs.rename(staging, path, replace=false)
  {
    file: name,
    dtype,
    shape: frozen_shape,
    count,
    byte_length,
    sha256: @crypto.bytes_to_hex_string(hash.finalize()),
  }
}

///|
/// Opens one final sidecar; callers retain this descriptor across both passes.
async fn open_blob(root : String, descriptor : BlobDescriptor) -> @fs.File {
  validate_descriptor(descriptor)
  let path = blob_path(canonical_root(root), descriptor.file)
  guard @fs.kind(path, follow_symlink=false) is Regular else {
    fail("checkpoint blob must be a regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  guard @fs.kind(path, follow_symlink=false) is Regular &&
    file.kind() is Regular else {
    file.close()
    fail("checkpoint blob changed to a non-regular file")
  }
  file
}

///|
async fn verify_open_file(file : @fs.File, descriptor : BlobDescriptor) -> Unit {
  guard file.size() == descriptor.byte_length else {
    fail("checkpoint blob file length differs from descriptor")
  }
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < descriptor.byte_length; {
    let n = (descriptor.byte_length - offset).min(65536L).to_int()
    hash.update(file.read_exactly_at(n, position=offset))
    continue offset + n.to_int64()
  }
  guard file.size() == descriptor.byte_length &&
    @crypto.bytes_to_hex_string(hash.finalize()) == descriptor.sha256 else {
    fail("checkpoint blob SHA256 or EOF mismatch")
  }
}

///|
/// Verifies descriptor, exact length and SHA256 without loading a whole blob.
pub async fn verify_blob(root : String, descriptor : BlobDescriptor) -> Unit {
  let file = open_blob(root, descriptor)
  defer file.close()
  verify_open_file(file, descriptor)
}

///|
async fn read_bytes(
  root : String,
  descriptor : BlobDescriptor,
  dtype : String,
  consume : (Int64, Bytes) -> Unit raise,
) -> Unit {
  guard descriptor.dtype == dtype else {
    fail("checkpoint blob dtype differs from requested decoder")
  }
  // Keep the same file descriptor across verification and decode. A path
  // replacement between passes cannot substitute a different inode.
  let file = open_blob(root, descriptor)
  defer file.close()
  verify_open_file(file, descriptor)
  let width = element_width(dtype)
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < descriptor.count; {
    let n = (descriptor.count - offset).min(65536L / width).to_int()
    let bytes = file.read_exactly_at(
      n * width.to_int(),
      position=offset * width,
    )
    hash.update(bytes)
    consume(offset, bytes)
    continue offset + n.to_int64()
  }
  guard file.size() == descriptor.byte_length &&
    @crypto.bytes_to_hex_string(hash.finalize()) == descriptor.sha256 else {
    fail("checkpoint blob changed while decoding")
  }
}

///|
pub async fn write_f64le(
  root : String,
  name : String,
  shape : Array[Int32],
  read_chunk : (Int64, Int32) -> Array[Double] raise,
) -> BlobDescriptor {
  write_bytes(root, name, "f64le", shape, (offset, n) => {
    let values = read_chunk(offset, n)
    guard values.length() == n else {
      fail("F64LE producer returned an incorrect value count")
    }
    Bytes::makei(n * 8, i => {
      (values[i / 8].reinterpret_as_int64() >> (i % 8 * 8)).to_byte()
    })
  })
}

///|
pub async fn write_i32le(
  root : String,
  name : String,
  shape : Array[Int32],
  read_chunk : (Int64, Int32) -> Array[Int32] raise,
) -> BlobDescriptor {
  write_bytes(root, name, "i32le", shape, (offset, n) => {
    let values = read_chunk(offset, n)
    guard values.length() == n else {
      fail("I32LE producer returned an incorrect value count")
    }
    Bytes::makei(n * 4, i => (values[i / 4] >> (i % 4 * 8)).to_byte())
  })
}

///|
pub async fn write_u8(
  root : String,
  name : String,
  shape : Array[Int32],
  read_chunk : (Int64, Int32) -> Array[Byte] raise,
) -> BlobDescriptor {
  write_bytes(root, name, "u8", shape, (offset, n) => {
    let values = read_chunk(offset, n)
    guard values.length() == n else {
      fail("U8 producer returned an incorrect value count")
    }
    Bytes::from_array(values)
  })
}

///|
pub async fn read_f64le(
  root : String,
  descriptor : BlobDescriptor,
  consume : (Int64, Array[Double]) -> Unit raise,
) -> Unit {
  read_bytes(root, descriptor, "f64le", (offset, bytes) => {
    let values = Array::makei(bytes.length() / 8, i => {
      let mut bits = 0L
      for j in 0..<8 {
        bits = bits | (bytes[i * 8 + j].to_int().to_int64() << (j * 8))
      }
      bits.reinterpret_as_double()
    })
    consume(offset, values)
  })
}

///|
pub async fn read_i32le(
  root : String,
  descriptor : BlobDescriptor,
  consume : (Int64, Array[Int32]) -> Unit raise,
) -> Unit {
  read_bytes(root, descriptor, "i32le", (offset, bytes) => {
    let values = Array::makei(bytes.length() / 4, i => {
      let mut bits = 0
      for j in 0..<4 {
        bits = bits | (bytes[i * 4 + j].to_int() << (j * 8))
      }
      bits
    })
    consume(offset, values)
  })
}

///|
pub async fn read_u8(
  root : String,
  descriptor : BlobDescriptor,
  consume : (Int64, Array[Byte]) -> Unit raise,
) -> Unit {
  read_bytes(root, descriptor, "u8", (offset, bytes) => {
    consume(offset, Array::makei(bytes.length(), i => bytes[i]))
  })
}
