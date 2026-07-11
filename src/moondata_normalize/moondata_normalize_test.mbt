///|
fn write_raw_fixture(root : String) -> Unit {
  ignore(@moondata_store.initialize_root(root))
  let payload = @moondata_core.data_ref(
    "payload-normalize-0",
    "raw-file",
    "moondata://media/imports/ds-normalize-raw/0-frame.json",
    content_type="application/json",
  )
  let dataset = @moondata_core.dataset_manifest(
    "ds-normalize-raw",
    "raw",
    "imported",
    10L,
    source_ids=["src-normalize"],
    capture_ids=["cap-normalize"],
    episode_ids=["ep-normalize"],
    data_refs=[payload],
  )
  let episode = @moondata_core.episode_manifest(
    "ep-normalize",
    dataset.dataset_id,
    "robot-normalize",
    "bridge-normalize",
    "session-normalize",
    "imported",
    10L,
    frame_count=1,
    frame_ids=["frame-normalize-0"],
    data_refs=[payload],
  )
  let frame = @moondata_core.frame_ref(
    "frame-normalize-0",
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
test "normalize raw imported dataset into canonical dataset with lineage" {
  let root = "target/moondata-normalize-test"
  write_raw_fixture(root)
  let result = match
    @moondata_normalize.normalize_raw_dataset(
      @moondata_normalize.normalize_request(
        root, "ds-normalize-raw", "ds-normalize-canonical", 20L,
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("normalize failed: " + error.message)
  }
  assert_eq(result.dataset.kind, "canonical")
  assert_eq(result.dataset.episode_ids.length(), 1)
  assert_eq(result.frame_count, 1)
  assert_eq(result.transform.input_dataset_id, "ds-normalize-raw")
  assert_eq(result.transform.output_dataset_id, "ds-normalize-canonical")
  assert_eq(result.lineage.edges[0].relation, "normalized-from")
  let canonical = match
    @moondata_store.read_dataset(root, "ds-normalize-canonical") {
    Ok(value) => value
    Err(_) => fail("read canonical dataset failed")
  }
  assert_eq(canonical.kind, "canonical")
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read catalog failed")
  }
  assert_true(catalog.entry_count >= 5)
}

///|
test "normalize rejects missing raw datasets" {
  match
    @moondata_normalize.normalize_raw_dataset(
      @moondata_normalize.normalize_request(
        "target/moondata-normalize-missing-test", "missing-raw", "missing-canonical",
        30L,
      ),
    ) {
    Ok(_) => fail("expected missing raw dataset to fail")
    Err(error) => assert_eq(error.code, "read-manifest")
  }
}
