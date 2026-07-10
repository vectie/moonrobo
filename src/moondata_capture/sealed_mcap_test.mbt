///|
fn mcap_fixture_bytes(finalized : Bool) -> Bytes {
  let magic : Array[Byte] = [0x89, 0x4d, 0x43, 0x41, 0x50, 0x30, 0x0d, 0x0a]
  let size = 20
  Bytes::makei(size, fn(index) {
    if index < 8 {
      magic[index]
    } else if finalized && index >= size - 8 {
      magic[index - (size - 8)]
    } else {
      (index + 1).to_byte()
    }
  })
}

///|
test "MCAP sealing writes one immutable raw capture graph" {
  let root = "target/moondata-sealed-mcap-test"
  let source = "target/moondata-sealed-mcap-source.mcap"
  @fsx.write_bytes_to_file(source, mcap_fixture_bytes(true)) catch {
    _ => fail("failed to write MCAP fixture")
  }
  let request = @moondata_capture.seal_mcap_request(
    root, source, "capture-mcap-test", "robot-mcap", "ros2-mcap", 7000L,
  )
  let result = match @moondata_capture.seal_mcap_capture(request) {
    Ok(value) => value
    Err(error) => fail("MCAP seal failed: " + error.message)
  }
  assert_eq(result.format, "mcap")
  assert_true(result.blob.uri.has_prefix("moondata://blobs/sha256/"))
  assert_eq(result.capture.frame_count, 1)
  assert_eq(result.capture.registration.dataset.kind, "raw")
  let payload = result.capture.registration.frames[0].payload_ref.unwrap()
  assert_eq(payload.kind, "mcap")
  assert_eq(payload.content_type, "application/x-mcap")
  assert_eq(payload.uri, result.blob.uri)
  assert_eq(payload.checksum, result.blob.data_ref.checksum)
  let repeated = match @moondata_capture.seal_mcap_capture(request) {
    Ok(value) => value
    Err(error) => fail("deduplicated MCAP seal failed: " + error.message)
  }
  assert_true(repeated.blob.existed)
  assert_eq(repeated.blob.uri, result.blob.uri)
}

///|
test "MCAP sealing rejects recordings that were not finalized" {
  let root = "target/moondata-sealed-mcap-invalid-test"
  let source = "target/moondata-sealed-mcap-invalid-source.mcap"
  @fsx.write_bytes_to_file(source, mcap_fixture_bytes(false)) catch {
    _ => fail("failed to write invalid MCAP fixture")
  }
  let request = @moondata_capture.seal_mcap_request(
    root, source, "capture-mcap-invalid", "robot-mcap", "ros2-mcap", 7100L,
  )
  let result = @moondata_capture.seal_mcap_capture(request)
  assert_true(result is Err({ code: "mcap-not-finalized", .. }))
  assert_true(!@fsx.path_exists(root + "/blobs"))
}

///|
test "MCAP sealing rejects capture identity reuse for different bytes" {
  let root = "target/moondata-sealed-mcap-conflict-test"
  let first_source = "target/moondata-sealed-mcap-conflict-first.mcap"
  let second_source = "target/moondata-sealed-mcap-conflict-second.mcap"
  let first = mcap_fixture_bytes(true)
  let second = Bytes::makei(first.length(), fn(index) {
    if index == 9 {
      0x7f
    } else {
      first[index]
    }
  })
  @fsx.write_bytes_to_file(first_source, first) catch {
    _ => fail("failed to write first conflict fixture")
  }
  @fsx.write_bytes_to_file(second_source, second) catch {
    _ => fail("failed to write second conflict fixture")
  }
  let first_request = @moondata_capture.seal_mcap_request(
    root, first_source, "capture-mcap-conflict", "robot-mcap", "ros2-mcap", 7200L,
  )
  match @moondata_capture.seal_mcap_capture(first_request) {
    Ok(_) => ()
    Err(error) => fail("first MCAP seal failed: " + error.message)
  }
  let conflicting = {
    ..first_request,
    source_path: second_source,
    recorded_at_ms: 7201L,
  }
  let result = @moondata_capture.seal_mcap_capture(conflicting)
  assert_true(result is Err({ code: "sealed-capture-conflict", .. }))
}
