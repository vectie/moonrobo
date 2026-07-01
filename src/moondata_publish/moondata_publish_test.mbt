///|
fn write_publish_fixture(
  root : String,
  version_status : String,
  quality : @moondata_core.QualityRun,
) -> Unit raise {
  ignore(@moondata_store.initialize_root(root))
  @fsx.create_dir(root + "/media/imports/ds-publish") catch {
    _ => ()
  }
  @fsx.write_string_to_file(
    root + "/media/imports/ds-publish/0-frame.json",
    "{\"t\":1}",
  ) catch {
    _ => fail("write publish payload failed")
  }
  let payload = @moondata_core.data_ref(
    "payload-publish-0",
    "json",
    "moondata://media/imports/ds-publish/0-frame.json",
    content_type="application/json",
    byte_count=7L,
    checksum=@moondata_core.text_checksum("{\"t\":1}"),
  )
  let source = @moondata_core.data_source(
    "src-publish", "local-file", "publish fixture", "robot-publish", "bridge-publish",
    "file://publish-fixture", 8L,
  )
  let capture = @moondata_core.capture_session(
    "cap-publish",
    source.source_id,
    source.robot_id,
    source.bridge_id,
    "completed",
    9L,
    stopped_at_ms=Some(10L),
  )
  let canonical = @moondata_core.dataset_manifest(
    "ds-publish-canonical",
    "canonical",
    "active",
    10L,
    source_ids=[source.source_id],
    capture_ids=[capture.capture_id],
    episode_ids=["ep-publish"],
    data_refs=[payload],
  )
  let dataset = @moondata_core.dataset_manifest(
    "ds-publish-curated",
    "curated",
    "active",
    10L,
    source_ids=[source.source_id],
    capture_ids=[capture.capture_id],
    episode_ids=["ep-publish"],
    data_refs=[payload],
  )
  let version = @moondata_core.dataset_version(
    "version-publish",
    dataset.dataset_id,
    version_status,
    20L,
    accepted_episode_ids=["ep-publish"],
    quality_run_ids=[quality.quality_run_id],
  )
  let episode = @moondata_core.episode_manifest(
    "ep-publish",
    "ds-publish-canonical",
    "robot-publish",
    "bridge-publish",
    "session-publish",
    "stopped",
    10L,
    stopped_at_ms=Some(20L),
    frame_count=1,
    frame_ids=["frame-publish-0"],
    data_refs=[payload],
  )
  let frame = @moondata_core.frame_ref(
    "frame-publish-0",
    episode.episode_id,
    episode.robot_id,
    episode.bridge_id,
    0,
    10L,
    payload_ref=Some(payload),
  )
  ignore(@moondata_store.write_source(root, source))
  ignore(@moondata_store.write_capture(root, capture))
  ignore(@moondata_store.write_dataset(root, canonical))
  ignore(@moondata_store.write_dataset(root, dataset))
  ignore(@moondata_store.write_dataset_version(root, version))
  ignore(@moondata_store.write_episode(root, episode))
  ignore(@moondata_store.write_frame(root, frame))
  ignore(@moondata_store.write_quality_run(root, quality))
}

///|
test "publish stored export writes export manifest and rebuilds catalog" {
  let root = "target/moondata-publish-test"
  let quality = @moondata_core.quality_run(
    "qr-publish",
    "ds-publish-canonical",
    ["ep-publish"],
    15L,
    [],
  )
  write_publish_fixture(root, "accepted", quality)
  let result = match
    @moondata_publish.publish_stored_export(
      @moondata_publish.stored_export_request(
        root,
        "version-publish",
        30L,
        export_manifest_id="export-publish",
        target_format="jsonl",
        output_uri="moondata://exports/export-publish.jsonl",
      ),
    ) {
    Ok(value) => value
    Err(error) => fail("publish failed: " + error.message)
  }
  assert_eq(result.manifest.input_version_id, "version-publish")
  assert_eq(result.manifest.dataset_id, "ds-publish-curated")
  assert_eq(result.manifest.quality_run_ids[0], "qr-publish")
  assert_eq(result.manifest.output_refs[0].content_type, "application/jsonl")
  assert_eq(result.output_record_count, 1)
  assert_true(result.output_byte_count > 0L)
  assert_eq(result.manifest.output_refs[0].byte_count, result.output_byte_count)
  assert_eq(result.manifest.output_refs[0].checksum, result.output_checksum)
  assert_true(result.manifest.output_refs[0].checksum.contains("text-sum-v1:"))
  assert_true(@fsx.path_exists(result.output_path))
  let manifest = match
    @moondata_store.read_export_manifest(root, "export-publish") {
    Ok(value) => value
    Err(_) => fail("read export manifest failed")
  }
  assert_eq(manifest.target_format, "jsonl")
  let catalog = match @moondata_store.read_catalog(root) {
    Ok(value) => value
    Err(_) => fail("read catalog failed")
  }
  assert_true(catalog.entry_count >= 8)
}

///|
test "publish stored export rejects unaccepted versions" {
  let root = "target/moondata-publish-reject-test"
  let quality = @moondata_core.quality_run(
    "qr-publish-reject",
    "ds-publish-canonical",
    ["ep-publish"],
    15L,
    [],
  )
  write_publish_fixture(root, "draft", quality)
  match
    @moondata_publish.publish_stored_export(
      @moondata_publish.stored_export_request(root, "version-publish", 30L),
    ) {
    Ok(_) => fail("expected unaccepted version to fail")
    Err(error) => assert_eq(error.code, "export-version-not-accepted")
  }
}

///|
test "publish stored export rejects blocked quality gates" {
  let root = "target/moondata-publish-blocked-test"
  let finding = @moondata_core.quality_finding(
    "finding-publish-blocked", "episode-not-stopped", "blocker", "episode", "ep-publish",
    "episode is not stopped",
  )
  let quality = @moondata_core.quality_run(
    "qr-publish-blocked",
    "ds-publish-canonical",
    ["ep-publish"],
    15L,
    [finding],
  )
  write_publish_fixture(root, "accepted", quality)
  match
    @moondata_publish.publish_stored_export(
      @moondata_publish.stored_export_request(root, "version-publish", 30L),
    ) {
    Ok(_) => fail("expected blocked quality to fail")
    Err(error) => assert_eq(error.code, "export-quality-not-passed")
  }
}
