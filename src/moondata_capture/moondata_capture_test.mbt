///|
fn ensure_dir(path : String) -> Unit raise {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ => fail("failed to create " + path)
    }
  }
}

///|
fn frame_capture_1_body() -> String {
  "{\"t\":100}\n"
}

///|
fn frame_capture_2_body() -> String {
  "{\"t\":120,\"ok\":true}\n"
}

///|
fn write_capture_payloads(root : String) -> Unit raise {
  ensure_dir("target")
  match @moondata_store.initialize_root(root) {
    Ok(_) => ()
    Err(error) => fail("initialize capture root failed: " + error.message)
  }
  let dir = root + "/media/imports/ds-capture-store"
  ensure_dir(dir)
  @fsx.write_string_to_file(dir + "/frame-1.json", frame_capture_1_body()) catch {
    _ => fail("write frame 1 payload failed")
  }
  @fsx.write_string_to_file(dir + "/frame-2.json", frame_capture_2_body()) catch {
    _ => fail("write frame 2 payload failed")
  }
}

///|
fn capture_request() -> @moondata_ingest.CaptureRegistrationRequest {
  let frame_1_body = frame_capture_1_body()
  let frame_2_body = frame_capture_2_body()
  {
    source_id: "src-capture-store",
    capture_id: "cap-capture-store",
    dataset_id: "ds-capture-store",
    episode_id: "ep-capture-store",
    robot_id: "robot-capture",
    bridge_id: "bridge-capture",
    session_id: "session-capture",
    source_kind: "sidecar-observation",
    source_label: "Sidecar observation",
    origin_uri: "sidecar://session-capture",
    status: "stopped",
    started_at_ms: 100L,
    stopped_at_ms: Some(120L),
    receipt_ids: ["receipt-capture"],
    frames: [
      @moondata_ingest.frame_input(
        "frame-capture-1",
        100L,
        "moondata://media/imports/ds-capture-store/frame-1.json",
        byte_count=frame_1_body.length().to_int64(),
        checksum=@moondata_core.text_checksum(frame_1_body),
      ),
      @moondata_ingest.frame_input(
        "frame-capture-2",
        120L,
        "moondata://media/imports/ds-capture-store/frame-2.json",
        byte_count=frame_2_body.length().to_int64(),
        checksum=@moondata_core.text_checksum(frame_2_body),
      ),
    ],
  }
}

///|
test "stored capture registration persists manifests and rebuilds catalog" {
  let root = "target/moondata-capture-store-test"
  write_capture_payloads(root)
  let result = match
    @moondata_capture.register_stored_capture(
      @moondata_capture.stored_capture_registration_request(
        root,
        capture_request(),
        generated_at_ms=130L,
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("stored capture failed: " + error.message)
  }
  assert_eq(result.dataset_id, "ds-capture-store")
  assert_eq(result.frame_count, 2)
  assert_eq(result.catalog_entry_count, 6)
  let dataset = match @moondata_store.read_dataset(root, "ds-capture-store") {
    Ok(value) => value
    Err(_) => fail("read dataset failed")
  }
  assert_eq(dataset.capture_ids[0], "cap-capture-store")
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read catalog failed")
  }
  assert_eq(catalog.entry_count, 6)
  assert_eq(catalog.entries[0].artifact_kind, "source")
  let episode = match @moondata_store.read_episode(root, "ep-capture-store") {
    Ok(value) => value
    Err(_) => fail("read episode failed")
  }
  assert_eq(episode.frame_count, 2)
  let frame = match @moondata_store.read_frame(root, "frame-capture-2") {
    Ok(value) => value
    Err(_) => fail("read frame failed")
  }
  assert_eq(frame.sequence_index, 1)
}

///|
test "stored capture registration rejects missing frame payloads" {
  let root = "target/moondata-capture-missing-frame-payload-test"
  match
    @moondata_capture.register_stored_capture(
      @moondata_capture.stored_capture_registration_request(
        root,
        capture_request(),
        generated_at_ms=214L,
      ),
    ) {
    Ok(_) => fail("expected missing frame payload capture to fail")
    Err(error) => assert_eq(error.code, "frame-payload-missing")
  }
}

///|
test "stored capture registration rejects incomplete frame payload metadata" {
  let root = "target/moondata-capture-incomplete-frame-metadata-test"
  let base = capture_request()
  let incomplete_frame = { ..base.frames[0], checksum: "" }
  let invalid = { ..base, frames: [incomplete_frame] }
  match
    @moondata_capture.register_stored_capture(
      @moondata_capture.stored_capture_registration_request(
        root,
        invalid,
        generated_at_ms=215L,
      ),
    ) {
    Ok(_) => fail("expected incomplete frame payload metadata to fail")
    Err(error) => assert_eq(error.code, "invalid-frame-payload-metadata")
  }
}

///|
test "stored capture registration rejects frame payload byte drift" {
  let root = "target/moondata-capture-frame-byte-drift-test"
  write_capture_payloads(root)
  let base = capture_request()
  let drifted_frame = {
    ..base.frames[0],
    byte_count: base.frames[0].byte_count + 1L,
  }
  let invalid = { ..base, frames: [drifted_frame] }
  match
    @moondata_capture.register_stored_capture(
      @moondata_capture.stored_capture_registration_request(
        root,
        invalid,
        generated_at_ms=216L,
      ),
    ) {
    Ok(_) => fail("expected frame payload byte drift capture to fail")
    Err(error) => assert_eq(error.code, "frame-payload-byte-count-mismatch")
  }
}

///|
test "stored capture registration rejects empty captures" {
  let empty : @moondata_ingest.CaptureRegistrationRequest = {
    source_id: "src-empty-capture",
    capture_id: "cap-empty-capture",
    dataset_id: "ds-empty-capture",
    episode_id: "ep-empty-capture",
    robot_id: "robot-empty",
    bridge_id: "bridge-empty",
    session_id: "session-empty",
    source_kind: "sidecar-observation",
    source_label: "Empty sidecar observation",
    origin_uri: "sidecar://empty",
    status: "stopped",
    started_at_ms: 200L,
    stopped_at_ms: Some(200L),
    receipt_ids: [],
    frames: [],
  }
  match
    @moondata_capture.register_stored_capture(
      @moondata_capture.stored_capture_registration_request(
        "target/moondata-empty-capture-test",
        empty,
        generated_at_ms=201L,
      ),
    ) {
    Ok(_) => fail("expected empty capture registration to fail")
    Err(error) => assert_eq(error.code, "capture-empty")
  }
}

///|
test "stored capture registration rejects path-unsafe dataset ids" {
  let root = "target/moondata-capture-unsafe-dataset-id-test"
  let base = capture_request()
  let invalid = { ..base, dataset_id: "../escape" }
  match
    @moondata_capture.register_stored_capture(
      @moondata_capture.stored_capture_registration_request(
        root,
        invalid,
        generated_at_ms=210L,
      ),
    ) {
    Ok(_) => fail("expected unsafe dataset id capture to fail")
    Err(error) => assert_eq(error.code, "invalid-dataset-id")
  }
}

///|
test "stored capture registration rejects path-unsafe frame ids" {
  let root = "target/moondata-capture-unsafe-frame-id-test"
  let base = capture_request()
  let unsafe_frame = { ..base.frames[0], frame_id: "../frame-escape" }
  let invalid = { ..base, frames: [unsafe_frame] }
  match
    @moondata_capture.register_stored_capture(
      @moondata_capture.stored_capture_registration_request(
        root,
        invalid,
        generated_at_ms=211L,
      ),
    ) {
    Ok(_) => fail("expected unsafe frame id capture to fail")
    Err(error) => assert_eq(error.code, "invalid-frame-id")
  }
}

///|
test "stored capture registration rejects external frame payload uris" {
  let root = "target/moondata-capture-external-frame-payload-uri-test"
  let base = capture_request()
  let external_frame = {
    ..base.frames[0],
    payload_uri: "sidecar://session-capture/frame-1.json",
  }
  let invalid = { ..base, frames: [external_frame] }
  match
    @moondata_capture.register_stored_capture(
      @moondata_capture.stored_capture_registration_request(
        root,
        invalid,
        generated_at_ms=212L,
      ),
    ) {
    Ok(_) => fail("expected external frame payload uri capture to fail")
    Err(error) => assert_eq(error.code, "invalid-frame-payload-uri")
  }
}

///|
test "stored capture registration rejects unsafe frame payload uris" {
  let root = "target/moondata-capture-unsafe-frame-payload-uri-test"
  let base = capture_request()
  let unsafe_frame = {
    ..base.frames[0],
    payload_uri: "moondata://media/imports/../escape.json",
  }
  let invalid = { ..base, frames: [unsafe_frame] }
  match
    @moondata_capture.register_stored_capture(
      @moondata_capture.stored_capture_registration_request(
        root,
        invalid,
        generated_at_ms=213L,
      ),
    ) {
    Ok(_) => fail("expected unsafe frame payload uri capture to fail")
    Err(error) => assert_eq(error.code, "invalid-frame-payload-uri")
  }
}
