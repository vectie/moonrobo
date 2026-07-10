///|
#borrow(path)
extern "c" fn native_file_size(path : Bytes) -> Int64 = "moondata_blob_file_size"

///|
#borrow(path)
extern "c" fn native_read_file_range(
  path : Bytes,
  offset : Int64,
  length : Int,
) -> Bytes = "moondata_blob_read_file_range"

///|
#borrow(source_path, destination_path)
extern "c" fn native_copy_file_staged(
  source_path : Bytes,
  destination_path : Bytes,
) -> Int = "moondata_blob_copy_file_staged"

///|
#borrow(path)
extern "c" fn native_available_bytes(path : Bytes) -> Int64 = "moondata_blob_available_bytes"

///|
pub fn local_available_bytes(
  path : String,
) -> Result[Int64, @moondata_store.MoonDataStoreIssue] {
  let available = native_available_bytes(@utf8.encode(path))
  if available < 0L {
    Err(
      blob_issue(
        "read-disk-space", path, "failed to read available storage capacity",
      ),
    )
  } else {
    Ok(available)
  }
}

///|
pub fn local_file_size(
  path : String,
) -> Result[Int64, @moondata_store.MoonDataStoreIssue] {
  let size = native_file_size(@utf8.encode(path))
  if size < 0L {
    Err(
      blob_issue(
        "read-blob-source", path, "failed to inspect MoonData blob source",
      ),
    )
  } else {
    Ok(size)
  }
}

///|
pub fn read_local_file_range(
  path : String,
  offset : Int64,
  length : Int,
) -> Result[Bytes, @moondata_store.MoonDataStoreIssue] {
  if offset < 0L || length < 0 {
    return Err(
      blob_issue(
        "blob-range-invalid", path, "blob file range must be non-negative",
      ),
    )
  }
  let size = match local_file_size(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if offset + length.to_int64() > size {
    return Err(
      blob_issue(
        "blob-range-invalid", path, "blob file range exceeds the source size",
      ),
    )
  }
  if length == 0 {
    return Ok(b"")
  }
  let bytes = native_read_file_range(@utf8.encode(path), offset, length)
  if bytes.length() != length {
    Err(
      blob_issue(
        "read-blob-range", path, "failed to read the requested blob file range",
      ),
    )
  } else {
    Ok(bytes)
  }
}

///|
pub fn local_file_checksum(
  path : String,
  chunk_size? : Int = 1024 * 1024,
) -> Result[String, @moondata_store.MoonDataStoreIssue] {
  if chunk_size <= 0 {
    return Err(
      blob_issue(
        "blob-chunk-size-invalid", path, "blob checksum chunk size must be positive",
      ),
    )
  }
  let size = match local_file_size(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if size == 0L {
    return Err(
      blob_issue("blob-empty", path, "MoonData does not store empty blobs"),
    )
  }
  let hasher = @crypto.SHA256::new()
  let mut offset = 0L
  while offset < size {
    let remaining = size - offset
    let length = if remaining > chunk_size.to_int64() {
      chunk_size
    } else {
      remaining.to_int()
    }
    let chunk = match read_local_file_range(path, offset, length) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    hasher.update(chunk)
    offset = offset + length.to_int64()
  }
  Ok(sha256_checksum(hasher.finalize()))
}

///|
fn copy_local_file_staged(
  source_path : String,
  destination_path : String,
) -> Result[Bool, @moondata_store.MoonDataStoreIssue] {
  let code = native_copy_file_staged(
    @utf8.encode(source_path),
    @utf8.encode(destination_path),
  )
  match code {
    0 => Ok(true)
    1 => Ok(false)
    _ =>
      Err(
        blob_issue(
          "copy-blob", destination_path, "failed to stage MoonData blob file",
        ),
      )
  }
}
