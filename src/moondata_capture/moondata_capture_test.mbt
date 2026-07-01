///|
fn capture_request() -> @moondata_ingest.CaptureRegistrationRequest {
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
        "sidecar://session-capture/frame-1.json",
        byte_count=10L,
      ),
      @moondata_ingest.frame_input(
        "frame-capture-2",
        120L,
        "sidecar://session-capture/frame-2.json",
        byte_count=11L,
      ),
    ],
  }
}

///|
test "stored capture registration persists manifests and rebuilds catalog" {
  let root = "target/moondata-capture-store-test"
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
