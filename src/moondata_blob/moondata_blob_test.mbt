///|
test "local blob store is SHA-256 addressed and deduplicated" {
  let root = "target/moondata-blob-test"
  let bytes = Bytes::makei(4, fn(index) { (65 + index).to_byte() })
  let first = match
    @moondata_blob.put_local_bytes(
      root,
      bytes,
      kind="mcap",
      content_type="application/x-mcap",
    ) {
    Ok(value) => value
    Err(error) => fail("blob put failed: " + error.message)
  }
  assert_true(first.data_ref.checksum.has_prefix("sha256:"))
  assert_true(first.uri.has_prefix("moondata://blobs/sha256/"))
  assert_true(@fsx.path_exists(first.path))
  let second = match
    @moondata_blob.put_local_bytes(
      root,
      bytes,
      kind="mcap",
      content_type="application/x-mcap",
    ) {
    Ok(value) => value
    Err(error) => fail("deduplicated blob put failed: " + error.message)
  }
  assert_true(second.existed)
  assert_eq(second.uri, first.uri)
  assert_eq(second.digest, first.digest)
}

///|
test "local blob store refuses a corrupted content-addressed payload" {
  let root = "target/moondata-blob-corruption-test"
  let bytes = Bytes::makei(3, fn(index) { (70 + index).to_byte() })
  let checksum = @moondata_core.bytes_checksum(bytes)
  let digest = checksum.strip_prefix("sha256:").unwrap().to_owned()
  let existing = root + "/blobs/sha256/" + digest[0:2].to_owned() + "/" + digest
  if @fsx.path_exists(existing) {
    @fsx.remove_file(existing) catch {
      _ => fail("failed to reset blob fixture")
    }
  }
  let stored = match @moondata_blob.put_local_bytes(root, bytes) {
    Ok(value) => value
    Err(error) => fail("blob put failed: " + error.message)
  }
  @fsx.write_bytes_to_file(stored.path, b"bad") catch {
    _ => fail("failed to corrupt blob fixture")
  }
  let result = @moondata_blob.put_local_bytes(root, bytes)
  assert_true(result is Err({ code: "blob-corrupt", .. }))
}
