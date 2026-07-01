///|
fn write_curation_fixture(
  root : String,
  quality : @moondata_core.QualityRun,
) -> Unit {
  ignore(@moondata_store.initialize_root(root))
  let payload = @moondata_core.data_ref(
    "payload-curate-0",
    "json",
    "moondata://media/imports/ds-curate/0-frame.json",
    content_type="application/json",
  )
  let dataset = @moondata_core.dataset_manifest(
    "ds-curate-canonical",
    "canonical",
    "active",
    10L,
    source_ids=["src-curate"],
    capture_ids=["cap-curate"],
    episode_ids=["ep-curate"],
    data_refs=[payload],
  )
  let episode = @moondata_core.episode_manifest(
    "ep-curate",
    dataset.dataset_id,
    "robot-curate",
    "bridge-curate",
    "session-curate",
    "stopped",
    10L,
    stopped_at_ms=Some(20L),
    frame_count=1,
    frame_ids=["frame-curate-0"],
    data_refs=[payload],
  )
  let frame = @moondata_core.frame_ref(
    "frame-curate-0",
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
  ignore(@moondata_store.write_quality_run(root, quality))
}

///|
test "curate stored dataset writes versioned curated artifacts" {
  let root = "target/moondata-curate-test"
  let quality = @moondata_core.quality_run(
    "qr-curate",
    "ds-curate-canonical",
    ["ep-curate"],
    20L,
    [],
  )
  write_curation_fixture(root, quality)
  let result = match
    @moondata_curate.curate_stored_dataset(
      @moondata_curate.stored_curation_request(
        root,
        "ds-curate-canonical",
        "qr-curate",
        30L,
        output_dataset_id="ds-curate-accepted",
        version_id="version-curate-accepted",
        transform_run_id="tr-curate-accepted",
        lineage_id="lineage-curate-accepted",
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("curate failed: " + error.message)
  }
  assert_eq(result.dataset.kind, "curated")
  assert_eq(result.dataset.episode_ids.length(), 1)
  assert_eq(result.version.status, "accepted")
  assert_eq(result.version.quality_run_ids[0], "qr-curate")
  assert_eq(result.transform.quality_run_ids[0], "qr-curate")
  assert_eq(result.accepted_episode_count, 1)
  let curated = match
    @moondata_store.read_curated_dataset(root, "ds-curate-accepted") {
    Ok(value) => value
    Err(_) => fail("read curated dataset failed")
  }
  assert_eq(curated.kind, "curated")
  let version = match
    @moondata_store.read_dataset_version(root, "version-curate-accepted") {
    Ok(value) => value
    Err(_) => fail("read curated version failed")
  }
  assert_eq(version.quality_run_ids.length(), 1)
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read catalog failed")
  }
  assert_true(catalog.entry_count >= 8)
}

///|
test "curate stored dataset rejects blocked quality gates" {
  let root = "target/moondata-curate-blocked-test"
  let finding = @moondata_core.quality_finding(
    "finding-curate-blocked", "episode-not-stopped", "blocker", "episode", "ep-curate",
    "episode is not stopped",
  )
  let quality = @moondata_core.quality_run(
    "qr-curate-blocked",
    "ds-curate-canonical",
    ["ep-curate"],
    20L,
    [finding],
  )
  write_curation_fixture(root, quality)
  match
    @moondata_curate.curate_stored_dataset(
      @moondata_curate.stored_curation_request(
        root, "ds-curate-canonical", "qr-curate-blocked", 30L,
      ),
    ) {
    Ok(_) => fail("expected blocked quality to fail")
    Err(error) => assert_eq(error.code, "curate-quality-not-passed")
  }
}
