///|
pub fn local_available_bytes(
  path : String,
) -> Result[Int64, @moondata_store.MoonDataStoreIssue] {
  Err(
    blob_issue(
      "disk-space-unsupported", path, "available storage capacity requires the native backend",
    ),
  )
}

///|
pub fn local_file_size(
  path : String,
) -> Result[Int64, @moondata_store.MoonDataStoreIssue] {
  let bytes = @fsx.read_file_to_bytes(path) catch {
    _ =>
      return Err(
        blob_issue(
          "read-blob-source", path, "failed to inspect MoonData blob source",
        ),
      )
  }
  Ok(bytes.length().to_int64())
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
  let bytes = @fsx.read_file_to_bytes(path) catch {
    _ =>
      return Err(
        blob_issue(
          "read-blob-source", path, "failed to read MoonData blob source",
        ),
      )
  }
  if offset > bytes.length().to_int64() ||
    offset + length.to_int64() > bytes.length().to_int64() {
    return Err(
      blob_issue(
        "blob-range-invalid", path, "blob file range exceeds the source size",
      ),
    )
  }
  let start = offset.to_int()
  Ok(Bytes::makei(length, fn(index) { bytes[start + index] }))
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
  let bytes = @fsx.read_file_to_bytes(path) catch {
    _ =>
      return Err(
        blob_issue(
          "read-blob-source", path, "failed to read MoonData blob source",
        ),
      )
  }
  if bytes.length() == 0 {
    return Err(
      blob_issue("blob-empty", path, "MoonData does not store empty blobs"),
    )
  }
  Ok(sha256_checksum(@crypto.sha256(bytes)))
}

///|
fn copy_local_file_staged(
  source_path : String,
  destination_path : String,
) -> Result[Bool, @moondata_store.MoonDataStoreIssue] {
  if @fsx.path_exists(destination_path) {
    return Ok(false)
  }
  let bytes = @fsx.read_file_to_bytes(source_path) catch {
    _ =>
      return Err(
        blob_issue(
          "read-blob-source", source_path, "failed to read MoonData blob source",
        ),
      )
  }
  @fsx.write_bytes_to_file(destination_path, bytes) catch {
    _ =>
      return Err(
        blob_issue(
          "copy-blob", destination_path, "failed to write MoonData blob file",
        ),
      )
  }
  Ok(true)
}
