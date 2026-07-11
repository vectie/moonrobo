///|
pub(all) struct LocalBlobResult {
  root : String
  path : String
  uri : String
  digest : String
  byte_count : Int64
  existed : Bool
  data_ref : @moondata_core.DataRef
} derive(Debug, Eq, ToJson, FromJson)

///|
fn blob_issue(
  code : String,
  path : String,
  message : String,
) -> @moondata_store.MoonDataStoreIssue {
  { code, path, message }
}

///|
fn join(root : String, relative : String) -> String {
  if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
fn sha256_digest(checksum : String) -> String {
  match checksum.strip_prefix("sha256:") {
    Some(value) => value.to_owned()
    None => ""
  }
}

///|
fn sha256_checksum(digest : FixedArray[Byte]) -> String {
  let mut hex = ""
  for byte in digest {
    hex = hex + byte.to_hex()
  }
  "sha256:" + hex
}

///|
fn sha256_digest_is_valid(digest : String) -> Bool {
  if digest.length() != 64 {
    return false
  }
  for char in digest {
    if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
      return false
    }
  }
  true
}

///|
fn ensure_blob_shard(
  root : String,
  shard : String,
) -> Result[String, @moondata_store.MoonDataStoreIssue] {
  let path = join(root, "blobs/sha256/\{shard}")
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ =>
        return Err(
          blob_issue(
            "create-blob-shard", path, "failed to create MoonData blob shard",
          ),
        )
    }
  }
  Ok(path)
}

///|
fn verify_existing_blob(
  path : String,
  checksum : String,
) -> Result[Unit, @moondata_store.MoonDataStoreIssue] {
  let actual = match local_file_checksum(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if actual != checksum {
    return Err(
      blob_issue(
        "blob-corrupt", path, "content-addressed MoonData blob checksum does not match its path",
      ),
    )
  }
  Ok(())
}

///|
fn local_blob_result(
  root : String,
  path : String,
  relative : String,
  digest : String,
  byte_count : Int64,
  existed : Bool,
  kind : String,
  content_type : String,
) -> LocalBlobResult {
  let uri = @moondata_core.moondata_uri(relative)
  let checksum = "sha256:\{digest}"
  let data_ref = @moondata_core.data_ref(
    "blob-\{digest}",
    kind,
    uri,
    content_type~,
    byte_count~,
    checksum~,
  )
  { root, path, uri, digest, byte_count, existed, data_ref }
}

///|
pub fn put_local_bytes(
  root : String,
  bytes : Bytes,
  kind? : String = "blob",
  content_type? : String = "application/octet-stream",
) -> Result[LocalBlobResult, @moondata_store.MoonDataStoreIssue] {
  if bytes.length() == 0 {
    return Err(
      blob_issue("blob-empty", root, "MoonData does not store empty blobs"),
    )
  }
  match @moondata_store.initialize_root(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let checksum = @moondata_core.bytes_checksum(bytes)
  let digest = sha256_digest(checksum)
  if !sha256_digest_is_valid(digest) {
    return Err(
      blob_issue(
        "blob-digest-invalid", root, "MoonData SHA-256 digest must be 64 hex characters",
      ),
    )
  }
  let shard = digest[0:2].to_owned()
  match ensure_blob_shard(root, shard) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let relative = "blobs/sha256/\{shard}/\{digest}"
  let path = join(root, relative)
  let existed = @fsx.path_exists(path)
  if existed {
    match verify_existing_blob(path, checksum) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  } else {
    @fsx.write_bytes_to_file(path, bytes) catch {
      _ =>
        return Err(
          blob_issue("write-blob", path, "failed to write MoonData blob"),
        )
    }
    match verify_existing_blob(path, checksum) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(
    local_blob_result(
      root,
      path,
      relative,
      digest,
      bytes.length().to_int64(),
      existed,
      kind,
      content_type,
    ),
  )
}

///|
pub fn put_local_file(
  root : String,
  source_path : String,
  kind? : String = "blob",
  content_type? : String = "application/octet-stream",
  expected_checksum? : String = "",
) -> Result[LocalBlobResult, @moondata_store.MoonDataStoreIssue] {
  let size = match local_file_size(source_path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if size == 0L {
    return Err(
      blob_issue(
        "blob-empty", source_path, "MoonData does not store empty blobs",
      ),
    )
  }
  let checksum = if expected_checksum == "" {
    match local_file_checksum(source_path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    expected_checksum
  }
  let digest = sha256_digest(checksum)
  if !sha256_digest_is_valid(digest) {
    return Err(
      blob_issue(
        "blob-digest-invalid", source_path, "MoonData SHA-256 digest must be 64 hex characters",
      ),
    )
  }
  match @moondata_store.initialize_root(root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let shard = digest[0:2].to_owned()
  match ensure_blob_shard(root, shard) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let relative = "blobs/sha256/\{shard}/\{digest}"
  let path = join(root, relative)
  let mut existed = @fsx.path_exists(path)
  let mut copied = false
  if !existed {
    copied = match copy_local_file_staged(source_path, path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    existed = !copied
  }
  match verify_existing_blob(path, checksum) {
    Ok(_) => ()
    Err(error) => {
      if copied && @fsx.path_exists(path) {
        @fsx.remove_file(path) catch {
          _ => ()
        }
      }
      return Err(error)
    }
  }
  let stored_size = match local_file_size(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if stored_size != size {
    return Err(
      blob_issue(
        "blob-size-mismatch", path, "stored MoonData blob size does not match its source",
      ),
    )
  }
  Ok(
    local_blob_result(
      root, path, relative, digest, size, existed, kind, content_type,
    ),
  )
}
