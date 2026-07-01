///|
fn write_canonical_fixture(root : String, robot_id : String) -> Unit {
  ignore(@moondata_store.initialize_root(root))
  let payload = @moondata_core.data_ref(
    "payload-assess-0",
    "json",
    "moondata://media/imports/ds-assess/0-frame.json",
    content_type="application/json",
  )
  let dataset = @moondata_core.dataset_manifest(
    "ds-assess-canonical",
    "canonical",
    "active",
    10L,
    source_ids=["src-assess"],
    capture_ids=["cap-assess"],
    episode_ids=["ep-assess"],
    data_refs=[payload],
  )
  let episode = @moondata_core.episode_manifest(
    "ep-assess",
    "ds-assess-raw",
    robot_id,
    "bridge-assess",
    "session-assess",
    "stopped",
    10L,
    stopped_at_ms=Some(20L),
    frame_count=1,
    frame_ids=["frame-assess-0"],
    data_refs=[payload],
  )
  let frame = @moondata_core.frame_ref(
    "frame-assess-0",
    episode.episode_id,
    episode.robot_id,
    episode.bridge_id,
    0,
    10L,
    payload_ref=Some(payload),
  )
  ignore(@moondata_store.write_dataset(root, dataset))
  ignore(@moondata_store.write_episode(root, episode))
  ignore(@moondata_store.write_frame(root, frame))
}

///|
test "run dataset quality persists a quality run and rebuilds the catalog" {
  let root = "target/moondata-assess-test"
  write_canonical_fixture(root, "robot-assess")
  let result = match
    @moondata_assess.run_dataset_quality(
      @moondata_assess.dataset_quality_request(
        root,
        "ds-assess-canonical",
        30L,
        quality_run_id="qr-assess",
        expected_robot_id="robot-assess",
        expected_bridge_id="bridge-assess",
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("quality failed: " + error.message)
  }
  assert_eq(result.episode_count, 1)
  assert_eq(result.frame_count, 1)
  assert_eq(result.quality.status, "passed")
  assert_eq(result.quality.finding_count, 0)
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read catalog failed")
  }
  assert_true(catalog.entry_count >= 4)
}

///|
test "run dataset quality records identity blockers when expected identity differs" {
  let root = "target/moondata-assess-mismatch-test"
  write_canonical_fixture(root, "robot-assess-source")
  let result = match
    @moondata_assess.run_dataset_quality(
      @moondata_assess.dataset_quality_request(
        root,
        "ds-assess-canonical",
        40L,
        quality_run_id="qr-assess-mismatch",
        expected_robot_id="robot-assess-target",
        expected_bridge_id="bridge-assess",
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("quality failed: " + error.message)
  }
  assert_eq(result.quality.status, "blocked")
  assert_eq(result.quality.blocker_count, 1)
  assert_eq(result.quality.findings[0].rule_id, "robot-id-mismatch")
}
