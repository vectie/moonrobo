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

///|
test "local file blobs hash and copy through bounded chunks" {
  let root = "target/moondata-streamed-blob-test"
  let source = "target/moondata-streamed-blob-source.bin"
  let bytes = Bytes::makei(4097, fn(index) { (index % 251).to_byte() })
  @fsx.write_bytes_to_file(source, bytes) catch {
    _ => fail("failed to write streamed blob source")
  }
  let size = @moondata_blob.local_file_size(source).unwrap()
  assert_eq(size, 4097L)
  let range = @moondata_blob.read_local_file_range(source, 1024L, 17).unwrap()
  assert_eq(range.length(), 17)
  for index in 0..<range.length() {
    assert_eq(range[index], bytes[1024 + index])
  }
  let checksum = @moondata_blob.local_file_checksum(source, chunk_size=257).unwrap()
  assert_eq(checksum, @moondata_core.bytes_checksum(bytes))
  let stored = @moondata_blob.put_local_file(
    root,
    source,
    kind="binary-test",
    expected_checksum=checksum,
  ).unwrap()
  assert_eq(stored.byte_count, size)
  assert_eq(stored.data_ref.checksum, checksum)
  assert_eq(@moondata_blob.local_file_checksum(stored.path).unwrap(), checksum)
}

///|
test "streamed blob copy removes content written under a wrong expected digest" {
  let root = "target/moondata-streamed-blob-mismatch-test"
  let source = "target/moondata-streamed-blob-mismatch-source.bin"
  @fsx.write_bytes_to_file(source, b"streamed-blob-mismatch") catch {
    _ => fail("failed to write mismatch source")
  }
  let wrong = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  let wrong_path = root +
    "/blobs/sha256/00/" +
    wrong.strip_prefix("sha256:").unwrap().to_owned()
  if @fsx.path_exists(wrong_path) {
    @fsx.remove_file(wrong_path) catch {
      _ => fail("failed to reset mismatch blob")
    }
  }
  let result = @moondata_blob.put_local_file(
    root,
    source,
    expected_checksum=wrong,
  )
  assert_true(result is Err({ code: "blob-corrupt", .. }))
  assert_true(!@fsx.path_exists(wrong_path))
}

///|
test "streamed blob rejects non-hex expected digests before path construction" {
  let source = "target/moondata-streamed-blob-unsafe-digest.bin"
  @fsx.write_bytes_to_file(source, b"unsafe-digest") catch {
    _ => fail("failed to write unsafe digest source")
  }
  let invalid_digest = "sha256:../../../../../../../../../../../../../../../../../../../../../../../../../../"
  let result = @moondata_blob.put_local_file(
    "target/moondata-streamed-blob-unsafe-digest-test",
    source,
    expected_checksum=invalid_digest,
  )
  assert_true(result is Err({ code: "blob-digest-invalid", .. }))
}
